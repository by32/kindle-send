import Foundation
import SQLite3

public struct SearchQuery: Sendable, Equatable {
    public var text: String
    public var category: Category
    /// ISO 639-1 code; nil = all languages.
    public var language: String?
    public var limit: Int = 120

    public init(text: String, category: Category = .popular, language: String? = nil, limit: Int = 120) {
        self.text = text
        self.category = category
        self.language = language
        self.limit = limit
    }
}

public enum CatalogDatabaseError: Error, Equatable {
    case sqlite(code: Int32, message: String)
}

/// The local SQLite search index. Every use of the sqlite handle runs on `queue`.
public final class CatalogDatabase: @unchecked Sendable {
    private let queue = DispatchQueue(label: "KindleSendKit.CatalogDatabase")
    private let db: OpaquePointer
    private let decoder = JSONDecoder()

    /// Exact searches returning fewer hits than this trigger the typo fallback.
    private static let typoFallbackBelow = 5
    private static let typoMinQueryLength = 4
    private static let typoCandidates = 300
    private static let typoMinSimilarity = 0.3

    /// Opens (or creates) the database at `url`; nil = in-memory.
    public init(url: URL?) throws {
        var handle: OpaquePointer?
        let path = url?.path ?? ":memory:"
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(handle)
            throw CatalogDatabaseError.sqlite(code: rc, message: message)
        }
        db = handle
        try queue.sync {
            try exec("PRAGMA journal_mode=WAL")
            try exec(Self.schema)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    /// Builds a fresh database at `url` (replacing any existing file; nil = in-memory),
    /// writing every work in one transaction.
    public static func build(at url: URL?, works: [Work]) throws -> CatalogDatabase {
        if let url {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let database = try CatalogDatabase(url: url)
        try database.queue.sync { try database.insert(works) }
        return database
    }

    public func search(_ q: SearchQuery) throws -> [Work] {
        try queue.sync { try runSearch(q) }
    }

    public func work(id: String) throws -> Work? {
        try queue.sync {
            let stmt = try Statement(db, "SELECT id, json FROM works WHERE id = ?1")
            try stmt.bind(1, id)
            return try stmt.step() ? decodeWork(stmt) : nil
        }
    }

    public var builtAt: Date? {
        queue.sync {
            guard let stmt = try? Statement(db, "SELECT value FROM meta WHERE key = 'built_at'"),
                  (try? stmt.step()) == true,
                  let seconds = Double(stmt.text(0))
            else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
    }

    // MARK: - Schema and build

    private static let schema = """
        CREATE TABLE IF NOT EXISTS works(
            id TEXT PRIMARY KEY, json BLOB, popularity INTEGER, has_se INTEGER,
            languages TEXT, categories TEXT);
        CREATE INDEX IF NOT EXISTS works_browse ON works(has_se DESC, popularity DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS works_fts USING fts5(
            title, authors, subjects, content='', tokenize='unicode61 remove_diacritics 2');
        CREATE VIRTUAL TABLE IF NOT EXISTS works_tri USING fts5(title_authors, tokenize='trigram');
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        """

    private func insert(_ works: [Work]) throws {
        try exec("BEGIN")
        do {
            let encoder = JSONEncoder()
            let insertWork = try Statement(db, """
                INSERT INTO works(rowid, id, json, popularity, has_se, languages, categories)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                """)
            let insertFTS = try Statement(db, "INSERT INTO works_fts(rowid, title, authors, subjects) VALUES (?1, ?2, ?3, ?4)")
            let insertTri = try Statement(db, "INSERT INTO works_tri(rowid, title_authors) VALUES (?1, ?2)")

            for (index, work) in works.enumerated() {
                let rowid = Int64(index + 1)
                let editions = work.editions
                let languages = Set(editions.flatMap(\.languages)).sorted()
                let categories = Category.allCases.filter { $0 != .popular && $0.matches(work) }.map(\.rawValue)
                let titles = Self.foldedUnique(editions.map(\.title))
                let authors = Self.foldedUnique(editions.flatMap(\.authors))
                let subjects = Self.foldedUnique(editions.flatMap(\.subjects))

                try insertWork.reset()
                try insertWork.bind(1, rowid)
                try insertWork.bind(2, work.id)
                try insertWork.bind(3, try encoder.encode(editions))
                try insertWork.bind(4, Int64(editions.map(\.downloads).max() ?? 0))
                try insertWork.bind(5, editions.contains { $0.source == .standardEbooks } ? 1 : 0)
                try insertWork.bind(6, Self.pipeList(languages))
                try insertWork.bind(7, Self.pipeList(categories))
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

            let meta = try Statement(db, "INSERT OR REPLACE INTO meta(key, value) VALUES ('built_at', ?1)")
            try meta.bind(1, String(Date().timeIntervalSince1970))
            try meta.run()
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
            let stmt = try Statement(db, """
                SELECT id, json FROM works
                WHERE (?1 IS NULL OR languages LIKE ?1) AND (?2 IS NULL OR categories LIKE ?2)
                ORDER BY has_se DESC, popularity DESC LIMIT ?3
                """)
            try bindFilters(stmt, language, category)
            try stmt.bind(3, Int64(limit))
            return try collect(stmt)
        }

        let tokens = folded.split(separator: " ").map(String.init)
        let match = tokens.map { "\"\(Self.quoteEscaped($0))\"*" }.joined(separator: " ")
        let exact = try Statement(db, """
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

        let stmt = try Statement(db, """
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

        let fetch = try Statement(db, "SELECT id, json FROM works WHERE rowid = ?1")
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
