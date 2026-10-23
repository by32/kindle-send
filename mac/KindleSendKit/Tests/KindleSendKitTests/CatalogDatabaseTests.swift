import Foundation
import Testing
@testable import KindleSendKit

@Suite struct CatalogDatabaseTests {
    private static func edition(
        _ id: String, _ title: String, _ author: String, source: Source = .gutenberg,
        languages: [String] = ["en"], subjects: [String] = [], downloads: Int = 0
    ) -> Edition {
        Edition(
            id: id, source: source, title: title, authors: [author], languages: languages,
            subjects: subjects, downloads: downloads, coverURL: URL(string: "https://example.com/c.jpg")!)
    }

    private static let poetryShelf = "Category: Poetry"

    private static let works: [Work] = [
        Work(id: "prejudice and pride|ann pratt", editions: [
            edition("pg:9001", "Prejudice and Pride: A Study", "Ann Pratt", downloads: 5),
        ]),
        Work(id: "pride and prejudice|jane austen", editions: [
            edition("pg:1342", "Pride and Prejudice", "Jane Austen",
                    subjects: ["Category: Novels"], downloads: 50_000),
        ]),
        Work(id: "crime and punishment|fyodor dostoevsky", editions: [
            edition("pg:2554", "Crime and Punishment", "Fyodor Dostoevsky", downloads: 20_000),
        ]),
        Work(id: "miserables|victor hugo", editions: [
            edition("pg:135", "Les Misérables", "Victor Hugo", languages: ["fr"], downloads: 8_000),
        ]),
        Work(id: "leaves of grass|walt whitman", editions: [
            edition("pg:1322", "Leaves of Grass", "Walt Whitman", subjects: [poetryShelf], downloads: 9_000),
        ]),
        Work(id: "raven|edgar poe", editions: [
            edition("pg:1065", "The Raven", "Edgar Allan Poe", subjects: [poetryShelf], downloads: 3_000),
        ]),
        Work(id: "lost world|ann smith", editions: [
            edition("pg:7000", "The Lost World", "Ann Smith"),
        ]),
        Work(id: "lost world|bob jones", editions: [
            edition("se:/ebooks/bob-jones/the-lost-world", "The Lost World", "Bob Jones", source: .standardEbooks),
            edition("pg:7001", "The Lost World", "Bob Jones"),
        ]),
        Work(id: "star voyage|cal reyes", editions: [
            edition("pg:8000", "Star Voyage", "Cal Reyes", subjects: ["Category: Science-Fiction & Fantasy"]),
        ]),
        Work(id: "dune road|ed marsh", editions: [
            edition("pg:8001", "Dune Road", "Ed Marsh", languages: ["eng"]),
        ]),
    ]

    private func database() throws -> CatalogDatabase {
        try CatalogDatabase.build(at: nil, works: Self.works)
    }

    private func titles(_ text: String, category: BookCategory = .popular, language: String? = nil) throws -> [String] {
        try database().search(SearchQuery(text: text, category: category, language: language))
            .map(\.defaultEdition.title)
    }

    @Test func prefixSearch() throws {
        #expect(try titles("pride prej").first == "Pride and Prejudice")
    }

    @Test func typoSearch() throws {
        #expect(try titles("pride predjudice").contains("Pride and Prejudice"))
        let authors = try database().search(SearchQuery(text: "dostoyevsky", category: .popular, language: nil))
            .flatMap(\.defaultEdition.authors)
        #expect(authors.contains("Fyodor Dostoevsky"))
    }

    @Test func languageFilter() throws {
        #expect(try !titles("miserables", language: "en").contains("Les Misérables"))
        #expect(try titles("miserables", language: nil).contains("Les Misérables"))
        #expect(try titles("", language: "fr") == ["Les Misérables"])
    }

    @Test func categoryBrowse() throws {
        #expect(try titles("", category: .poetry) == ["Leaves of Grass", "The Raven"])
    }

    @Test func seBoost() throws {
        let results = try database().search(SearchQuery(text: "lost world", category: .popular, language: nil))
        #expect(results.map(\.id) == ["lost world|bob jones", "lost world|ann smith"])
    }

    @Test func popularBrowseBoostsSEWithoutPartitioning() throws {
        let ids = try database().search(SearchQuery(text: "", category: .popular, language: nil)).map(\.id)
        let pride = try #require(ids.firstIndex(of: "pride and prejudice|jane austen"))
        let seZero = try #require(ids.firstIndex(of: "lost world|bob jones"))
        let pgZero = try #require(ids.firstIndex(of: "lost world|ann smith"))
        #expect(pride < seZero)
        #expect(seZero < pgZero)
        #expect(ids.first == "pride and prejudice|jane austen")
    }

