import Foundation

/// A failed SMTP exchange. `serverText` is the server's reply (or the connection failure);
/// it never contains the password.
public struct SMTPError: Error, LocalizedError, Equatable {
    /// The server's reply code, or 0 when the connection itself failed.
    public var code: Int
    public var serverText: String
    /// The dialogue step that failed: CONNECT, EHLO, STARTTLS, AUTH, MAIL FROM, RCPT TO, DATA or BODY.
    public var stage: String

    public init(code: Int, serverText: String, stage: String) {
        self.code = code
        self.serverText = serverText
        self.stage = stage
    }

    public var errorDescription: String? {
        code == 0 ? "SMTP \(stage) failed: \(serverText)" : "SMTP \(stage) failed (\(code)): \(serverText)"
    }
}

/// Logs in with AUTH PLAIN and sends one message per connection.
public struct SMTPClient: Sendable {
    static let ehloDomain = "kindlesend.local"
    /// Seconds to wait for the reply to the final "." (RFC 5321 §4.5.3.2.6 recommends 10 minutes):
    /// a server may scan a large message before accepting it.
    static let bodyReplyTimeout: TimeInterval = 600

    private let account: SMTPAccount
    private let password: String
    private let transport: @Sendable () -> SMTPTransport

    public init(account: SMTPAccount, password: String,
                transport: @escaping @Sendable () -> SMTPTransport = { StreamTaskSMTPTransport() }) {
        self.account = account
        self.password = password
        self.transport = transport
    }

    /// Connects, authenticates and quits without sending anything.
    public func verifyLogin() async throws {
        try await session { _ in }
    }

    /// Sends `message`, a full RFC 5322 message with CRLF line endings.
    public func send(from: String, to: String, message: Data) async throws {
        try await session { connection in
            try await Self.command("MAIL FROM:<\(from)>", expecting: [250], stage: "MAIL FROM", on: connection)
            try await Self.command("RCPT TO:<\(to)>", expecting: [250, 251], stage: "RCPT TO", on: connection)
            try await Self.command("DATA", expecting: [354], stage: "DATA", on: connection)
            try await Self.during("BODY") {
                try await connection.write(Self.dataPayload(message))
                try await Self.expect([250], stage: "BODY", from: connection, timeout: Self.bodyReplyTimeout)
            }
        }
    }

    /// Opens an authenticated session, runs `body`, then sends QUIT and closes without waiting for
    /// QUIT's reply (the work is already done, so a slow or silent server must not delay it).
    private func session(_ body: (SMTPTransport) async throws -> Void) async throws {
        let connection = transport()
        do {
            try await Self.during("CONNECT") {
                try await connection.connect(host: account.host, port: account.port,
                                             tlsImmediately: account.security == .implicitTLS)
                try await Self.expect([220], stage: "CONNECT", from: connection)
            }
            try await Self.command("EHLO \(Self.ehloDomain)", expecting: [250], stage: "EHLO", on: connection)
            if account.security == .startTLS {
                try await Self.command("STARTTLS", expecting: [220], stage: "STARTTLS", on: connection)
                try await Self.during("STARTTLS") { try await connection.startTLS() }
                // A failed TLS handshake surfaces on the first exchange after the upgrade.
                do {
                    try await Self.command("EHLO \(Self.ehloDomain)", expecting: [250], stage: "EHLO", on: connection)
                } catch let error as SMTPError where error.code == 0 {
                    throw SMTPError(code: 0, serverText: error.serverText, stage: "STARTTLS")
                }
            }
            try await Self.command("AUTH PLAIN \(authPlainCredentials)", expecting: [235], stage: "AUTH", on: connection)
            try await body(connection)
            // The work is done; a failed QUIT does not fail it.
            try? await connection.writeLine("QUIT")
        } catch {
            await connection.close()
            throw error
        }
        await connection.close()
    }

    private var authPlainCredentials: String {
        Data("\u{0}\(account.user)\u{0}\(password)".utf8).base64EncodedString()
    }

    private static func command(_ line: String, expecting codes: Set<Int>, stage: String,
                                on connection: SMTPTransport) async throws {
        try await during(stage) {
            try await connection.writeLine(line)
            try await expect(codes, stage: stage, from: connection)
        }
    }

    private static func expect(_ codes: Set<Int>, stage: String, from connection: SMTPTransport,
                               timeout: TimeInterval? = nil) async throws {
        let reply = try await connection.readReply(timeout: timeout)
        guard codes.contains(reply.code) else {
            throw SMTPError(code: reply.code, serverText: reply.text, stage: stage)
        }
    }

    /// Reports any non-SMTP failure (closed connection, timeout, TLS error) as an `SMTPError` for `stage`.
    private static func during(_ stage: String, _ operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch let error as SMTPError {
            throw error
        } catch {
            throw SMTPError(code: 0, serverText: error.localizedDescription, stage: stage)
        }
    }

    /// The DATA payload: lines starting with "." get a second ".", the message ends with CRLF,
    /// and the terminating ".\r\n" follows.
    static func dataPayload(_ message: Data) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(message.count + message.count / 64 + 5)
        var atLineStart = true
        for byte in message {
            if atLineStart && byte == UInt8(ascii: ".") { out.append(byte) }
            out.append(byte)
            atLineStart = byte == UInt8(ascii: "\n")
        }
        if !out.ends(with: [0x0D, 0x0A]) { out.append(contentsOf: [0x0D, 0x0A]) }
        out.append(contentsOf: Array(".\r\n".utf8))
        return Data(out)
    }
}

private extension Array where Element == UInt8 {
    func ends(with suffix: [UInt8]) -> Bool { count >= suffix.count && Array(self[(count - suffix.count)...]) == suffix }
}
