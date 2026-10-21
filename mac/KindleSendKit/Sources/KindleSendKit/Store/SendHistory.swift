import Foundation
import Observation

/// Which editions have already been emailed, and when. Persisted after every change.
@MainActor @Observable
public final class SendHistory {
    private var sent: [String: Date]
    @ObservationIgnored private let store: JSONFileStore<[String: Date]>

    public init(fileURL: URL) {
        store = JSONFileStore(fileURL: fileURL)
        sent = store.load() ?? [:]
    }

    public func wasSent(id: String) -> Bool {
        sent[id] != nil
    }

    public func sentDate(id: String) -> Date? {
        sent[id]
    }

    public func record(ids: [String], on date: Date) {
        for id in ids { sent[id] = date }
        try? store.save(sent)
    }
}
