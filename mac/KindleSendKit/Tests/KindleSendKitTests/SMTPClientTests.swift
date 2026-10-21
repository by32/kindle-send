import Foundation
import Network
import Synchronization
import Testing
@testable import KindleSendKit

/// Plays canned server replies in order and records every call the client makes.
actor ScriptedTransport: SMTPTransport {
    enum Event: Equatable {
        case connect(host: String, port: Int, tlsImmediately: Bool)
        case startTLS
        case line(String)
        case data(Data)
        case close
    }

    private var replies: [(code: Int, text: String)]
    private(set) var events: [Event] = []

    init(_ replies: [(Int, String)]) {
        self.replies = replies.map { (code: $0.0, text: $0.1) }
    }

    func connect(host: String, port: Int, tlsImmediately: Bool) async throws {
        events.append(.connect(host: host, port: port, tlsImmediately: tlsImmediately))
    }
    func startTLS() async throws { events.append(.startTLS) }
    func writeLine(_ s: String) async throws { events.append(.line(s)) }
    func write(_ data: Data) async throws { events.append(.data(data)) }
    func readReply() async throws -> (code: Int, text: String) {
        guard !replies.isEmpty else { throw SMTPTransportError.connectionClosed }
        return replies.removeFirst()
    }
    func close() async { events.append(.close) }

    var lines: [String] {
        events.compactMap { if case let .line(s) = $0 { s } else { nil } }
    }
    var startTLSCount: Int { events.filter { $0 == .startTLS }.count }
}

@Suite struct SMTPClientTests {
    static let icloud = SMTPAccount(host: "smtp.mail.me.com", port: 587, user: "reader@icloud.com",
                                    from: "reader@icloud.com", maxBytes: 20 * 1_048_576)
    static let gmail = SMTPAccount(host: "smtp.gmail.com", port: 465, user: "reader@gmail.com",
                                   from: "reader@gmail.com", maxBytes: 25 * 1_048_576)
    static let password = "abcd-efgh-ijkl-mnop"

    static func client(_ account: SMTPAccount, _ transport: ScriptedTransport) -> SMTPClient {
        SMTPClient(account: account, password: password, transport: { transport })
    }

    static func authLine(_ user: String) -> String {
        "AUTH PLAIN " + Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
    }

    static let sendReplies: [(Int, String)] = [
        (250, "2.1.0 OK"), (250, "2.1.5 OK"), (354, "Go ahead"), (250, "2.0.0 queued"), (221, "Bye"),
    ]

