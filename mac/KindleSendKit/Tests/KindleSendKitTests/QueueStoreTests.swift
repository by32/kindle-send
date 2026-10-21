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
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let quarantined = try #require(siblings.first { $0.hasPrefix("queue.json.corrupt-") })
        let kept = try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(quarantined))
        #expect(kept == Data("{not json".utf8))
        #expect(!FileManager.default.fileExists(atPath: url.path))
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

    @Test func removeManyPersistsOnce() {
        let url = Self.tempFile()
        let queue = QueueStore(fileURL: url)
        for n in 1...4 { queue.add(Self.edition("pg:\(n)")) }
        queue.remove(ids: ["pg:1", "pg:3", "pg:99"])
        #expect(queue.items.map(\.id) == ["pg:2", "pg:4"])
        #expect(QueueStore(fileURL: url).items.map(\.id) == ["pg:2", "pg:4"])
    }

    /// A path whose parent is a regular file, so every write fails.
    private static func unwritableFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let blocker = dir.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        return blocker.appendingPathComponent("queue.json")
    }

    @Test func queueSaveFailureIsVisible() throws {
        let queue = QueueStore(fileURL: try Self.unwritableFile())
        queue.add(Self.edition("pg:1"))
        #expect(queue.lastSaveError != nil)
        #expect(queue.contains(id: "pg:1"))
    }

    @Test func historySaveFailureIsVisible() throws {
        let history = SendHistory(fileURL: try Self.unwritableFile())
        history.record(ids: ["pg:1"], on: .now)
        #expect(history.lastSaveError != nil)
        #expect(history.wasSent(id: "pg:1"))
    }

    @Test func saveErrorClearsAfterSuccess() {
        let queue = QueueStore(fileURL: Self.tempFile())
        queue.add(Self.edition("pg:1"))
        #expect(queue.lastSaveError == nil)
    }
}
