import Foundation
import SQLite3

public struct SearchQuery: Sendable, Equatable {
    public var text: String
    public var category: BookCategory
    /// ISO 639-1 code; nil = all languages.
    public var language: String?
    public var limit: Int = 120

    public init(text: String, category: BookCategory = .popular, language: String? = nil, limit: Int = 120) {
        self.text = text
        self.category = category
        self.language = language
        self.limit = limit
    }
}

public enum CatalogDatabaseError: Error, Equatable {
    case sqlite(code: Int32, message: String)
    /// The database was used after `close()`.
    case closed
}

/// The local SQLite search index. Every use of the sqlite handle runs on `queue`.
public final class CatalogDatabase: @unchecked Sendable {
    private let queue = DispatchQueue(label: "KindleSendKit.CatalogDatabase")
    /// nil after `close()`. Only touched on `queue` (and in `deinit`).
    private var connection: OpaquePointer?
    private let decoder = JSONDecoder()

    /// Exact searches returning fewer hits than this trigger the typo fallback.
    private static let typoFallbackBelow = 5
    private static let typoMinQueryLength = 4
    private static let typoCandidates = 300
    private static let typoMinSimilarity = 0.3
    /// Folded queries this short use the title-prefix path instead of FTS.
    private static let shortQueryMaxLength = 2
    /// Browse order is `popularity * seBoost + 1` for works with a Standard Ebooks edition and
    /// `popularity` otherwise: SE works outrank equally popular Gutenberg ones and surface ahead
    /// of the unranked long tail, but a top Gutenberg book still outranks an unranked SE work.
    private static let seBoost = 1.5

    private static func browseRank(popularity: Int64, hasSE: Bool) -> Double {
        hasSE ? Double(popularity) * seBoost + 1 : Double(popularity)
    }

    /// Opens an existing index file read-only. It never creates the file or any sidecar
    /// (`-journal`, `-wal`, `-shm`). nil = an empty, writable in-memory index.
    public convenience init(url: URL?) throws {
        if let url {
            try self.init(path: url.path, flags: SQLITE_OPEN_READONLY, createSchema: false)
        } else {
            try self.init(path: ":memory:", flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, createSchema: true)
        }
    }

