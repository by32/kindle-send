import Foundation
import Synchronization
import Testing
@testable import KindleSendKit

/// Serves canned responses; records every request in order.
actor FakeHTTPClient: HTTPClient {
    private let handler: @Sendable (URL) throws -> Data
    private(set) var requests: [URL] = []

    init(_ handler: @escaping @Sendable (URL) throws -> Data) {
        self.handler = handler
    }

    func data(from url: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(url)
        let data = try handler(url)
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// Collects progress phases from a `@Sendable` callback.
final class PhaseLog: Sendable {
    private let phases = Mutex<[CatalogUpdater.Phase]>([])
    var all: [CatalogUpdater.Phase] { phases.withLock { $0 } }
    func record(_ phase: CatalogUpdater.Phase) { phases.withLock { $0.append(phase) } }
}

@Suite struct CatalogUpdaterTests {
    private struct Missing: Error { let url: URL }

    private static func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// A listing page holding one minimal `<li>` per path.
    private static func listing(_ paths: [String]) -> Data {
        let items = paths.map { path in
            """
            <li typeof="schema:Book" about="\(path)"><img src="/c.jpg"/>\
            <p><span property="schema:name">Title \(path)</span></p>\
            <p class="author"><span property="schema:name">Author \(path)</span></p></li>
            """
        }
        return Data("<ol>\(items.joined())</ol>".utf8)
    }

    private static let emptyPage = Data("<html><body><ol></ol></body></html>".utf8)

    /// Fixture-backed responses: listing pages 1 (3 books), 2 (Frankenstein), 3 (empty);
    /// every subject's page 1 is empty except science-fiction, whose page 2 repeats page 1.
    /// `overrides` win; `failing` URLs throw; any other URL throws.
    private static func responses(
        overrides: [URL: Data] = [:], failing: Set<URL> = []
    ) throws -> @Sendable (URL) throws -> Data {
        let frankenstein = try fixture("se_frankenstein_page", "html")
        var table: [URL: Data] = [
            CatalogUpdater.gutenbergCatalogURL: try fixture("pg_catalog_sample.csv", "gz"),
            CatalogUpdater.gutenbergPopularityURL: try fixture("top1000_sample", "html"),
            StandardEbooksParser.listingURL(1): try fixture("se_listing_page", "html"),
            StandardEbooksParser.listingURL(2): frankenstein,
            StandardEbooksParser.listingURL(3): emptyPage,
        ]
        for slug in BookCategory.allCases.flatMap(\.standardEbooksSubjects) {
            table[StandardEbooksParser.subjectURL(slug, page: 1)] = emptyPage
        }
        table[StandardEbooksParser.subjectURL("science-fiction", page: 1)] = frankenstein
        table[StandardEbooksParser.subjectURL("science-fiction", page: 2)] = frankenstein
        table.merge(overrides) { $1 }
        let responses = table
        return { url in
            guard !failing.contains(url), let data = responses[url] else { throw Missing(url: url) }
            return data
        }
    }

    private static func tempDatabaseURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("catalog.sqlite")
    }

    private static func tempFileURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".tmp")
    }

    // MARK: - Refresh

    @Test func refreshBuildsSearchableIndex() async throws {
        let url = try Self.tempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let updater = CatalogUpdater(http: FakeHTTPClient(try Self.responses()), databaseURL: url)

        try await updater.refresh { _ in }

        let db = try CatalogDatabase(url: url)
        let hits = try db.search(SearchQuery(text: "frankenstein"))
        #expect(hits.count == 1)
        let work = try #require(hits.first)
        #expect(work.editions.count == 2)
        #expect(work.defaultEdition.id == "se:/ebooks/mary-shelley/frankenstein")
        #expect(work.defaultEdition.subjects == ["science-fiction"])
        #expect(work.editions.map(\.id).contains("pg:84"))

        let pride = try #require(try db.search(SearchQuery(text: "pride and prejudice")).first)
        #expect(pride.defaultEdition.id == "pg:1342")
        #expect(pride.defaultEdition.downloads == 186_807)
        #expect(try db.search(SearchQuery(text: "suspense merriman")).count == 1)

        #expect(db.storedSchemaVersion == CatalogDatabase.schemaVersion)
        #expect(!FileManager.default.fileExists(atPath: Self.tempFileURL(for: url).path))
    }

    @Test func refreshReplacesExistingIndex() async throws {
        let url = try Self.tempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try CatalogDatabase.build(at: url, works: []).close()
        let updater = CatalogUpdater(http: FakeHTTPClient(try Self.responses()), databaseURL: url)

        try await updater.refresh { _ in }

        #expect(try CatalogDatabase(url: url).search(SearchQuery(text: "frankenstein")).count == 1)
        #expect(!FileManager.default.fileExists(atPath: Self.tempFileURL(for: url).path))
    }

    @Test func failedRefreshKeepsOldIndex() async throws {
        let url = try Self.tempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let old = Work(id: "old|work", editions: [Edition(
            id: "pg:1", source: .gutenberg, title: "Old Work", authors: ["Someone"], languages: ["en"],
            subjects: [], coverURL: URL(string: "https://example.com/c.jpg")!)])
        try CatalogDatabase.build(at: url, works: [old]).close()
        let before = try Data(contentsOf: url)
        let http = FakeHTTPClient(try Self.responses(failing: [StandardEbooksParser.listingURL(2)]))
        let log = PhaseLog()

        await #expect(throws: (any Error).self) {
            try await CatalogUpdater(http: http, databaseURL: url).refresh(progress: log.record)
        }

        #expect(try Data(contentsOf: url) == before)
        #expect(!FileManager.default.fileExists(atPath: Self.tempFileURL(for: url).path))
        guard case .failed = log.all.last else {
            Issue.record("last phase was \(String(describing: log.all.last))")
            return
        }
        #expect(try CatalogDatabase(url: url).search(SearchQuery(text: "old work")).count == 1)
    }

    @Test func failedBuildKeepsOldIndex() async throws {
        let url = try Self.tempDatabaseURL()
        let fileManager = FileManager.default
        try CatalogDatabase.build(at: url, works: []).close()
        let before = try Data(contentsOf: url)
        // A read-only, non-empty directory at the temp path makes the build fail.
        let blocked = Self.tempFileURL(for: url)
        try fileManager.createDirectory(at: blocked, withIntermediateDirectories: false)
        try Data().write(to: blocked.appendingPathComponent("keep"))
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            try? fileManager.removeItem(at: url.deletingLastPathComponent())
        }

        await #expect(throws: CatalogDatabaseError.self) {
            try await CatalogUpdater(http: FakeHTTPClient(try Self.responses()), databaseURL: url).refresh { _ in }
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func emptyFirstListingPageFails() async throws {
        let url = try Self.tempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let http = FakeHTTPClient(try Self.responses(overrides: [StandardEbooksParser.listingURL(1): Self.emptyPage]))

        await #expect(throws: CatalogUpdaterError.standardEbooksListingEmpty(StandardEbooksParser.listingURL(1))) {
            try await CatalogUpdater(http: http, databaseURL: url).refresh { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: Self.tempFileURL(for: url).path))
    }

    @Test func listingStopsWhenPageRepeats() async throws {
        let url = try Self.tempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let page = Self.listing(["/ebooks/a/one", "/ebooks/b/two"])
        let http = FakeHTTPClient(try Self.responses(overrides: [
            StandardEbooksParser.listingURL(1): page,
            StandardEbooksParser.listingURL(2): page,
        ]))

        try await CatalogUpdater(http: http, databaseURL: url).refresh { _ in }

        let listingRequests = await http.requests.filter { $0.path == "/ebooks" }
        #expect(listingRequests == [StandardEbooksParser.listingURL(1), StandardEbooksParser.listingURL(2)])
    }

    @Test func listingStopsAtHardCap() async throws {
        let url = try Self.tempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let base = try Self.responses()
        let http = FakeHTTPClient { url in
            guard url.path == "/ebooks" else { return try base(url) }
            // Every page yields a new book, forever.
            return Self.listing(["/ebooks/author/book-\(url.query ?? "")"])
        }

        try await CatalogUpdater(http: http, databaseURL: url).refresh { _ in }

        let listingRequests = await http.requests.filter { $0.path == "/ebooks" }
        #expect(listingRequests == (1...60).map(StandardEbooksParser.listingURL))
    }

    @Test func progressPhasesInOrder() async throws {
        let url = try Self.tempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = PhaseLog()

        try await CatalogUpdater(http: FakeHTTPClient(try Self.responses()), databaseURL: url)
            .refresh(progress: log.record)

        #expect(log.all == [
            .downloadingGutenberg,
            .fetchingStandardEbooks(page: 1), .fetchingStandardEbooks(page: 2), .fetchingStandardEbooks(page: 3),
            .indexing, .done,
        ])
    }

    // MARK: - Staleness

    @Test func staleness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let updater = CatalogUpdater(
            http: FakeHTTPClient { _ in Data() }, databaseURL: URL(fileURLWithPath: "/dev/null"), now: { now })
        let hour: TimeInterval = 3600
        #expect(updater.isStale(builtAt: nil))
        #expect(!updater.isStale(builtAt: now.addingTimeInterval(-23 * hour)))
        #expect(updater.isStale(builtAt: now.addingTimeInterval(-25 * hour)))
    }

    @Test func staleWhenSchemaVersionDiffers() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let updater = CatalogUpdater(
            http: FakeHTTPClient { _ in Data() }, databaseURL: URL(fileURLWithPath: "/dev/null"), now: { now })
        let fresh = now.addingTimeInterval(-3600)
        #expect(!updater.isStale(builtAt: fresh, schemaVersion: CatalogDatabase.schemaVersion))
        #expect(updater.isStale(builtAt: fresh, schemaVersion: CatalogDatabase.schemaVersion + 1))
        #expect(updater.isStale(builtAt: fresh, schemaVersion: nil))
        #expect(updater.isStale(builtAt: nil, schemaVersion: CatalogDatabase.schemaVersion))
    }
}
