import Foundation

public enum WorkGrouper {
    /// Groups editions of the same work (by `matchKey`). Within a work, Standard Ebooks
    /// editions come first, then by downloads descending, then by id. Works keep the
    /// order in which their first edition appeared.
    public static func group(_ editions: [Edition]) -> [Work] {
        var order: [String] = []
        var buckets: [String: [Edition]] = [:]
        for e in editions {
            let key = matchKey(title: e.title, primaryAuthor: e.authors.first ?? "")
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(e)
        }
        return order.map { key in
            Work(id: key, editions: buckets[key]!.sorted(by: isPreferred))
        }
    }

    private static func isPreferred(_ a: Edition, _ b: Edition) -> Bool {
        let aSE = a.source == .standardEbooks, bSE = b.source == .standardEbooks
        if aSE != bSE { return aSE }
        if a.downloads != b.downloads { return a.downloads > b.downloads }
        return a.id < b.id
    }
}
