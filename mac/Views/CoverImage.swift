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
    /// The url `image` belongs to, so a reused view never shows another book's cover.
    @State private var imageURL: URL?

    init(url: URL, title: String, compact: Bool = false) {
        self.url = url
        self.title = title
        self.compact = compact
        // A cache hit renders on the first frame instead of flashing the placeholder.
        let cached = DecodedCovers.shared.cached(url)
        _image = State(initialValue: cached)
        _imageURL = State(initialValue: cached == nil ? nil : url)
    }

    /// The loaded image when it belongs to `url`, else a cache hit for `url` (so a url change
    /// still renders a cached cover on its first frame), else nil.
    private var displayed: CGImage? {
        imageURL == url ? image : DecodedCovers.shared.cached(url)
    }

    var body: some View {
        ZStack {
            if let image = displayed {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                CoverPlaceholderView(title: title, compact: compact)
            }
        }
        .clipped()
        .task(id: url) {
            guard imageURL != url else { return }
            image = nil
            imageURL = nil
            let loaded = await DecodedCovers.shared.image(for: url, from: model.covers)
            guard !Task.isCancelled else { return }
            image = loaded
            imageURL = loaded == nil ? nil : url
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
    /// Decoded bitmaps are large (a 600 px cover is ~1 MB), so the cache is bounded by bytes.
    private static let byteLimit = 150 * 1024 * 1024
    private let cache = NSCache<NSURL, CGImage>()

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = Self.byteLimit
    }

    /// The decoded cover if it is in memory; never loads.
    func cached(_ url: URL) -> CGImage? {
        cache.object(forKey: url as NSURL)
    }

    /// nil when the cover cannot be loaded (or the caller was cancelled).
    func image(for url: URL, from covers: CoverCache) async -> CGImage? {
        if let hit = cached(url) { return hit }
        guard let data = try? await covers.data(for: url),
              let decoded = await Self.decode(data), !Task.isCancelled else { return nil }
        cache.setObject(decoded, forKey: url as NSURL, cost: decoded.bytesPerRow * decoded.height)
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
