import KindleSendKit
import SwiftUI

/// The main window: toolbar search, category chips and the cover grid, with the queue in a
/// toolbar popover.
struct BrowseView: View {
    @Environment(AppModel.self) private var model
    @State private var showingQueue = false

    private static let topID = "top"

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                CategoryChips()
                ResultsGrid(topID: Self.topID)
                    .overlay {
                        if model.results.isEmpty && !model.query.text.isEmpty {
                            ContentUnavailableView.search(text: model.query.text)
                        }
                    }
            }
            .onChange(of: model.query) {
                model.updateSearch()
                proxy.scrollTo(Self.topID, anchor: .top)
            }
        }
        .searchable(text: $model.query.text, placement: .toolbar, prompt: "Search all libraries")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                QueueButton(count: model.queue.items.count,
                            failed: model.queue.items.filter { $0.lastError != nil }.count) { showingQueue.toggle() }
                    .popover(isPresented: $showingQueue, arrowEdge: .bottom) {
                        QueuePopover().environment(model)
                    }
            }
        }
    }
}

private struct QueueButton: View {
    let count: Int
    /// Queued books whose last send failed; the badge turns red while any remain.
    let failed: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "books.vertical")
                Text("Queue")
                if failed > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(failed > 0 ? Color.red : Color.accentColor))
                }
            }
        }
        .help(failed > 0 ? "Queue: \(failed) failed to send" : "Queue")
        .accessibilityLabel("Queue")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let books = count == 1 ? "1 book" : "\(count) books"
        return failed > 0 ? "\(books), \(failed) failed" : books
    }
}

private struct CategoryChips: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(BookCategory.allCases) { category in
                    let selected = model.query.category == category
                    Button { model.query.category = category } label: {
                        Text(category.title)
                            .font(.callout)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 4)
                            .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                            .background(Capsule().fill(selected ? Color.primary : Color.secondary.opacity(0.14)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(category.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)
        }
    }
}

/// The cover grid. Queued and sent state are computed once per pass, not per tile.
private struct ResultsGrid: View {
    @Environment(AppModel.self) private var model
    let topID: String

    @State private var openWork: Work?
    @State private var resend: Edition?

    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 16)]

    var body: some View {
        let queued = Set(model.queue.items.map(\.id))
        ScrollView {
            Color.clear.frame(height: 0).id(topID)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(model.results) { work in
                    let ids = work.editions.map(\.id)
                    WorkTile(work: work,
                             isQueued: ids.contains(where: queued.contains),
                             isSent: ids.contains(where: model.history.wasSent(id:)),
                             toggleQueue: { toggle(work, queuedIDs: queued) },
                             openEditions: { openWork = work })
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .sheet(item: $openWork) { work in
            EditionPicker(work: work).environment(model)
        }
        .confirmResend($resend, history: model.history) { model.queue.add($0) }
    }

    /// ✓ removes whichever editions of the work are queued; ＋ adds the default edition.
    private func toggle(_ work: Work, queuedIDs: Set<String>) {
        let inQueue = work.editions.map(\.id).filter(queuedIDs.contains)
        if !inQueue.isEmpty {
            model.queue.remove(ids: inQueue)
        } else if model.history.wasSent(id: work.defaultEdition.id) {
            resend = work.defaultEdition
        } else {
            model.queue.add(work.defaultEdition)
        }
    }
}
