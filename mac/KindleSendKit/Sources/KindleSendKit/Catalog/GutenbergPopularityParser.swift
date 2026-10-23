import Foundation

/// Parses Gutenberg's `browse/scores/top1000.php` page.
public enum GutenbergPopularityParser {
    /// Maps ebook id to its download count over the last 30 days. The page also
    /// lists yesterday and 7-day sections, but their counts are on different
    /// scales, so only the `books-last30` section is read.
    public static func parse(html: String) -> [Int: Int] {
        guard let heading = html.range(of: #"id="books-last30""#) else { return [:] }
        let rest = html[heading.upperBound...]
        let section = rest[..<(rest.range(of: "</ol>")?.lowerBound ?? rest.endIndex)]
        let pattern = /\/ebooks\/(\d+)">[^<]*\((\d+)\)<\/a>/
        var result: [Int: Int] = [:]
        for match in section.matches(of: pattern) {
            guard let id = Int(match.1), let count = Int(match.2), result[id] == nil else { continue }
            result[id] = count
        }
        return result
    }
}
