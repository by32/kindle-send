import Foundation

/// Parses Gutenberg's `browse/scores/top1000.php` page.
public enum GutenbergPopularityParser {
    /// Maps ebook id to download count. The page lists several periods
    /// (yesterday, 7 days, 30 days); the first occurrence of each id wins.
    public static func parse(html: String) -> [Int: Int] {
        let pattern = /\/ebooks\/(\d+)">[^<]*\((\d+)\)<\/a>/
        var result: [Int: Int] = [:]
        for match in html.matches(of: pattern) {
            guard let id = Int(match.1), let count = Int(match.2), result[id] == nil else { continue }
            result[id] = count
        }
        return result
    }
}
