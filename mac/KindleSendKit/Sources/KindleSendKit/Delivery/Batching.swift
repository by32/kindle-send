import Foundation

public enum Batching {
    /// Size of `byteCount` bytes as a base64 body: 4*ceil(n/3), plus CRLF after every 76 characters.
    public static func encodedSize(_ byteCount: Int) -> Int {
        guard byteCount > 0 else { return 0 }
        let encoded = 4 * ((byteCount + 2) / 3)
        let lines = (encoded + 75) / 76
        return encoded + 2 * lines
    }

    /// Greedy, order-preserving split so each batch stays within `maxBytes` (encoded) and `maxCount`.
    /// An item that exceeds `maxBytes` on its own gets a batch to itself.
    public static func batches(_ items: [Attachment], maxBytes: Int, maxCount: Int = 25) -> [[Attachment]] {
        var result: [[Attachment]] = []
        var current: [Attachment] = []
        var currentSize = 0
        for item in items {
            let size = encodedSize(item.data.count)
            if !current.isEmpty, currentSize + size > maxBytes || current.count >= maxCount {
                result.append(current)
                current = []
                currentSize = 0
            }
            current.append(item)
            currentSize += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
