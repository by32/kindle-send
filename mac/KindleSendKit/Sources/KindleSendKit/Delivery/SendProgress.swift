import Foundation

/// What a running send has reported so far, and the bookkeeping each event implies:
/// sent books are recorded in the history and leave the queue; failed books stay with their error.
public struct SendProgress: Sendable, Equatable {
    public struct Summary: Sendable, Equatable {
        public var sent: Int
        public var failed: Int

        public init(sent: Int, failed: Int) {
            self.sent = sent
            self.failed = failed
        }

        /// e.g. "3 sent, 1 failed".
        public var text: String { "\(sent) sent, \(failed) failed" }
    }

    /// The latest event for each edition id.
    public private(set) var status: [String: SendEvent] = [:]
    /// Set by `.finished`.
    public private(set) var summary: Summary?

    public init() {}

    @MainActor
    public mutating func apply(_ event: SendEvent, queue: QueueStore, history: SendHistory, at date: Date) {
        switch event {
        case let .downloading(id):
            status[id] = event
        case let .sending(ids, _, _):
            for id in ids { status[id] = event }
        case let .sent(ids):
            for id in ids { status[id] = event }
            history.record(ids: ids, on: date)
            queue.remove(ids: ids)
        case let .failed(id, message):
            status[id] = event
            queue.setError(message, for: id)
        case let .finished(sent, failed):
            summary = Summary(sent: sent, failed: failed)
        }
    }
}
