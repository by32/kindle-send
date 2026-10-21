import Foundation

/// Parses Standard Ebooks listing pages and builds their URLs.
public enum StandardEbooksParser {
    private static let base = "https://standardebooks.org"

    /// Page N of the full catalog, 48 per page.
    public static let listingURL: @Sendable (Int) -> URL = { page in
        URL(string: "\(base)/ebooks?per-page=48&page=\(page)")!
    }

    public static func subjectURL(_ slug: String, page: Int) -> URL {
        URL(string: "\(base)/subjects/\(slug)?per-page=48&page=\(page)")!
    }

    /// Download URL of the compatible epub for an edition (path may include a translator segment).
    public static func epubURL(for edition: Edition) -> URL {
        let path = edition.id.hasPrefix("se:") ? String(edition.id.dropFirst(3)) : edition.id
        let parts = path.split(separator: "/").map(String.init)
        let file = parts.dropFirst().joined(separator: "_")
        return URL(string: "\(base)\(path)/downloads/\(file).epub?source=download")!
    }

    /// Empty result means the page is past the last page of the listing.
    public static func parseListing(html: String) -> [Edition] {
        matches(bookPattern, in: html).compactMap { match in
            let path = match[1]
            let body = match[2]
            let names = matches(namePattern, in: body)
            guard path.hasPrefix("/ebooks/"),
                  let title = names.first.map({ decodeEntities($0[1]) }), !title.isEmpty,
                  let src = matches(coverPattern, in: body).first?[1],
                  let cover = URL(string: src, relativeTo: URL(string: base))?.absoluteURL
            else { return nil }

            let authors = matches(authorPattern, in: body).compactMap { block in
                matches(namePattern, in: block[1]).first.map { decodeEntities($0[1]) }
            }
            let components = path.split(separator: "/")
            let credits = components.count >= 4 ? deslug(String(components[3])) : nil
            return Edition(
                id: "se:\(path)", source: .standardEbooks, title: title,
                authors: authors, languages: ["en"], subjects: [],
                credits: credits, downloads: 0, coverURL: cover)
        }
    }

    // MARK: - Helpers

    private static let bookPattern = regex(#"<li\b[^>]*typeof="schema:Book"[^>]*\babout="([^"]*)"[^>]*>(.*?)</li>"#)
    private static let namePattern = regex(#"<span\b[^>]*property="schema:name"[^>]*>(.*?)</span>"#)
    private static let authorPattern = regex(#"<p\b[^>]*class="author"[^>]*>(.*?)</p>"#)
    private static let coverPattern = regex(#"<img\b[^>]*\bsrc="([^"]*)""#)
    private static let entityPattern = regex(#"&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    }

    /// All matches as arrays of capture groups (index 0 is the whole match).
    private static func matches(_ re: NSRegularExpression, in text: String) -> [[String]] {
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
            }
        }
    }

    private static func decodeEntities(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for m in entityPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            switch name {
            case "amp": out += "&"
            case "lt": out += "<"
            case "gt": out += ">"
            case "quot": out += "\""
            case "apos": out += "'"
            default:
                let scalar = name.hasPrefix("#x")
                    ? UInt32(name.dropFirst(2), radix: 16)
                    : UInt32(name.dropFirst())
                if let scalar, let u = Unicode.Scalar(scalar) { out.unicodeScalars.append(u) }
                else { out += ns.substring(with: m.range) }
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deslug(_ slug: String) -> String {
        slug.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