    private init(path: String, flags: Int32, createSchema: Bool) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close_v2(handle)
            throw CatalogDatabaseError.sqlite(code: rc, message: message)
        }
        connection = handle
        // Memory-map reads; the index is read far more than written.
        sqlite3_exec(handle, "PRAGMA mmap_size=268435456", nil, nil, nil)
        guard createSchema else { return }
        do {
            // Rollback journal, not WAL: a closed index is one self-contained file that can be
            // swapped into place atomically.
            try queue.sync {
                try exec("PRAGMA journal_mode=DELETE")
                try exec("PRAGMA synchronous=OFF")
                try exec(Self.schema)
            }
        } catch {
            close()
            throw error
        }
    }

    deinit {
        if let connection { sqlite3_close_v2(connection) }
    }

    /// Builds a fresh, writable index at `url` (nil = in-memory), writing every work in one
    /// transaction. **Deletes any existing file at `url`**, so callers replacing a live index
    /// must build at a temporary path, `close()` it, then swap it into place. `partial` marks an
    /// index built without one of its sources (see `isPartial`).
    public static func build(at url: URL?, works: [Work], partial: Bool = false) throws -> CatalogDatabase {
        let database: CatalogDatabase
        if let url {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
            database = try CatalogDatabase(
                path: url.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, createSchema: true)
        } else {
            database = try CatalogDatabase(url: nil)
        }
        try database.queue.sync { try database.insert(works, partial: partial) }
        return database
    }

    /// Closes the connection. Idempotent; later calls throw `CatalogDatabaseError.closed`.
    public func close() {
        queue.sync {
            if let connection { sqlite3_close_v2(connection) }
            connection = nil
        }
    }

    public func search(_ q: SearchQuery) throws -> [Work] {
        try queue.sync { try runSearch(q) }
    }

    public func work(id: String) throws -> Work? {
        try queue.sync {
            let stmt = try Statement(handle(), "SELECT id, json FROM works WHERE id = ?1")
            try stmt.bind(1, id)
            return try stmt.step() ? decodeWork(stmt) : nil
        }
    }

    /// The layout `build` writes. Bump it whenever the schema or indexed content changes, so
    /// `CatalogUpdater.isStale(builtAt:schemaVersion:)` rebuilds indexes from older builds.
    public static let schemaVersion = 2

    public var builtAt: Date? {
        meta("built_at").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    /// The `schemaVersion` this file was built with; nil for files built before versioning.
    public var storedSchemaVersion: Int? {
        meta("schema_version").flatMap { Int($0) }
    }

    /// True when the index was built without Standard Ebooks (its listing failed on a first
    /// build). `CatalogUpdater` treats such an index as stale so the next check retries.
    public var isPartial: Bool {
        meta("partial") == "1"
    }

    private func meta(_ key: String) -> String? {
        queue.sync {
            guard let stmt = try? Statement(handle(), "SELECT value FROM meta WHERE key = ?1"),
                  (try? stmt.bind(1, key)) != nil,
                  (try? stmt.step()) == true
            else { return nil }
            return stmt.text(0)
        }
    }

    private func handle() throws -> OpaquePointer {
        guard let connection else { throw CatalogDatabaseError.closed }
        return connection
    }

    // MARK: - Schema and build

    private static let schema = """
        CREATE TABLE IF NOT EXISTS works(
            id TEXT PRIMARY KEY, json BLOB, popularity INTEGER, has_se INTEGER,
            languages TEXT, categories TEXT, title_prefix1 TEXT, title_prefix2 TEXT, browse_rank REAL);
        CREATE INDEX IF NOT EXISTS works_browse ON works(browse_rank DESC);
        CREATE INDEX IF NOT EXISTS works_prefix1 ON works(title_prefix1, browse_rank DESC);
        CREATE INDEX IF NOT EXISTS works_prefix2 ON works(title_prefix2, browse_rank DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS works_fts USING fts5(
            title, authors, subjects, content='', tokenize='unicode61 remove_diacritics 2');
        CREATE VIRTUAL TABLE IF NOT EXISTS works_tri USING fts5(title_authors, tokenize='trigram');
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        """

    private func insert(_ works: [Work], partial: Bool) throws {
        try exec("BEGIN")
        do {
            let encoder = JSONEncoder()
            let insertWork = try Statement(handle(), """
                INSERT INTO works(
                    rowid, id, json, popularity, has_se, languages, categories, title_prefix1, title_prefix2,
                    browse_rank)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                """)
            let insertFTS = try Statement(handle(), "INSERT INTO works_fts(rowid, title, authors, subjects) VALUES (?1, ?2, ?3, ?4)")
            let insertTri = try Statement(handle(), "INSERT INTO works_tri(rowid, title_authors) VALUES (?1, ?2)")

            for (index, work) in works.enumerated() {
                let rowid = Int64(index + 1)
                let editions = work.editions
                let languages = Set(editions.flatMap(\.languages)).sorted()
                let categories = BookCategory.allCases.filter { $0 != .popular && $0.matches(work) }.map(\.rawValue)
                let titles = Self.foldedUnique(editions.map(\.title))
                let authors = Self.foldedUnique(editions.flatMap(\.authors))
                let subjects = Self.foldedUnique(editions.flatMap(\.subjects))

                try insertWork.reset()
                try insertWork.bind(1, rowid)
                try insertWork.bind(2, work.id)
                try insertWork.bind(3, try encoder.encode(editions))
                let popularity = Int64(editions.map(\.downloads).max() ?? 0)
                let hasSE = editions.contains { $0.source == .standardEbooks }
                try insertWork.bind(4, popularity)
                try insertWork.bind(5, Int64(hasSE ? 1 : 0))
                try insertWork.bind(6, Self.pipeList(languages))
                try insertWork.bind(7, Self.pipeList(categories))
                let title = foldForSearch(work.defaultEdition.title)
                try insertWork.bind(8, String(title.prefix(1)))
                try insertWork.bind(9, String(title.prefix(2)))
                try insertWork.bind(10, Self.browseRank(popularity: popularity, hasSE: hasSE))
                try insertWork.run()

                try insertFTS.reset()
                try insertFTS.bind(1, rowid)
                try insertFTS.bind(2, titles)
                try insertFTS.bind(3, authors)
                try insertFTS.bind(4, subjects)
                try insertFTS.run()

                try insertTri.reset()
                try insertTri.bind(1, rowid)
                try insertTri.bind(2, titles + " " + authors)
                try insertTri.run()
            }

            let insertMeta = try Statement(handle(), "INSERT OR REPLACE INTO meta(key, value) VALUES (?1, ?2)")
            for (key, value) in [("built_at", String(Date().timeIntervalSince1970)),
                                 ("schema_version", String(Self.schemaVersion)),
                                 ("partial", partial ? "1" : "0")] {
                try insertMeta.reset()
                try insertMeta.bind(1, key)
                try insertMeta.bind(2, value)
                try insertMeta.run()
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Folded, de-duplicated (order kept), space-joined.
    private static func foldedUnique(_ values: [String]) -> String {
        var seen = Set<String>()
        return values.map(foldForSearch).filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: " ")
    }

    /// `["en", "fr"]` -> `"|en|fr|"`; empty -> `"|"`.
    private static func pipeList(_ values: [String]) -> String {
        "|" + values.map { $0 + "|" }.joined()
    }

    // MARK: - Search

    private func runSearch(_ q: SearchQuery) throws -> [Work] {
        let folded = foldForSearch(q.text)
        let limit = max(q.limit, 0)
        let language = q.language.map { "%|\($0)|%" }
        let category = q.category == .popular ? nil : "%|\(q.category.rawValue)|%"

        guard !folded.isEmpty else {
            let stmt = try Statement(handle(), """
                SELECT id, json FROM works
                WHERE (?1 IS NULL OR languages LIKE ?1) AND (?2 IS NULL OR categories LIKE ?2)
                ORDER BY browse_rank DESC LIMIT ?3
                """)
            try bindFilters(stmt, language, category)
            try stmt.bind(3, Int64(limit))
            return try collect(stmt)
        }

        if folded.count <= Self.shortQueryMaxLength {
            // bm25 over a 1-2 character prefix would score most of the catalog. Instead match
            // the default title's first characters; the (prefix, browse_rank) index
            // yields rows already in order, so only `limit` rows are read.
            let column = folded.count == 1 ? "title_prefix1" : "title_prefix2"
            let stmt = try Statement(handle(), """
                SELECT id, json FROM works
                WHERE \(column) = ?3
                  AND (?1 IS NULL OR languages LIKE ?1) AND (?2 IS NULL OR categories LIKE ?2)
                ORDER BY browse_rank DESC LIMIT ?4
                """)
            try bindFilters(stmt, language, category)
            try stmt.bind(3, folded)
            try stmt.bind(4, Int64(limit))
            return try collect(stmt)
        }

        let tokens = folded.split(separator: " ").map(String.init)
        let match = tokens.map { "\"\(Self.quoteEscaped($0))\"*" }.joined(separator: " ")
        let exact = try Statement(handle(), """
            SELECT w.id, w.json FROM works_fts JOIN works w ON w.rowid = works_fts.rowid
            WHERE works_fts MATCH ?3
              AND (?1 IS NULL OR w.languages LIKE ?1) AND (?2 IS NULL OR w.categories LIKE ?2)
            ORDER BY bm25(works_fts, 10.0, 5.0, 1.0) - 2.0 * ln(1 + w.popularity) - 3.0 * w.has_se
            LIMIT ?4
            """)
        try bindFilters(exact, language, category)
        try exact.bind(3, match)
        try exact.bind(4, Int64(limit))
        var results = try collect(exact)

        guard results.count < Self.typoFallbackBelow, folded.count >= Self.typoMinQueryLength,
              results.count < limit
        else { return results }
        let found = Set(results.map(\.id))
        for work in try typoFallback(tokens, language, category, limit: limit - results.count)
        where !found.contains(work.id) {
            results.append(work)
        }
        return Array(results.prefix(limit))
    }

    /// Trigram candidates (best `typoCandidates` by FTS rank), re-ranked by trigram similarity:
    /// the mean, over query words, of each word's best `TypoTolerance.similarity` against the
    /// words of the work's title and authors; ties go to the more popular work.
    private func typoFallback(_ tokens: [String], _ language: String?, _ category: String?, limit: Int) throws -> [Work] {
        let tokenTrigrams = tokens.map { TypoTolerance.trigrams(folded: $0) }
        let trigrams = Set(zip(tokens, tokenTrigrams).filter { $0.0.count >= 3 }.flatMap(\.1))
        guard !trigrams.isEmpty else { return [] }
        let match = trigrams.sorted().map { "\"\(Self.quoteEscaped($0))\"" }.joined(separator: " OR ")

        let stmt = try Statement(handle(), """
            SELECT w.rowid, works_tri.title_authors, w.popularity
            FROM works_tri JOIN works w ON w.rowid = works_tri.rowid
            WHERE works_tri MATCH ?3
              AND (?1 IS NULL OR w.languages LIKE ?1) AND (?2 IS NULL OR w.categories LIKE ?2)
            ORDER BY rank LIMIT ?4
            """)
        try bindFilters(stmt, language, category)
        try stmt.bind(3, match)
        try stmt.bind(4, Int64(Self.typoCandidates))

        var scored: [(rowid: Int64, similarity: Double, popularity: Int64)] = []
        while try stmt.step() {
            let words = Set(stmt.text(1).split(separator: " ")).map { TypoTolerance.trigrams(folded: String($0)) }
            let similarity = tokenTrigrams.map { token in
                words.map { TypoTolerance.jaccard(token, $0) }.max() ?? 0
            }.reduce(0, +) / Double(tokens.count)
            if similarity >= Self.typoMinSimilarity {
                scored.append((stmt.int64(0), similarity, stmt.int64(2)))
            }
        }
        scored.sort { ($0.similarity, $0.popularity) > ($1.similarity, $1.popularity) }

        let fetch = try Statement(handle(), "SELECT id, json FROM works WHERE rowid = ?1")
        return try scored.prefix(limit).compactMap { candidate in
            try fetch.reset()
            try fetch.bind(1, candidate.rowid)
            return try fetch.step() ? decodeWork(fetch) : nil
        }
    }

    private static func quoteEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\"\"")
    }

    private func bindFilters(_ stmt: Statement, _ language: String?, _ category: String?) throws {
        try stmt.bind(1, language)
        try stmt.bind(2, category)
    }

    /// Reads `(id, json)` rows.
    private func collect(_ stmt: Statement) throws -> [Work] {
        var works: [Work] = []
        while try stmt.step() { works.append(try decodeWork(stmt)) }
        return works
    }

    private func decodeWork(_ stmt: Statement) throws -> Work {
        Work(id: stmt.text(0), editions: try decoder.decode([Edition].self, from: stmt.blob(1)))
    }

    private func exec(_ sql: String) throws {
        let db = try handle()
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else {
            throw CatalogDatabaseError.sqlite(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
    }
}

// MARK: - Prepared statements

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin prepared-statement wrapper. Used only on `CatalogDatabase`'s queue.
private final class Statement {
    private let db: OpaquePointer
    private let stmt: OpaquePointer

    init(_ db: OpaquePointer, _ sql: String) throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw CatalogDatabaseError.sqlite(code: rc, message: String(cString: sqlite3_errmsg(db)))
        }
        self.db = db
        self.stmt = stmt
    }

    deinit {
        sqlite3_finalize(stmt)
    }

    func bind(_ index: Int32, _ value: String?) throws {
        let rc = value.map { sqlite3_bind_text(stmt, index, $0, -1, SQLITE_TRANSIENT) } ?? sqlite3_bind_null(stmt, index)
        try check(rc)
    }

    func bind(_ index: Int32, _ value: Int64) throws {
        try check(sqlite3_bind_int64(stmt, index, value))
    }

    func bind(_ index: Int32, _ value: Double) throws {
        try check(sqlite3_bind_double(stmt, index, value))
    }

    func bind(_ index: Int32, _ value: Data) throws {
        let rc = value.withUnsafeBytes {
            sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
        }
        try check(rc)
    }

    /// Returns true while a row is available.
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw error(rc)
    }

    /// Steps a statement that returns no rows.
    func run() throws {
        _ = try step()
    }

    func reset() throws {
        try check(sqlite3_reset(stmt))
    }

    func text(_ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(stmt, column)
    }

    func blob(_ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, column)))
    }

    private func check(_ rc: Int32) throws {
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    private func error(_ rc: Int32) -> CatalogDatabaseError {
        .sqlite(code: rc, message: String(cString: sqlite3_errmsg(db)))
    }
}
