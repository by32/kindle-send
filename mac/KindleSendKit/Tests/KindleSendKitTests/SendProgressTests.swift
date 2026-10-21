import Foundation
import Testing
@testable import KindleSendKit

@MainActor @Suite struct SendProgressTests {
    private static let cover = URL(string: "https://example.com/c.jpg")!
    private static let when = Date(timeIntervalSince1970: 1_800_000_000)

    private static func stores(_ ids: [String]) -> (QueueStore, SendHistory) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = QueueStore(fileURL: dir.appendingPathComponent("queue.json"))
        for id in ids {
            queue.add(Edition(id: id, source: .gutenberg, title: "Book \(id)", authors: [], languages: ["en"],
                              subjects: [], coverURL: cover))
        }
        return (queue, SendHistory(fileURL: dir.appendingPathComponent("history.json")))
    }

    @Test func summaryText() {
        #expect(SendProgress.Summary(sent: 3, failed: 1).text == "3 sent, 1 failed")
        #expect(SendProgress.Summary(sent: 0, failed: 2).text == "0 sent, 2 failed")
        #expect(SendProgress.Summary(sent: 1, failed: 0).text == "1 sent, 0 failed")
    }

    @Test func sentRecordsHistoryAndLeavesQueue() {
        let (queue, history) = Self.stores(["pg:1", "pg:2", "pg:3"])
        var progress = SendProgress()
        progress.apply(.sent(ids: ["pg:1", "pg:3"]), queue: queue, history: history, at: Self.when)

        #expect(queue.items.map(\.id) == ["pg:2"])
        #expect(history.sentDate(id: "pg:1") == Self.when)
        #expect(history.sentDate(id: "pg:3") == Self.when)
        #expect(!history.wasSent(id: "pg:2"))
        #expect(progress.status["pg:1"] == .sent(ids: ["pg:1", "pg:3"]))
    }

    @Test func failedKeepsItemWithError() {
        let (queue, history) = Self.stores(["pg:1"])
        var progress = SendProgress()
        progress.apply(.failed(id: "pg:1", message: "too big"), queue: queue, history: history, at: Self.when)

        #expect(queue.items.first?.lastError == "too big")
        #expect(!history.wasSent(id: "pg:1"))
        #expect(progress.status["pg:1"] == .failed(id: "pg:1", message: "too big"))
    }

    @Test func progressEventsOnlyUpdateStatus() {
        let (queue, history) = Self.stores(["pg:1", "pg:2"])
        var progress = SendProgress()
        progress.apply(.downloading(id: "pg:1"), queue: queue, history: history, at: Self.when)
        #expect(progress.status["pg:1"] == .downloading(id: "pg:1"))

        let sending = SendEvent.sending(ids: ["pg:1", "pg:2"], batch: 1, of: 1)
        progress.apply(sending, queue: queue, history: history, at: Self.when)
        #expect(progress.status["pg:1"] == sending)
        #expect(progress.status["pg:2"] == sending)

        progress.apply(.finished(sent: 0, failed: 0), queue: queue, history: history, at: Self.when)
        #expect(progress.summary == SendProgress.Summary(sent: 0, failed: 0))
        #expect(queue.items.count == 2)
        #expect(!history.wasSent(id: "pg:1"))
    }
}
