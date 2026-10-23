import Foundation
import Synchronization

public protocol SMTPTransport: Sendable {
    func connect(host: String, port: Int, tlsImmediately: Bool) async throws
    /// Upgrades the open connection to TLS; call after the server's 220 reply to STARTTLS.
    func startTLS() async throws
    /// Sends `s` followed by CRLF.
    func writeLine(_ s: String) async throws
    func write(_ data: Data) async throws
    /// Reads one complete reply, joining the lines of a multiline ("250-…") reply with "\n".
    /// `timeout` overrides the transport's per-read timeout (seconds); nil keeps the default.
    func readReply(timeout: TimeInterval?) async throws -> (code: Int, text: String)
    func close() async
}

extension SMTPTransport {
    /// Reads one reply with the transport's default timeout.
    public func readReply() async throws -> (code: Int, text: String) {
        try await readReply(timeout: nil)
    }
}

/// Connection-level failures. `SMTPClient` reports them as `SMTPError` with the dialogue stage.
public enum SMTPTransportError: Error, Equatable, LocalizedError {
    case notConnected
    case connectionClosed
    case timedOut
    case malformedReply(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the mail server."
        case .connectionClosed: "The mail server closed the connection."
        case .timedOut: "The mail server did not reply in time."
        case let .malformedReply(line): "The mail server sent an unreadable reply: \(line)"
        }
    }
}

/// Splits received bytes into SMTP replies. Lines may arrive split or coalesced across reads.
struct SMTPReplyParser {
    private var buffer = Data()
    private var pendingLines: [String] = []

    mutating func append(_ data: Data) { buffer.append(data) }

    /// Drops everything received so far, e.g. plaintext bytes sent before a TLS upgrade.
    mutating func discardBuffered() {
        buffer.removeAll()
        pendingLines.removeAll()
    }

    /// The next complete reply, or nil until more bytes arrive.
    mutating func nextReply() throws -> (code: Int, text: String)? {
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.last == 0x0D { line.removeLast() }

            let bytes = Array(line)
            let separator = bytes.count > 3 ? bytes[3] : nil
            guard bytes.count >= 3, bytes[0..<3].allSatisfy({ (0x30...0x39).contains($0) }),
                  separator == nil || separator == 0x20 || separator == 0x2D
            else { throw SMTPTransportError.malformedReply(String(decoding: bytes, as: UTF8.self)) }

            let code = Int(String(decoding: bytes[0..<3], as: UTF8.self))!
            pendingLines.append(String(decoding: bytes.dropFirst(4), as: UTF8.self))
            if separator != 0x2D {
                defer { pendingLines.removeAll() }
                return (code, pendingLines.joined(separator: "\n"))
            }
        }
        return nil
    }
}

/// SMTP over `URLSessionStreamTask`. TLS comes from `startSecureConnection()`, either right after
/// connecting (implicit TLS) or after the STARTTLS exchange.
public final class StreamTaskSMTPTransport: SMTPTransport {
    static let defaultTimeout: TimeInterval = 60
    private static let chunkSize = 65_536

    private struct State {
        var task: URLSessionStreamTask?
        var parser = SMTPReplyParser()
        var atEOF = false
    }

    private let state = Mutex(State())
    private let timeout: TimeInterval

    public convenience init() { self.init(timeout: Self.defaultTimeout) }

    /// - Parameter timeout: seconds to wait for each read and each written chunk.
    init(timeout: TimeInterval) { self.timeout = timeout }

    public func connect(host: String, port: Int, tlsImmediately: Bool) async throws {
        let task = URLSession.shared.streamTask(withHostName: host, port: port)
        let previous = state.withLock { state in
            defer { state = State(task: task) }
            return state.task
        }
        previous?.cancel()
        task.resume()
        if tlsImmediately { task.startSecureConnection() }
    }

    public func startTLS() async throws {
        let task = try currentTask()
        // Nothing the server sent before the upgrade may be read as if it came over TLS.
        state.withLock { $0.parser.discardBuffered() }
        task.startSecureConnection()
    }

    public func writeLine(_ s: String) async throws {
        try await write(Data((s + "\r\n").utf8))
    }

    public func write(_ data: Data) async throws {
        let task = try currentTask()
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: Self.chunkSize, limitedBy: data.endIndex) ?? data.endIndex
            try await write(Data(data[offset..<end]), to: task)
            offset = end
        }
    }

    public func readReply(timeout: TimeInterval?) async throws -> (code: Int, text: String) {
        let task = try currentTask()
        while true {
            let (reply, atEOF) = try state.withLock { state in
                (try state.parser.nextReply(), state.atEOF)
            }
            if let reply { return reply }
            if atEOF { throw SMTPTransportError.connectionClosed }
            let (data, eof) = try await read(from: task, timeout: timeout ?? self.timeout)
            state.withLock { state in
                state.parser.append(data)
                state.atEOF = eof
            }
        }
    }

    public func close() async {
        let task = state.withLock { state in
            defer { state.task = nil }
            return state.task
        }
        task?.cancel()
    }

    private func currentTask() throws -> URLSessionStreamTask {
        guard let task = state.withLock({ $0.task }) else { throw SMTPTransportError.notConnected }
        return task
    }

    private func read(from task: URLSessionStreamTask, timeout: TimeInterval) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            task.readData(ofMinLength: 1, maxLength: Self.chunkSize, timeout: timeout) { data, atEOF, error in
                if let error {
                    continuation.resume(throwing: Self.transportError(error))
                } else {
                    continuation.resume(returning: (data ?? Data(), atEOF))
                }
            }
        }
    }

    private func write(_ chunk: Data, to task: URLSessionStreamTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.write(chunk, timeout: timeout) { error in
                if let error {
                    continuation.resume(throwing: Self.transportError(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Stream-task timeouts arrive as POSIX ETIMEDOUT (or URLError.timedOut).
    private static func transportError(_ error: Error) -> Error {
        let nsError = error as NSError
        let timedOut = (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ETIMEDOUT))
            || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut)
        return timedOut ? SMTPTransportError.timedOut : error
    }
}
