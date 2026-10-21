import KindleSendKit
import SwiftUI

/// First-launch progress while the local catalog index is built.
struct IndexProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Building the book index")
                .font(.title2.bold())
            Text("Kindle Send keeps a local copy of the Project Gutenberg and Standard Ebooks catalogs so search is instant. This takes a few seconds.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            if case let .failed(message) = model.indexPhase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Try Again") { Task { await model.refreshIndex() } }
                    .keyboardShortcut(.defaultAction)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(step), total: 3)
                    Text(stepText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 320)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Completed steps out of three.
    private var step: Int {
        switch model.indexPhase {
        case .idle, .failed, .downloadingGutenberg: 0
        case .fetchingStandardEbooks: 1
        case .indexing: 2
        case .done: 3
        }
    }

    private var stepText: String {
        switch model.indexPhase {
        case .idle: "Getting ready…"
        case .downloadingGutenberg: "Step 1 of 3: Downloading the Project Gutenberg catalog…"
        case let .fetchingStandardEbooks(page): "Step 2 of 3: Reading Standard Ebooks, page \(page)…"
        case .indexing: "Step 3 of 3: Building the search index…"
        case .done: "Done"
        case .failed: ""
        }
    }
}