    @Test func startTLSDialogueForPort587() async throws {
        let transport = ScriptedTransport([
            (220, "smtp.mail.me.com ESMTP"), (250, "smtp.mail.me.com\nSTARTTLS"), (220, "2.0.0 Ready to start TLS"),
            (250, "smtp.mail.me.com\nAUTH PLAIN LOGIN"), (235, "2.7.0 Authentication successful"),
        ] + Self.sendReplies)
        let message = Data("Subject: Book\r\n\r\nHello\r\n".utf8)

        try await Self.client(Self.icloud, transport).send(from: "reader@icloud.com", to: "me@kindle.com", message: message)

        #expect(await transport.events == [
            .connect(host: "smtp.mail.me.com", port: 587, tlsImmediately: false),
            .line("EHLO kindlesend.local"),
            .line("STARTTLS"),
            .startTLS,
            .line("EHLO kindlesend.local"),
            .line(Self.authLine("reader@icloud.com")),
            .line("MAIL FROM:<reader@icloud.com>"),
            .line("RCPT TO:<me@kindle.com>"),
            .line("DATA"),
            .data(Data("Subject: Book\r\n\r\nHello\r\n.\r\n".utf8)),
            .line("QUIT"),
            .close,
        ])
        #expect(await transport.startTLSCount == 1)
    }

    @Test func implicitTLSForPort465() async throws {
        let transport = ScriptedTransport([
            (220, "smtp.gmail.com ESMTP"), (250, "smtp.gmail.com\nAUTH PLAIN LOGIN"), (235, "2.7.0 Accepted"), (221, "Bye"),
        ])

        try await Self.client(Self.gmail, transport).verifyLogin()

        #expect(await transport.events.first == .connect(host: "smtp.gmail.com", port: 465, tlsImmediately: true))
        #expect(await transport.lines == ["EHLO kindlesend.local", Self.authLine("reader@gmail.com"), "QUIT"])
        #expect(await transport.startTLSCount == 0)
        #expect(await transport.events.last == .close)
    }

    @Test func dotStuffing() async throws {
        let transport = ScriptedTransport([(220, "hi"), (250, "hello"), (235, "ok")] + Self.sendReplies)
        let message = Data(".starts with a dot\r\nmiddle\r\n.\r\n..two\r\nno final newline".utf8)

        try await Self.client(Self.gmail, transport).send(from: "a@b.c", to: "d@kindle.com", message: message)

        let sent = await transport.events.compactMap { if case let .data(d) = $0 { d } else { nil } }
        #expect(sent == [Data("..starts with a dot\r\nmiddle\r\n..\r\n...two\r\nno final newline\r\n.\r\n".utf8)])
    }

    @Test func authFailureSurfacesServerText() async throws {
        let transport = ScriptedTransport([
            (220, "hi"), (250, "hello"), (535, "5.7.8 Username and Password not accepted"),
        ])

        let error = try await #require(throws: SMTPError.self) { try await Self.client(Self.gmail, transport).verifyLogin() }

        #expect(error.code == 535)
        #expect(error.stage == "AUTH")
        let description = try #require(error.errorDescription)
        #expect(description.contains("Username and Password not accepted"))
        #expect(!description.contains(Self.password))
        #expect(await transport.events.last == .close)
    }

    @Test func unexpectedCodesNameTheirStage() async throws {
        let cases: [(replies: [(Int, String)], stage: String)] = [
            ([(554, "go away")], "CONNECT"),
            ([(220, "hi"), (502, "no EHLO")], "EHLO"),
            ([(220, "hi"), (250, "hello"), (454, "TLS not available")], "STARTTLS"),
            ([(220, "hi"), (250, "hello"), (220, "go"), (250, "hello"), (235, "ok"), (550, "bad sender")], "MAIL FROM"),
            ([(220, "hi"), (250, "hello"), (220, "go"), (250, "hello"), (235, "ok"), (250, "ok"), (550, "no such user")], "RCPT TO"),
            ([(220, "hi"), (250, "hello"), (220, "go"), (250, "hello"), (235, "ok"), (250, "ok"), (251, "forwarded"), (451, "later")], "DATA"),
            ([(220, "hi"), (250, "hello"), (220, "go"), (250, "hello"), (235, "ok"), (250, "ok"), (250, "ok"), (354, "go"), (552, "too big")], "BODY"),
        ]
        for (replies, stage) in cases {
            let transport = ScriptedTransport(replies)
            let error = try await #require(throws: SMTPError.self) {
                try await Self.client(Self.icloud, transport).send(from: "a@b.c", to: "d@kindle.com", message: Data("x\r\n".utf8))
            }
            #expect(error.stage == stage)
            #expect(error.code == replies.last!.0)
            #expect(error.errorDescription?.contains(replies.last!.1) == true)
        }
    }

    @Test func connectionClosedMidDialogueNamesStage() async throws {
        let transport = ScriptedTransport([(220, "hi"), (250, "hello")])

        let error = try await #require(throws: SMTPError.self) { try await Self.client(Self.gmail, transport).verifyLogin() }

        #expect(error.stage == "AUTH")
        #expect(error.errorDescription?.contains("closed") == true)
        #expect(error.errorDescription?.contains("AUTH") == true)
    }

    @Test func multilineEHLO() throws {
        var parser = SMTPReplyParser()
        parser.append(Data("250-PIPELINING\r\n250 AUTH PLAIN LOGIN\r\n".utf8))
        let reply = try #require(try parser.nextReply())
        #expect(reply.code == 250)
        #expect(reply.text == "PIPELINING\nAUTH PLAIN LOGIN")
        #expect(try parser.nextReply() == nil)
    }

    @Test func replyLinesSplitAndCoalescedAcrossReads() throws {
        var parser = SMTPReplyParser()
        parser.append(Data("250-smtp.example".utf8))
        #expect(try parser.nextReply() == nil)
        parser.append(Data(".com\r\n250 SIZE".utf8))
        #expect(try parser.nextReply() == nil)
        parser.append(Data(" 1000\r\n220 2.0.0 Ready\r\n235".utf8))
        let first = try #require(try parser.nextReply())
        #expect(first.code == 250 && first.text == "smtp.example.com\nSIZE 1000")
        let second = try #require(try parser.nextReply())
        #expect(second.code == 220 && second.text == "2.0.0 Ready")
        #expect(try parser.nextReply() == nil)
        parser.append(Data("\r\n".utf8))
        let third = try #require(try parser.nextReply())
        #expect(third.code == 235 && third.text == "")
    }

    @Test func discardBufferedDropsBytesFromBeforeTLS() throws {
        var parser = SMTPReplyParser()
        parser.append(Data("250-partial\r\n250 injected\r\n".utf8))
        parser.discardBuffered()
        #expect(try parser.nextReply() == nil)
        parser.append(Data("250 fresh\r\n".utf8))
        #expect(try parser.nextReply()?.text == "fresh")
    }

    @Test func malformedReplyThrows() {
        var parser = SMTPReplyParser()
        parser.append(Data("hello there\r\n".utf8))
        #expect(throws: SMTPTransportError.self) { try parser.nextReply() }
    }

    @Test func providerPresets() {
        let mb = 1_048_576
        #expect(Provider.allCases == [.icloud, .gmail, .fastmail, .yahoo, .custom])
        #expect(Provider.icloud.preset! == (host: "smtp.mail.me.com", port: 587, maxBytes: 20 * mb))
        #expect(Provider.gmail.preset! == (host: "smtp.gmail.com", port: 465, maxBytes: 25 * mb))
        #expect(Provider.fastmail.preset! == (host: "smtp.fastmail.com", port: 465, maxBytes: 50 * mb))
        #expect(Provider.yahoo.preset! == (host: "smtp.mail.yahoo.com", port: 465, maxBytes: 25 * mb))
        #expect(Provider.custom.preset == nil)
        #expect(Provider.customMaxBytes == 50 * mb)
        #expect(Provider.allCases.map(\.displayName) == ["iCloud Mail", "Gmail", "Fastmail", "Yahoo Mail", "Other SMTP server"])
        #expect(Provider.allCases.map(\.appPasswordHelpURL?.absoluteString) == [
            "https://account.apple.com",
            "https://myaccount.google.com/apppasswords",
            "https://app.fastmail.com/settings/security/apppasswords",
            "https://login.yahoo.com/myaccount/security/app-password",
            nil,
        ])
    }

    @Test func securityFollowsPort() {
        #expect(Self.gmail.security == .implicitTLS)
        #expect(Self.icloud.security == .startTLS)
        var custom = Self.icloud
        custom.port = 25
        #expect(custom.security == .startTLS)
    }
}

