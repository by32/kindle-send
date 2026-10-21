import Foundation

public enum SendEvent: Sendable, Equatable {
    case downloading(id: String)
    case sending(ids: [String], batch: Int, of: Int)
    case sent(ids: [String])
    case failed(id: String, message: String)
    case finished(sent: Int, failed: Int)
}

public protocol MailSending: Sendable {
    func send(from: String, to: String, message: Data) async throws
}

extension SMTPClient: MailSending {}

/// Downloads, batches and emails editions. A failure in one book or batch never stops the rest,
/// and each id is reported as sent or failed exactly once.
public struct SendJob: Sendable {
    private let downloader: EditionDownloader
    private let mailer: MailSending
    private let from: String
    private let to: String
    private let maxBytes: Int

    public init(downloader: EditionDownloader, mailer: MailSending, from: String, to: String, maxBytes: Int) {
        self.downloader = downloader
        self.mailer = mailer
        self.from = from
        self.to = to
        self.maxBytes = maxBytes
    }

    public func run(_ editions: [Edition]) -> AsyncStream<SendEvent> {
        AsyncStream { continuation in
            let task = Task {
                await execute(editions, emit: {
                    if case .terminated = continuation.yield($0) { return false }
                    return true
                })
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(_ editions: [Edition], emit: (SendEvent) -> Bool) async {
        var sentCount = 0
        var failedCount = 0

        // Kept in lockstep so batches map back to editions by position, never by filename.
        var downloaded: [(edition: Edition, attachment: Attachment)] = []
        for edition in editions {
            if Task.isCancelled { return }
            guard emit(.downloading(id: edition.id)) else { return }
            do {
                downloaded.append((edition, try await downloader.download(edition, maxBytes: maxBytes)))
            } catch {
                failedCount += 1
                guard emit(.failed(id: edition.id, message: Self.message(for: error))) else { return }
            }
        }

        let batches = Batching.batches(downloaded.map(\.attachment), maxBytes: maxBytes)
        var offset = 0
        for (index, batch) in batches.enumerated() {
            if Task.isCancelled { return }
            let members = downloaded[offset..<offset + batch.count]
            offset += batch.count
            let ids = members.map(\.edition.id)
            guard emit(.sending(ids: ids, batch: index + 1, of: batches.count)) else { return }
            let subject = batch.count == 1 ? members.first!.edition.title : "\(batch.count) books"
            let message = MIMEMessage.build(from: from, to: to, subject: subject, attachments: batch)
            do {
                try await mailer.send(from: from, to: to, message: message)
                sentCount += ids.count
                guard emit(.sent(ids: ids)) else { return }
                // Let a consumer that has stopped listening cancel us before the next batch is sent.
                await Task.yield()
            } catch {
                for id in ids {
                    failedCount += 1
                    guard emit(.failed(id: id, message: Self.message(for: error))) else { return }
                }
            }
        }
        _ = emit(.finished(sent: sentCount, failed: failedCount))
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
