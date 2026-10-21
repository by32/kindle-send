import Foundation

public enum DownloadError: Error, Equatable, LocalizedError {
    case tooLarge(bytes: Int, cap: Int)
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case let .tooLarge(bytes, cap):
            "Too large to email (\(Self.megabytes(bytes, decimals: true)) MB > \(Self.megabytes(cap, decimals: false)) MB cap)"
        case let .http(code):
            "Download failed (HTTP \(code))"
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

    /// Downloads the edition's EPUB. For Gutenberg, falls back to the no-images build when the
    /// full one exceeds the cap (measured on the whole message: base64 size plus MIME overhead).
    public func download(_ edition: Edition, maxBytes: Int) async throws -> Attachment {
        var data = try await fetch(Self.primaryURL(for: edition))
        if Batching.singleMessageSize(data.count) > maxBytes, let fallback = Self.noImagesURL(for: edition) {
            data = try await fetch(fallback)
        }
        if Batching.singleMessageSize(data.count) > maxBytes {
            throw DownloadError.tooLarge(bytes: data.count, cap: maxBytes)
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