/// Exercises `StreamTaskSMTPTransport` over plain TCP against a local server (no TLS, no real accounts).
@Suite struct StreamTaskSMTPTransportTests {
    @Test func readsRepliesSplitAcrossPackets() async throws {
        let server = try await LocalServer.start { connection in
            connection.sendChunks(["220-first", " line\r\n220 sec", "ond\r\n"], delay: 0.05)
        }
        defer { server.stop() }
        let transport = StreamTaskSMTPTransport(timeout: 5)
        try await transport.connect(host: "127.0.0.1", port: server.port, tlsImmediately: false)

        let reply = try await transport.readReply()

        #expect(reply.code == 220 && reply.text == "first line\nsecond")
        await transport.close()
    }

    @Test func writesLinesWithCRLF() async throws {
        let received = Mutex(Data())
        let server = try await LocalServer.start { connection in
            connection.sendChunks(["220 hi\r\n"], delay: 0)
            connection.receiveLine { data in
                received.withLock { $0 = data }
                connection.sendChunks(["250 ok\r\n"], delay: 0)
            }
        }
        defer { server.stop() }
        let transport = StreamTaskSMTPTransport(timeout: 5)
        try await transport.connect(host: "127.0.0.1", port: server.port, tlsImmediately: false)
        _ = try await transport.readReply()

        try await transport.writeLine("EHLO kindlesend.local")
        let reply = try await transport.readReply()

        #expect(reply.code == 250)
        #expect(received.withLock { $0 } == Data("EHLO kindlesend.local\r\n".utf8))
        await transport.close()
    }

