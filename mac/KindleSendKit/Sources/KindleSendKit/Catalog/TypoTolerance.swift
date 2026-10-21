import Foundation

public enum TypoTolerance {
    /// Contiguous 3-character windows of the folded string. A non-empty string shorter
    /// than 3 characters yields itself, so short words can still match exactly.
    public static func trigrams(_ s: String) -> Set<String> {
        trigrams(folded: foldForSearch(s))
    }

    /// Jaccard similarity of the two strings' trigram sets, in 0...1.
    public static func similarity(_ a: String, _ b: String) -> Double {
        jaccard(trigrams(a), trigrams(b))
    }

    /// `trigrams(_:)` for text already passed through `foldForSearch`.
    static func trigrams(folded: String) -> Set<String> {
        let chars = Array(folded)
        guard chars.count >= 3 else { return chars.isEmpty ? [] : [folded] }
        return Set((0...(chars.count - 3)).map { String(chars[$0..<($0 + 3)]) })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let shared = a.intersection(b).count
        let union = a.count + b.count - shared
        return union == 0 ? 0 : Double(shared) / Double(union)
    }
}
