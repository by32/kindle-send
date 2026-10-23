import Foundation

public enum GutenbergCatalogError: Error, Equatable {
    case missingHeader
    case unexpectedHeader(String)
}

/// Parses Project Gutenberg's `pg_catalog.csv` into `Edition`s.
public enum GutenbergCatalogParser {
    private static let expectedHeader = [
        "Text#", "Type", "Issued", "Title", "Language",
        "Authors", "Subjects", "LoCC", "Bookshelves",
    ]

    /// Only `Text` rows are returned; downloads are 0 (see `GutenbergPopularityParser`).
    public static func parse(csv: String) throws -> [Edition] {
        let rows = readRecords(csv)
        guard let header = rows.first else { throw GutenbergCatalogError.missingHeader }
        let cleaned = header.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")) }
        guard cleaned == expectedHeader else {
            throw GutenbergCatalogError.unexpectedHeader(cleaned.joined(separator: ","))
        }
        return rows.dropFirst().compactMap(edition(from:))
    }

    private static func edition(from row: [String]) -> Edition? {
        guard row.count >= expectedHeader.count, row[1] == "Text",
              let number = Int(row[0]),
              let cover = URL(string: "https://www.gutenberg.org/cache/epub/\(number)/pg\(number).cover.medium.jpg")
        else { return nil }

        var authors: [String] = []
        var credits: [String] = []
        var firstCredited: String?
        for raw in splitList(row[5]) {
            if let (name, role) = splitRole(raw) {
                let display = displayAuthor(fromGutenberg: name)
                firstCredited = firstCredited ?? display
                credits.append("\(display) (\(role))")
            } else {
                authors.append(displayAuthor(fromGutenberg: raw))
            }
        }
        if authors.isEmpty, let firstCredited { authors = [firstCredited] }
        return Edition(
            id: "pg:\(number)",
            source: .gutenberg,
            title: row[3].trimmingCharacters(in: .whitespacesAndNewlines),
            authors: authors,
            languages: splitList(row[4]),
            subjects: splitList(row[6]) + splitList(row[8]),
            credits: credits.isEmpty ? nil : credits.joined(separator: "; "),
            coverURL: cover,
            issued: row[2].isEmpty ? nil : row[2]
        )
    }

    private static func splitList(_ s: String) -> [String] {
        s.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// "Maude, Aylmer, 1858-1938 [Translator]" -> ("Maude, Aylmer, 1858-1938", "Translator").
    private static func splitRole(_ s: String) -> (String, String)? {
        guard s.hasSuffix("]"), let open = s.lastIndex(of: "[") else { return nil }
        let role = s[s.index(after: open)..<s.index(before: s.endIndex)]
        let name = s[..<open].trimmingCharacters(in: .whitespaces)
        return (name, String(role))
    }

    /// RFC 4180 reader: quoted fields, doubled quotes, CR/LF inside quotes.
    private static func readRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var pendingQuote = false  // saw a `"` inside quotes; may be an escape or the closer
        var fieldStarted = false

        func endField() {
            record.append(String(field))
            field = String.UnicodeScalarView()
            fieldStarted = false
        }
        func endRecord() {
            endField()
            if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
            record = []
        }

        for scalar in text.unicodeScalars {
            if pendingQuote {
                pendingQuote = false
                if scalar == "\"" {
                    field.append(scalar)
                    continue
                }
                inQuotes = false
            }
            if inQuotes {
                if scalar == "\"" { pendingQuote = true } else { field.append(scalar) }
                continue
            }
            switch scalar {
            case "\"" where !fieldStarted:
                inQuotes = true
                fieldStarted = true
            case ",":
                endField()
            case "\n":
                endRecord()
            case "\r":
                break  // the following "\n" ends the record
            default:
                field.append(scalar)
                fieldStarted = true
            }
        }
        if fieldStarted || !record.isEmpty { endRecord() }
        return records
    }
}