    @Test func connectionClosedThrowsWithStage() async throws {
        let server = try await LocalServer.start { connection in
            connection.sendChunks(["220 hi\r\n"], delay: 0)
            connection.receiveLine { _ in connection.cancel() }
        }
        defer { server.stop() }
        let account = SMTPAccount(host: "127.0.0.1", port: server.port, user: "u", from: "u@x", maxBytes: 1)
        let client = SMTPClient(account: account, password: "secret", transport: { StreamTaskSMTPTransport(timeout: 5) })

        let error = try await #require(throws: SMTPError.self) { try await client.verifyLogin() }

        #expect(error.stage == "EHLO")
        #expect(error.errorDescription?.contains("closed") == true)
    }

    @Test func silentServerTimesOut() async throws {
        let server = try await LocalServer.start { _ in }
        defer { server.stop() }
        let account = SMTPAccount(host: "127.0.0.1", port: server.port, user: "u", from: "u@x", maxBytes: 1)
        let client = SMTPClient(account: account, password: "secret", transport: { StreamTaskSMTPTransport(timeout: 0.5) })

        let error = try await #require(throws: SMTPError.self) { try await client.verifyLogin() }

        #expect(error.stage == "CONNECT")
        #expect(error.serverText == SMTPTransportError.timedOut.errorDescription)
    }

    @Test func defaultReplyTimeoutIsSixtySeconds() {
        #expect(StreamTaskSMTPTransport.defaultTimeout == 60)
    }
}

/// A plain-TCP server on 127.0.0.1 that hands each accepted connection to `handler`.
final class LocalServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalServer")
    let port: Int

    private init(listener: NWListener, port: Int) {
        self.listener = listener
        self.port = port
    }

    static func start(_ handler: @escaping @Sendable (NWConnection) -> Void) async throws -> LocalServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "LocalServer.listener")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            handler(connection)
        }
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let result: Result<Int, Error>? = switch state {
                case .ready: .success(Int(listener.port!.rawValue))
                case let .failed(error): .failure(error)
                default: nil
                }
                guard let result, resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            listener.start(queue: queue)
        }
        return LocalServer(listener: listener, port: port)
    }

    func stop() { listener.cancel() }
}

extension NWConnection {
    func sendChunks(_ chunks: [String], delay: TimeInterval) {
        guard let first = chunks.first else { return }
        send(content: Data(first.utf8), completion: .contentProcessed { _ in
            Thread.sleep(forTimeInterval: delay)
            self.sendChunks(Array(chunks.dropFirst()), delay: delay)
        })
    }

    /// Receives bytes until a CRLF arrives, then calls `done` with everything received.
    func receiveLine(_ done: @escaping @Sendable (Data) -> Void, received: Data = Data()) {
        receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
            let all = received + (data ?? Data())
            if all.suffix(2) == Data("\r\n".utf8) || error != nil {
                done(all)
            } else {
                self.receiveLine(done, received: all)
            }
        }
    }
}
