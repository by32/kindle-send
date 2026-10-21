import ImageIO
import KindleSendKit
import SwiftUI

/// A book cover that fills its frame. It loads lazily while on screen (the load is cancelled when
/// the view disappears) and shows a title card while the cover is loading or missing.
struct CoverImage: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let title: String
    /// Smaller placeholder text for thumbnails.
    var compact = false

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                CoverPlaceholderView(title: title, compact: compact)
            }
        }
        .clipped()
        .task(id: url) {
            image = await DecodedCovers.shared.image(for: url, from: model.covers)
        }
    }
}

/// The missing-cover card: a stable color per title with the title in serif.
struct CoverPlaceholderView: View {
    let title: String
    var compact = false

    var body: some View {
        let hue = CoverPlaceholder.hue(for: title)
        LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.62),
                                Color(hue: hue, saturation: 0.55, brightness: 0.42)],
                       startPoint: .top, endPoint: .bottom)
            .overlay {
                if !compact {
                    Text(title)
                        .font(.system(.callout, design: .serif).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .minimumScaleFactor(0.7)
                        .padding(10)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Decoded covers kept in memory, so scrolling back does not re-read or re-decode them.
@MainActor final class DecodedCovers {
    static let shared = DecodedCovers()
    /// Longest side, in pixels, covers are decoded at: a 2x Retina tile up to ~200 pt wide.
    nonisolated private static let maxPixelSize = 600
    private let cache = NSCache<NSURL, CGImage>()

    private init() { cache.countLimit = 400 }

    /// nil when the cover cannot be loaded (or the caller was cancelled).
    func image(for url: URL, from covers: CoverCache) async -> CGImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let data = try? await covers.data(for: url),
              let decoded = await Self.decode(data), !Task.isCancelled else { return nil }
        cache.setObject(decoded, forKey: url as NSURL)
        return decoded
    }

    /// Downsamples off the main actor.
    @concurrent nonisolated private static func decode(_ data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
