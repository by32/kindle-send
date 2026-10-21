import Foundation
import Observation

public struct QueueItem: Codable, Hashable, Sendable, Identifiable {
    public var edition: Edition
    public var addedAt: Date
    public var lastError: String?
    public var id: String { edition.id }
}

/// The books waiting to be sent. Persisted after every change.
@MainActor @Observable
public final class QueueStore {
    public private(set) var items: [QueueItem]
    @ObservationIgnored private let store: JSONFileStore<[QueueItem]>

    public init(fileURL: URL) {
        store = JSONFileStore(fileURL: fileURL)
        items = store.load() ?? []
    }

    public func add(_ e: Edition) {
        guard !contains(id: e.id) else { return }
        items.append(QueueItem(edition: e, addedAt: .now, lastError: nil))
        persist()
    }

    public func remove(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    public func contains(id: String) -> Bool {
        items.contains { $0.id == id }
    }

    public func setError(_ msg: String?, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].lastError = msg
        persist()
    }

    private func persist() {
        try? store.save(items)
    }
}
