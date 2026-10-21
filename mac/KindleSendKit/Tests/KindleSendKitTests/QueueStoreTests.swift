import Foundation
import Testing
@testable import KindleSendKit

@MainActor @Suite struct QueueStoreTests {
    private static let cover = URL(string: "https://example.com/c.jpg")!
    private static func edition(_ id: String) -> Edition {
        Edition(id: id, source: .gutenberg, title: "Book \(id)", authors: ["A B"], languages: ["en"],
                subjects: [], coverURL: cover)
    }

    private static func tempFile(_ name: String = "queue.json") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
    }

    @Test func persistsAcrossInstances() {
        let url = Self.tempFile()
        let queue = QueueStore(fileURL: url)
        queue.add(Self.edition("pg:1"))
        queue.add(Self.edition("pg:2"))
        queue.setError("boom", for: "pg:2")
        queue.remove(id: "pg:1")

        let reloaded = QueueStore(fileURL: url)
        #expect(reloaded.items.map(\.id) == ["pg:2"])
        #expect(reloaded.items.first?.lastError == "boom")
        #expect(reloaded.contains(id: "pg:2"))
        #expect(!reloaded.contains(id: "pg:1"))
    }

    @Test func addIsIdempotent() {
        let queue = QueueStore(fileURL: Self.tempFile())
        queue.add(Self.edition("pg:1"))
        queue.add(Self.edition("pg:1"))
        #expect(queue.items.count == 1)
    }

    @Test func corruptFileLoadsEmpty() throws {
        let url = Self.tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        #expect(QueueStore(fileURL: url).items.isEmpty)
        #expect(!SendHistory(fileURL: url).wasSent(id: "pg:1"))
        #expect(QueueStore(fileURL: Self.tempFile()).items.isEmpty)
    }

    @Test func historyRecordsAndPersistsDates() {
        let url = Self.tempFile("history.json")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let history = SendHistory(fileURL: url)
        #expect(history.sentDate(id: "pg:1") == nil)
        history.record(ids: ["pg:1", "pg:2"], on: date)

        let reloaded = SendHistory(fileURL: url)
        #expect(reloaded.wasSent(id: "pg:1"))
        #expect(reloaded.sentDate(id: "pg:2") == date)
        #expect(reloaded.sentDate(id: "pg:3") == nil)
        #expect(!reloaded.wasSent(id: "pg:3"))
    }
}
