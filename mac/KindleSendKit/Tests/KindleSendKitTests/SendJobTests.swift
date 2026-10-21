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

    @Test func partialFailureKeepsOnlyFailedInQueue() async {
        let (a, b, c, d) = (Self.edition(1, "A"), Self.edition(2, "B"), Self.edition(3, "C"), Self.edition(4, "D"))
        let http = FakeHTTPClient { url in
            if url.absoluteString.contains("/ebooks/2.") { throw HTTPError.status(404, url) }
            return Data(count: Self.mb)
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
    }

    @Test func oversizeBookFailsClearly() async {
        let http = FakeHTTPClient { _ in Data(count: 30 * Self.mb) }
        let mailer = FakeMailer()
        let job = SendJob(downloader: EditionDownloader(http: http), mailer: mailer,
                          from: "me@x.com", to: "k@kindle.com", maxBytes: 20 * Self.mb)
        let events = await Self.collect(job.run([Self.edition(1, "Huge")]))

        #expect(events.contains(.failed(id: "pg:1", message: "Too large to email (30.0 MB > 20 MB cap)")))
        #expect(events.last == .finished(sent: 0, failed: 1))
        #expect(mailer.callCount == 0)
    }

    @Test func sameFilenameEditionsStayDistinct() async {
        // Two editions with identical title/author produce the same filename; ids must still map correctly.
        let (a, b) = (Self.edition(1, "Same"), Self.edition(2, "Same"))
        let http = FakeHTTPClient { _ in Data(count: 1000) }
        let mailer = FakeMailer()
        let job = SendJob(downloader: EditionDownloader(http: http), mailer: mailer,
                          from: "me@x.com", to: "k@kindle.com", maxBytes: 20 * Self.mb)
        let events = await Self.collect(job.run([a, b]))
        #expect(events.contains(.sent(ids: ["pg:1", "pg:2"])))
        #expect(mailer.callCount == 1)
    }
}
