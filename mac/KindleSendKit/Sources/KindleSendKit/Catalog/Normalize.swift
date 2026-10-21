import Foundation

/// Lowercased, diacritics folded, non-alphanumerics turned into spaces,
/// whitespace collapsed.
public func foldForSearch(_ s: String) -> String {
    let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    let mapped = String(folded.unicodeScalars.map {
        CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
    })
    return mapped.split(whereSeparator: { $0 == " " }).joined(separator: " ").lowercased()
}

/// Stable key identifying a work across editions and sources.
public func matchKey(title: String, primaryAuthor: String) -> String {
    var titleTokens = foldForSearch(cutSubtitle(title)).split(separator: " ").map(String.init)
    if titleTokens.count > 1, ["the", "a", "an"].contains(titleTokens[0]) {
        titleTokens.removeFirst()
    }
    let authorTokens = foldForSearch(primaryAuthor).split(separator: " ").map(String.init)
    var authorKey = authorTokens
    if let first = authorTokens.first, let last = authorTokens.last {
        authorKey = authorTokens.count == 1 ? [first] : [first, last]
    }
    return titleTokens.joined(separator: " ") + "|" + authorKey.joined(separator: " ")
}

/// "Austen, Jane, 1775-1817" -> "Jane Austen"; "Homer, 751? BCE-651? BCE" -> "Homer".
/// Parenthetical expansions are dropped: "Wells, H. G. (Herbert George), 1866-1946" -> "H. G. Wells".
public func displayAuthor(fromGutenberg raw: String) -> String {
    let stripped = raw.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
    let parts = stripped.split(separator: ",", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.contains(where: \.isNumber) }
    guard let family = parts.first else { return stripped.trimmingCharacters(in: .whitespaces) }
    guard parts.count > 1 else { return family }
    return parts[1] + " " + family
}

/// Cuts a title at the first `;`, `:`, ` or,` or line-break subtitle marker. Gutenberg often
/// puts the subtitle after an embedded newline ("In the South Seas\r\nBeing an Account…").
private func cutSubtitle(_ title: String) -> String {
    let markers = [";", ":", " or,"]
    // "\r\n" is a single Character, so line breaks are matched by Character, not substring.
    var cuts = markers.compactMap { title.range(of: $0, options: .caseInsensitive)?.lowerBound }
    if let lineBreak = title.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
        cuts.append(lineBreak)
    }
    return cuts.min().map { String(title[..<$0]) } ?? title
}
