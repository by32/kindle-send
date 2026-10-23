import Foundation
import Synchronization
import Testing
@testable import KindleSendKit

private struct MailerError: Error, LocalizedError {
    var errorDescription: String? { "550 mailbox full" }
}

/// Records each send; throws on the call numbers in `failingCalls` (1-based).
private final class FakeMailer: MailSending {
    private let calls = Mutex<[Data]>([])
    let failingCalls: Set<Int>
    init(failingCalls: Set<Int> = []) { self.failingCalls = failingCalls }
    var callCount: Int { calls.withLock { $0.count } }

    func send(from: String, to: String, message: Data) async throws {
        let n = calls.withLock { $0.append(message); return $0.count }
        if failingCalls.contains(n) { throw MailerError() }
    }
}

@Suite struct SendJobTests {
    private static let mb = 1_048_576
    private static let cover = URL(string: "https://example.com/c.jpg")!
    private static func edition(_ n: Int, _ title: String) -> Edition {
        Edition(id: "pg:\(n)", source: .gutenberg, title: title, authors: ["Ann Author"], languages: ["en"],
                subjects: [], coverURL: cover)
    }

    private static func collect(_ stream: AsyncStream<SendEvent>) async -> [SendEvent] {
        var events: [SendEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test func partialFailureKeepsOnlyFailedInQueue() async throws {
        let (a, b, c, d) = (Self.edition(1, "A"), Self.edition(2, "B"), Self.edition(3, "C"), Self.edition(4, "D"))
        let http = FakeHTTPClient { url in
            if url.absoluteString.contains("/ebooks/2.") { throw HTTPError.status(404, url) }
            return epubData(Self.mb)
        }
        let mailer = FakeMailer(failingCalls: [2])
        let job = SendJob(downloader: EditionDownloader(http: http), mailer: mailer,
                          from: "me@x.com", to: "k@kindle.com", maxBytes: 2_500_000)
        let events = await Self.collect(job.run([a, b, c, d]))

        #expect(events.contains(.failed(id: "pg:2", message: "Download failed (HTTP 404)")))
        #expect(events.contains(.sent(ids: ["pg:1"])))
        #expect(events.contains(.failed(id: "pg:3", message: "550 mailbox full")))
        #expect(events.contains(.sent(ids: ["pg:4"])))
        #expect(events.last == .finished(sent: 2, failed: 2))
        #expect(events.contains(.sending(ids: ["pg:3"], batch: 2, of: 3)))
        #expect(mailer.callCount == 3)

        // Exactly one terminal event per edition id; each .sent follows its batch's .sending.
        var terminal: [String: Int] = [:]
        for event in events {
            switch event {
            case let .sent(ids): for id in ids { terminal[id, default: 0] += 1 }
            case let .failed(id, _): terminal[id, default: 0] += 1
            default: break
            }
        }
        #expect(terminal == ["pg:1": 1, "pg:2": 1, "pg:3": 1, "pg:4": 1])
        for (i, event) in events.enumerated() {
            if case let .sent(ids) = event {
                let sendingIndex = events.firstIndex { if case .sending(ids, _, _) = $0 { true } else { false } }
                #expect(try #require(sendingIndex) < i)
            }
        }
    }

    @Test func emptyInputFinishesImmediately() async {
        let mailer = FakeMailer()
        let job = SendJob(downloader: EditionDownloader(http: FakeHTTPClient { _ in Data() }), mailer: mailer,
                          from: "me@x.com", to: "k@kindle.com", maxBytes: 20 * Self.mb)
        let events = await Self.collect(job.run([]))
        #expect(events == [.finished(sent: 0, failed: 0)])
        #expect(mailer.callCount == 0)
    }

    @Test func allDownloadsFail() async {
        let http = FakeHTTPClient { url in throw HTTPError.status(500, url) }
        let mailer = FakeMailer()
        let job = SendJob(downloader: EditionDownloader(http: http), mailer: mailer,
                          from: "me@x.com", to: "k@kindle.com", maxBytes: 20 * Self.mb)
        let events = await Self.collect(job.run([Self.edition(1, "A"), Self.edition(2, "B")]))
        let failures = events.filter { if case .failed = $0 { true } else { false } }
        #expect(failures.count == 2)
        #expect(events.last == .finished(sent: 0, failed: 2))
        #expect(mailer.callCount == 0)
    }

    @Test func stoppingEarlyCancelsRemainingBatches() async {
        let http = FakeHTTPClient { _ in epubData(Self.mb) }
        let mailer = FakeMailer()
        let job = SendJob(downloader: EditionDownloader(http: http), mailer: mailer,
                          from: "me@x.com", to: "k@kindle.com", maxBytes: 2_500_000)
        let editions = (1...4).map { Self.edition($0, "B\($0)") }
        for await event in job.run(editions) {
            if case .sent = event { break }
        }
        // Pull-based: nothing runs after the consumer stops, so this holds with no waiting.
        #expect(mailer.callCount == 1)
    }

    @Test func oversizeBookFailsClearly() async {
        let http = FakeHTTPClient { _ in epubData(30 * Self.mb) }
        let mailer = FakeMailer()
        let job = SendJob(downloader: EditionDownloader(http: http), mailer: mailer,
                          from: "me@x.com", to: "k@kindle.com", maxBytes: 20 * Self.mb)
        let events = await Self.collect(job.run([Self.edition(1, "Huge")]))

        #expect(events.contains(.failed(id: "pg:1", message: "Too large to email (41.1 MB > 20 MB cap)")))
        #expect(events.last == .finished(sent: 0, failed: 1))
        #expect(mailer.callCount == 0)
    }

    @Test func sameFilenameEditionsStayDistinct() async {
        // Two editions with identical title/author produce the same filename; ids must still map correctly.
        let (a, b) = (Self.edition(1, "Same"), Self.edition(2, "Same"))
        let http = FakeHTTPClient { _ in epubData(1000) }
        let mailer = FakeMailer()
        let job = SendJob(downloader: EditionDownloader(http: http), mailer: mailer,
                          from: "me@x.com", to: "k@kindle.com", maxBytes: 20 * Self.mb)
        let events = await Self.collect(job.run([a, b]))
        #expect(events.contains(.sent(ids: ["pg:1", "pg:2"])))
        #expect(mailer.callCount == 1)
    }
}
