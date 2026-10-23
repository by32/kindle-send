import KindleSendKit
import SwiftUI

/// One work in the grid: a 2:3 cover with a ＋/✓ queue button, edition and Sent labels, and the
/// title and author below. Takes plain values so the grid decides queued/sent state once per pass.
struct WorkTile: View {
    let work: Work
    let isQueued: Bool
    let isSent: Bool
    let toggleQueue: () -> Void
    let openEditions: () -> Void

    private var edition: Edition { work.defaultEdition }
    private var author: String { edition.authors.joined(separator: ", ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: openEditions) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay { CoverImage(url: edition.coverURL, title: edition.title) }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(author.isEmpty ? edition.title : "\(edition.title) by \(author)")
            .accessibilityHint("Shows the editions")
            .overlay(alignment: .topTrailing) { queueButton.padding(6) }
            .overlay(alignment: .bottomLeading) { labels.padding(6) }

            Text(edition.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(author)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var queueButton: some View {
        Button(action: toggleQueue) {
            Image(systemName: isQueued ? "checkmark" : "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isQueued ? Color.white : Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Circle().fill(isQueued ? Color.accentColor : Color.white.opacity(0.92)))
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isQueued ? "Remove from Queue" : "Add to Queue")
        .accessibilityLabel(isQueued ? "Remove \(edition.title) from Queue" : "Add \(edition.title) to Queue")
    }

    @ViewBuilder private var labels: some View {
        HStack(spacing: 4) {
            if work.editions.count > 1 { TileCapsule(text: "\(work.editions.count) editions") }
            if isSent { TileCapsule(text: "Sent", systemImage: "checkmark") }
        }
    }
}

private struct TileCapsule: View {
    let text: String
    var systemImage: String?

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(.black.opacity(0.62)))
    }
}
