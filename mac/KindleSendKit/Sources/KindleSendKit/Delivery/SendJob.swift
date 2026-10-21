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
    let downloader: EditionDownloader
    let mailer: MailSending
    let from: String
    let to: String
    let maxBytes: Int

    public init(downloader: EditionDownloader, mailer: MailSending, from: String, to: String, maxBytes: Int) {
        self.downloader = downloader
        self.mailer = mailer
        self.from = from
        self.to = to
        self.maxBytes = maxBytes
    }

    /// Pull-based: each `next()` on the stream advances the job by exactly one step, so once the
    /// consumer stops iterating nothing further is downloaded, built or sent.
    public func run(_ editions: [Edition]) -> AsyncStream<SendEvent> {
        let run = Run(job: self, editions: editions)
        return AsyncStream(unfolding: { await run.next() })
    }

    /// The job's state machine. An actor so the unfolding closure can capture it safely.
    private actor Run {
        enum Phase {
            case download(Int)
            case finishDownload(Int)
            case sendBatch(Int)
            case finishSend(Int)
            case done
        }

        let job: SendJob
        let editions: [Edition]
        var phase = Phase.download(0)
        var pending: [SendEvent] = []
        var downloaded: [(edition: Edition, attachment: Attachment)] = []
        // Batches as ranges into `downloaded`, so ids map back by position, never by filename.
        var batchRanges: [Range<Int>] = []
        var sentCount = 0
        var failedCount = 0

        init(job: SendJob, editions: [Edition]) {
            self.job = job
            self.editions = editions
        }

        func next() async -> SendEvent? {
            while pending.isEmpty {
                if Task.isCancelled { phase = .done }
                if case .done = phase { return nil }
                await step()
            }
            return pending.removeFirst()
        }

        private func step() async {
            switch phase {
            case let .download(i):
                guard i < editions.count else {
                    let batches = Batching.batches(downloaded.map(\.attachment), maxBytes: job.maxBytes)
                    var offset = 0
                    for batch in batches {
                        batchRanges.append(offset..<offset + batch.count)
                        offset += batch.count
                    }
                    phase = .sendBatch(0)
                    return
                }
                pending.append(.downloading(id: editions[i].id))
                phase = .finishDownload(i)
            case let .finishDownload(i):
                let edition = editions[i]
                do {
                    downloaded.append((edition, try await job.downloader.download(edition, maxBytes: job.maxBytes)))
                } catch {
                    failedCount += 1
                    pending.append(.failed(id: edition.id, message: SendJob.message(for: error)))
                }
                phase = .download(i + 1)
            case let .sendBatch(k):
                guard k < batchRanges.count else {
                    pending.append(.finished(sent: sentCount, failed: failedCount))
                    phase = .done
                    return
                }
                let ids = downloaded[batchRanges[k]].map(\.edition.id)
                pending.append(.sending(ids: ids, batch: k + 1, of: batchRanges.count))
                phase = .finishSend(k)
            case let .finishSend(k):
                let members = downloaded[batchRanges[k]]
                let ids = members.map(\.edition.id)
                let subject = members.count == 1 ? members.first!.edition.title : "\(members.count) books"
                let message = MIMEMessage.build(
                    from: job.from, to: job.to, subject: subject, attachments: members.map(\.attachment))
                do {
                    try await job.mailer.send(from: job.from, to: job.to, message: message)
                    sentCount += ids.count
                    pending.append(.sent(ids: ids))
                } catch {
                    for id in ids {
                        failedCount += 1
                        pending.append(.failed(id: id, message: SendJob.message(for: error)))
                    }
                }
                phase = .sendBatch(k + 1)
            case .done:
                break
            }
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
