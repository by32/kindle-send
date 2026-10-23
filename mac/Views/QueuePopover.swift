import KindleSendKit
import SwiftUI

/// The toolbar popover: queued books, the send button and where the books go.
struct QueuePopover: View {
    @Environment(AppModel.self) private var model
    /// The rows as they were when Send was pressed, so sent books show ✓ until the send ends
    /// (a sent book leaves the queue right away).
    @State private var sendingRows: [QueueItem] = []
    @State private var sentHere = false

    private var rows: [QueueItem] {
        guard model.isSending, !sendingRows.isEmpty else { return model.queue.items }
        let snapshot = Set(sendingRows.map(\.id))
        let current = Dictionary(model.queue.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return sendingRows.map { current[$0.id] ?? $0 } + model.queue.items.filter { !snapshot.contains($0.id) }
    }

    private var canSend: Bool {
        model.settings.account != nil && model.settings.isValidKindleEmail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .font(.caption)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { item in
                            QueueRow(item: item, event: model.isSending ? model.sendEvents[item.id] : nil,
                                     isSending: model.isSending, isQueued: model.queue.contains(id: item.id)) {
                                model.queue.remove(id: item.id)
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let summary = failureSummary {
                Label(summary, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if let error = model.sendError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Button {
                sendingRows = model.queue.items
                sentHere = true
                Task { await model.sendQueue() }
            } label: {
                Group {
                    if model.isSending {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Sending…")
                        }
                    } else {
                        Text("Send \(model.queue.items.count) to Kindle")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSend || model.isSending || model.queue.items.isEmpty)
            .accessibilityLabel(model.isSending ? "Sending" : "Send \(model.queue.items.count) to Kindle")

            VStack(spacing: 3) {
                if canSend {
                    Text("\(model.settings.kindleEmail) · via \(model.settings.provider.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Books arrive in your Kindle library under Docs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    SettingsLink { Text("Set up sending in Settings") }
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(width: 320)
        .onChange(of: model.isSending) { _, sending in
            if !sending { sendingRows = [] }
        }
    }

    private var header: String {
        let n = model.queue.items.count
        return n == 1 ? "Queue · 1 book" : "Queue · \(n) books"
    }

    /// "3 sent, 1 failed" after a send whose failed books are still in the queue.
    private var failureSummary: String? {
        guard !model.isSending, let summary = model.sendProgress.summary, summary.failed > 0,
              model.queue.items.contains(where: { $0.lastError != nil }) else { return nil }
        return summary.text
    }

    private var emptyText: String {
        if sentHere, !model.isSending, let summary = model.sendProgress.summary, summary.sent > 0 {
            return summary.sent == 1 ? "Sent 1 book to your Kindle." : "Sent \(summary.sent) books to your Kindle."
        }
        return "Add books with the ＋ on a cover."
    }
}

private struct QueueRow: View {
    let item: QueueItem
    /// The latest send event for this book while a send runs.
    let event: SendEvent?
    let isSending: Bool
    /// False once a sent book has left the queue.
    let isQueued: Bool
    let remove: () -> Void

    private var edition: Edition { item.edition }

    /// Why this book failed: the current send's failure, else the one kept from the last send.
    private var errorMessage: String? {
        if case let .failed(_, message) = event { return message }
        return item.lastError
    }

    var body: some View {
        HStack(spacing: 8) {
            CoverImage(url: edition.coverURL, title: edition.title, compact: true)
                .frame(width: 24, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            VStack(alignment: .leading, spacing: 1) {
                Text(edition.title).font(.callout).lineLimit(1)
                Text(edition.authors.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder private var trailing: some View {
        switch event {
        case .downloading:
            status("Downloading…")
        case .sending:
            status("Sending…")
        case .sent:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Sent")
        case let .failed(_, message):
            failure(message)
        case .finished, nil:
            if isSending {
                if isQueued && item.lastError == nil {
                    Text("Waiting").font(.caption).foregroundStyle(.secondary)
                } else if let error = item.lastError {
                    failure(error)
                }
            } else {
                HStack(spacing: 6) {
                    if let error = item.lastError { failure(error) }
                    Button(action: remove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Remove from Queue")
                    .accessibilityLabel("Remove \(edition.title) from Queue")
                }
            }
        }
    }

    private func status(_ text: String) -> some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func failure(_ message: String) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .help(message)
            .accessibilityLabel("Failed: \(message)")
    }
}
