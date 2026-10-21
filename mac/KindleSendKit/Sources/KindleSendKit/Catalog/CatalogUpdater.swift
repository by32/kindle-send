import Foundation

public enum CatalogUpdaterError: Error, Equatable, LocalizedError {
    /// Page 1 of the Standard Ebooks listing parsed to no books: the site's markup changed.
    case standardEbooksListingEmpty(URL)
    /// `refresh` was called while another refresh was running.
    case refreshInProgress

    public var errorDescription: String? {
        switch self {
        case let .standardEbooksListingEmpty(url):
            "No books found on \(url.absoluteString); the Standard Ebooks page layout may have changed."
        case .refreshInProgress:
            "A catalog refresh is already running."
        }
    }
}

/// Downloads both catalogs, builds a fresh index beside the live one and swaps it into place.
/// A failed refresh leaves the live index file untouched.
public actor CatalogUpdater {
    public enum Phase: Sendable, Equatable {
        case idle, downloadingGutenberg, fetchingStandardEbooks(page: Int), indexing, done, failed(String)
    }

    static let gutenbergCatalogURL = URL(string: "https://www.gutenberg.org/cache/epub/feeds/pg_catalog.csv.gz")!
    static let gutenbergPopularityURL = URL(string: "https://www.gutenberg.org/browse/scores/top1000.php")!
    static let maxAge: TimeInterval = 24 * 60 * 60
    /// Hard cap on pages fetched from any one Standard Ebooks listing.
    static let maxPages = 60

    private let http: any HTTPClient
    private let databaseURL: URL
    private let now: @Sendable () -> Date
    private var isRefreshing = false

    public init(http: any HTTPClient, databaseURL: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.http = http
        self.databaseURL = databaseURL
        self.now = now
    }

    /// True when the index was never built (nil) or was built more than 24 h ago.
    public nonisolated func isStale(builtAt: Date?) -> Bool {
        guard let builtAt else { return true }
        return now().timeIntervalSince(builtAt) > Self.maxAge
    }

    /// Also true when the index was built with a different `CatalogDatabase.schemaVersion`
    /// (nil = built before versioning). Pass `database.builtAt` and `database.storedSchemaVersion`.
    public nonisolated func isStale(builtAt: Date?, schemaVersion: Int?) -> Bool {
        schemaVersion != CatalogDatabase.schemaVersion || isStale(builtAt: builtAt)
    }

    /// Reports phases in order; on failure reports `.failed` and rethrows.
    public func refresh(progress: @Sendable (Phase) -> Void) async throws {
        guard !isRefreshing else { throw CatalogUpdaterError.refreshInProgress }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let works = try await fetchWorks(progress)
            progress(.indexing)
            try install(works)
            progress(.done)
        } catch {
            progress(.failed(Self.message(for: error)))
            throw error
        }
    }

    // MARK: - Fetching

    private func fetchWorks(_ progress: @Sendable (Phase) -> Void) async throws -> [Work] {
        progress(.downloadingGutenberg)
        let (gzip, _) = try await http.data(from: Self.gutenbergCatalogURL)
        var gutenberg = try GutenbergCatalogParser.parse(csv: String(decoding: try Gzip.decompress(gzip), as: UTF8.self))
        let (top, _) = try await http.data(from: Self.gutenbergPopularityURL)
        let downloads = GutenbergPopularityParser.parse(html: String(decoding: top, as: UTF8.self))
        for i in gutenberg.indices {
            if let id = Int(gutenberg[i].id.dropFirst("pg:".count)), let count = downloads[id] {
                gutenberg[i].downloads = count
            }
        }

        var standard = try await fetchPages(StandardEbooksParser.listingURL, firstPageRequired: true) { page in
            progress(.fetchingStandardEbooks(page: page))
        }
        let indexByID = Dictionary(uniqueKeysWithValues: standard.enumerated().map { ($1.id, $0) })
        for slug in BookCategory.allCases.flatMap(\.standardEbooksSubjects) {
            let tagged = try await fetchPages({ StandardEbooksParser.subjectURL(slug, page: $0) }, firstPageRequired: false)
            for edition in tagged {
                if let i = indexByID[edition.id], !standard[i].subjects.contains(slug) {
                    standard[i].subjects.append(slug)
                }
            }
        }
        return WorkGrouper.group(gutenberg + standard)
    }

    /// Fetches pages 1, 2, … one at a time until a page yields no new edition ids (the site
    /// repeats its last page past the end) or `maxPages` is reached.
    private func fetchPages(
        _ url: (Int) -> URL, firstPageRequired: Bool, willFetch: (Int) -> Void = { _ in }
    ) async throws -> [Edition] {
        var seen = Set<String>()
        var editions: [Edition] = []
        for page in 1...Self.maxPages {
            willFetch(page)
            let pageURL = url(page)
            let (data, _) = try await http.data(from: pageURL)
            let found = StandardEbooksParser.parseListing(html: String(decoding: data, as: UTF8.self))
            if found.isEmpty, page == 1, firstPageRequired {
                throw CatalogUpdaterError.standardEbooksListingEmpty(pageURL)
            }
            let new = found.filter { seen.insert($0.id).inserted }
            if new.isEmpty { break }
            editions += new
        }
        return editions
    }

    // MARK: - Installing

    /// Builds `<db>.tmp`, flushes it to disk, then swaps it over the live file.
    private func install(_ works: [Work]) throws {
        let fileManager = FileManager.default
        let directory = databaseURL.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(databaseURL.lastPathComponent + ".tmp")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try CatalogDatabase.build(at: temp, works: works).close()
            let handle = try FileHandle(forWritingTo: temp)
            try handle.synchronize()
            try handle.close()
            if fileManager.fileExists(atPath: databaseURL.path) {
                _ = try fileManager.replaceItemAt(databaseURL, withItemAt: temp)
            } else {
                try fileManager.moveItem(at: temp, to: databaseURL)
            }
        } catch {
            for suffix in ["", "-journal"] {
                try? fileManager.removeItem(atPath: temp.path + suffix)
            }
            throw error
        }
    }

    /// Localized text where the error has it, else the Swift case (e.g. `sizeMismatch`).
    private static func message(for error: any Error) -> String {
        if error is LocalizedError || (error as NSError).userInfo[NSLocalizedDescriptionKey] != nil {
            return error.localizedDescription
        }
        return String(describing: error)
    }
}
