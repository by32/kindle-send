import Foundation

public enum DownloadError: Error, Equatable, LocalizedError {
    /// `bytes` is the estimated size of the whole message (see `Batching.singleMessageSize`),
    /// the figure compared against `cap`.
    case tooLarge(bytes: Int, cap: Int)
    case http(Int)
    /// The response was not a ZIP archive, e.g. an HTML interstitial or rate-limit page.
    case notAnEpub

    public var errorDescription: String? {
        switch self {
        case let .tooLarge(bytes, cap):
            "Too large to email (\(Self.megabytes(bytes, decimals: true)) MB > \(Self.megabytes(cap, decimals: false)) MB cap)"
        case let .http(code):
            "Download failed (HTTP \(code))"
        case .notAnEpub:
            "Download wasn't an EPUB (the site may be rate-limiting; try again later)"
        }
    }

    private static func megabytes(_ bytes: Int, decimals: Bool) -> String {
        let mb = Double(bytes) / 1_048_576
        return decimals ? String(format: "%.1f", mb) : String(format: "%g", mb)
    }
}

public struct EditionDownloader: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient) {
        self.http = http
    }

    /// An EPUB is a ZIP archive, which starts with a local file header: "PK\u{3}\u{4}".
    private static let zipMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    /// Downloads the edition's EPUB. For Gutenberg, falls back to the no-images build when the
    /// full one exceeds the cap (measured on the whole message: base64 size plus MIME overhead).
    /// Throws `notAnEpub` when the response isn't a ZIP archive (e.g. an HTML error page).
    public func download(_ edition: Edition, maxBytes: Int) async throws -> Attachment {
        var data = try await fetch(Self.primaryURL(for: edition))
        if Batching.singleMessageSize(data.count) > maxBytes, let fallback = Self.noImagesURL(for: edition) {
            data = try await fetch(fallback)
        }
        guard data.starts(with: Self.zipMagic) else { throw DownloadError.notAnEpub }
        let messageSize = Batching.singleMessageSize(data.count)
        if messageSize > maxBytes {
            throw DownloadError.tooLarge(bytes: messageSize, cap: maxBytes)
        }
        return Attachment(filename: Self.filename(for: edition), data: data, mimeType: "application/epub+zip")
    }

    static func primaryURL(for edition: Edition) -> URL {
        switch edition.source {
        case .gutenberg: URL(string: "https://www.gutenberg.org/ebooks/\(gutenbergID(edition)).epub3.images")!
        case .standardEbooks: StandardEbooksParser.epubURL(for: edition)
        }
    }

    static func noImagesURL(for edition: Edition) -> URL? {
        edition.source == .gutenberg
            ? URL(string: "https://www.gutenberg.org/ebooks/\(gutenbergID(edition)).epub.noimages")! : nil
    }

    private static func gutenbergID(_ edition: Edition) -> String {
        edition.id.hasPrefix("pg:") ? String(edition.id.dropFirst(3)) : edition.id
    }

    /// "{Title} - {Author surname}.epub" with `/` and `:` replaced by `-`.
    static func filename(for edition: Edition) -> String {
        var name = String(MIMEMessage.scrub(edition.title).prefix(120))
        if let surname = MIMEMessage.scrub(edition.authors.first ?? "").split(separator: " ").last {
            name += " - \(surname)"
        }
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".epub"
    }

    private func fetch(_ url: URL) async throws -> Data {
        do {
            return try await http.data(from: url).0
        } catch let HTTPError.status(code, _) {
            throw DownloadError.http(code)
        }
    }
}
