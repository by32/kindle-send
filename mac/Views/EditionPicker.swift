import KindleSendKit
import SwiftUI

/// Lists a work's editions so one other than the default can be queued.
struct EditionPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let work: Work

    @State private var selection: Edition.ID?
    @State private var resend: Edition?

    private var selected: Edition? {
        work.editions.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(work.defaultEdition.title).font(.headline)
                Text(work.editions.count == 1 ? "1 edition" : "\(work.editions.count) editions")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            List(work.editions, selection: $selection) { edition in
                EditionRow(edition: edition,
                           isQueued: model.queue.contains(id: edition.id),
                           isSent: model.history.wasSent(id: edition.id))
                    .tag(edition.id)
            }
            .listStyle(.inset)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(addTitle) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.map { model.queue.contains(id: $0.id) } ?? true)
            }
            .padding()
        }
        .frame(width: 480, height: 400)
        .onAppear { if selection == nil { selection = work.editions.first?.id } }
        .confirmResend($resend, history: model.history) { edition in
            model.queue.add(edition)
            dismiss()
        }
    }

    private var addTitle: String {
        if let selected, model.queue.contains(id: selected.id) { "In Queue" } else { "Add to Queue" }
    }

    private func add() {
        guard let edition = selected, !model.queue.contains(id: edition.id) else { return }
        if model.history.wasSent(id: edition.id) {
            resend = edition
        } else {
            model.queue.add(edition)
            dismiss()
        }
    }
}

private struct EditionRow: View {
    let edition: Edition
    let isQueued: Bool
    let isSent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CoverImage(url: edition.coverURL, title: edition.title, compact: true)
                .frame(width: 32, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    SourceBadge(source: edition.source)
                    if isQueued { Text("In Queue").font(.caption2).foregroundStyle(.secondary) }
                    if isSent { Text("Sent").font(.caption2.weight(.semibold)).foregroundStyle(.green) }
                }
                Text(edition.title).font(.body.weight(.medium)).lineLimit(2)
                if !edition.authors.isEmpty {
                    Text(edition.authors.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                }
                if let credits = edition.credits, !credits.isEmpty {
                    Text(credits).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts: [String] = []
        if let issued = edition.issued, !issued.isEmpty { parts.append("Released \(issued)") }
        if edition.downloads > 0 { parts.append("\(edition.downloads.formatted()) downloads") }
        return parts.joined(separator: " · ")
    }
}

private struct SourceBadge: View {
    let source: Source

    var body: some View {
        Text(source == .standardEbooks ? "Standard Ebooks" : "Gutenberg")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(source == .standardEbooks ? Color.white : Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(source == .standardEbooks ? Color.accentColor : Color.secondary.opacity(0.2)))
    }
}

extension View {
    /// Asks "Already sent on {date}. Send again?" while `edition` is set; `confirm` re-queues it.
    func confirmResend(_ edition: Binding<Edition?>, history: SendHistory,
                       confirm: @escaping (Edition) -> Void) -> some View {
        let date = edition.wrappedValue.flatMap { history.sentDate(id: $0.id) }
        let title = date.map { "Already sent on \($0.formatted(date: .abbreviated, time: .omitted)). Send again?" }
            ?? "Already sent. Send again?"
        return alert(title, isPresented: Binding(
            get: { edition.wrappedValue != nil }, set: { if !$0 { edition.wrappedValue = nil } }
        ), presenting: edition.wrappedValue) { e in
            Button("Add to Queue") { confirm(e) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
