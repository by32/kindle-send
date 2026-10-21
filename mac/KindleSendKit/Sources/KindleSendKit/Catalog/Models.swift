import Foundation

public enum Source: String, Codable, Sendable {
    case gutenberg, standardEbooks
}

public struct Edition: Codable, Hashable, Sendable, Identifiable {
    /// "pg:1342" or "se:/ebooks/mary-shelley/frankenstein"
    public var id: String
    public var source: Source
    public var title: String
    /// Display form, e.g. "Jane Austen".
    public var authors: [String]
    /// ISO 639-1, e.g. ["en"].
    public var languages: [String]
    /// Gutenberg subjects + bookshelves; Standard Ebooks subject slugs.
    public var subjects: [String]
    /// Translator/illustrator credit if known.
    public var credits: String?
    /// 0 if unknown.
    public var downloads: Int
    public var coverURL: URL
    /// e.g. "1998-06-01".
    public var issued: String?

    public init(
        id: String, source: Source, title: String, authors: [String],
        languages: [String], subjects: [String], credits: String? = nil,
        downloads: Int = 0, coverURL: URL, issued: String? = nil
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.authors = authors
        self.languages = languages
        self.subjects = subjects
        self.credits = credits
        self.downloads = downloads
        self.coverURL = coverURL
        self.issued = issued
    }
}

public struct Work: Hashable, Sendable, Identifiable {
    /// The work's `matchKey`.
    public var id: String
    /// Default edition first.
    public var editions: [Edition]
    public var defaultEdition: Edition { editions[0] }

    public init(id: String, editions: [Edition]) {
        self.id = id
        self.editions = editions
    }
}