    @Test func shortQueriesUseTheSameBoostedOrder() throws {
        #expect(try database().search(SearchQuery(text: "t")).map(\.id)
            == ["raven|edgar poe", "lost world|bob jones", "lost world|ann smith"])
    }

    @Test func hostileQueriesDoNotThrow() throws {
        let db = try database()
        for text in ["", "   ", "\"\"\"", "AND", "NEAR(", "*", "-", "a", "a-"] {
            _ = try db.search(SearchQuery(text: text, category: .popular, language: nil))
        }
    }

    @Test func workLookupRoundTripsEditions() throws {
        let db = try database()
        let work = try #require(try db.work(id: "lost world|bob jones"))
        #expect(work == Self.works[7])
        #expect(try db.work(id: "missing") == nil)
        #expect(db.builtAt != nil)
    }

    @Test func pipeFiltersDoNotMatchNearCollisions() throws {
        #expect(try !titles("", language: "en").contains("Dune Road"))
        #expect(try titles("", language: "eng") == ["Dune Road"])
        #expect(try titles("", category: .fiction) == ["Pride and Prejudice"])
        #expect(try titles("", category: .scienceFiction) == ["Star Voyage"])
    }

    @Test func shortQueriesMatchTitlePrefixByPopularity() throws {
        #expect(try titles("l") == ["Leaves of Grass", "Les Misérables"])
        #expect(try titles("L", language: "en") == ["Leaves of Grass"])
        #expect(try titles("pr") == ["Pride and Prejudice", "Prejudice and Pride: A Study"])
        #expect(try titles("zq").isEmpty)
    }

    @Test func builtFileReopensReadOnlyWithoutSidecars() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("catalog.sqlite")
        try CatalogDatabase.build(at: url, works: Self.works).close()

        let reopened = try CatalogDatabase(url: url)
        #expect(reopened.builtAt != nil)
        #expect(reopened.storedSchemaVersion == CatalogDatabase.schemaVersion)
        let hits = try reopened.search(SearchQuery(text: "raven", category: .popular, language: nil))
        #expect(hits.map(\.defaultEdition.title) == ["The Raven"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["catalog.sqlite"])
        reopened.close()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["catalog.sqlite"])
    }

    @Test func closedDatabaseThrows() throws {
        let db = try database()
        db.close()
        db.close()
        #expect(throws: CatalogDatabaseError.closed) {
            try db.search(SearchQuery(text: "raven"))
        }
        #expect(throws: CatalogDatabaseError.closed) { try db.work(id: "raven|edgar poe") }
        #expect(db.builtAt == nil)
        #expect(db.storedSchemaVersion == nil)
    }

    @Test func readOnlyOpenOfMissingFileThrows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        #expect(throws: CatalogDatabaseError.self) { try CatalogDatabase(url: url) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Benchmark

    /// Opt-in: `KINDLESEND_BENCH=1 KINDLESEND_BENCH_CSV=/path/pg_catalog.csv.gz swift test ...`.
    /// A path ending in `.gz` is decompressed with `/usr/bin/gunzip -c`; any other path is read as CSV.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KINDLESEND_BENCH"] == "1"))
    func fullCatalogSearchIsFast() throws {
        let path = try #require(ProcessInfo.processInfo.environment["KINDLESEND_BENCH_CSV"])
        let editions = try GutenbergCatalogParser.parse(csv: try Self.readCatalog(path))
        let works = WorkGrouper.group(editions)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("catalog.sqlite")

        // The app's path: build to a file, close it, reopen it read-only.
        let buildStart = ContinuousClock.now
        try CatalogDatabase.build(at: url, works: works).close()
        let buildTime = ContinuousClock.now - buildStart
        let db = try CatalogDatabase(url: url)

        let queries = [
            "pride", "dostoyevsky", "sherlock holmes", "austen", "war and peace",
            "frankenstein", "moby dick", "dickens", "shakespeare", "the", "a",
            "sherlok", "tolstoi", "alice in wonderland", "history of rome", "poems",
            "great expectations", "dracula", "jane eyre", "kafka metamorphosis",
            "the adventures of sherlok holmes", "t",
        ]
        var times: [Duration] = []
        for category in BookCategory.allCases {
            let start = ContinuousClock.now
            _ = try db.search(SearchQuery(text: "", category: category, language: "en"))
            let elapsed = ContinuousClock.now - start
            times.append(elapsed)
            print("bench browse \(category.rawValue): \(elapsed)")
        }
        for text in queries {
            let start = ContinuousClock.now
            _ = try db.search(SearchQuery(text: text, category: .popular, language: nil))
            let elapsed = ContinuousClock.now - start
            times.append(elapsed)
            print("bench query \"\(text)\": \(elapsed)")
        }
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1]
        print("bench: \(works.count) works, \(times.count) queries, build \(buildTime), median \(median), p95 \(p95), max \(sorted.last!)")
        #expect(median < .milliseconds(50))
        #expect(p95 < .milliseconds(50))
    }

    private static func readCatalog(_ path: String) throws -> String {
        guard path.hasSuffix(".gz") else { return try String(contentsOfFile: path, encoding: .utf8) }
        let gunzip = Process()
        gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        gunzip.arguments = ["-c", path]
        let pipe = Pipe()
        gunzip.standardOutput = pipe
        try gunzip.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        gunzip.waitUntilExit()
        return try #require(String(data: data, encoding: .utf8))
    }
}
