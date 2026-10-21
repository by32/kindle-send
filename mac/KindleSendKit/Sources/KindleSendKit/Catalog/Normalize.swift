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
public func displayAuthor(fromGutenberg raw: String) -> String {
    let parts = raw.split(separator: ",", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.contains(where: \.isNumber) }
    guard let family = parts.first else { return raw.trimmingCharacters(in: .whitespaces) }
    guard parts.count > 1 else { return family }
    return parts[1] + " " + family
}

/// Cuts a title at the first `;`, `:` or ` or,` subtitle marker.
private func cutSubtitle(_ title: String) -> String {
    let markers = [";", ":", " or,"]
    let cut = markers
        .compactMap { title.range(of: $0, options: .caseInsensitive)?.lowerBound }
        .min()
    return cut.map { String(title[..<$0]) } ?? title
}
