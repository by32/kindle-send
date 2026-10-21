import Foundation

public enum Batching {
    /// Reserved for the message headers, text part and closing boundary.
    public static let messageOverhead = 8 * 1024
    /// Reserved for each attachment's MIME part headers and boundary.
    public static let attachmentOverhead = 4 * 1024

    /// Estimated size of a message carrying one attachment of `byteCount` bytes, overhead included.
    public static func singleMessageSize(_ byteCount: Int) -> Int {
        messageOverhead + attachmentOverhead + encodedSize(byteCount)
    }
    /// Size of `byteCount` bytes as a base64 body: 4*ceil(n/3), plus CRLF after every 76 characters.
    public static func encodedSize(_ byteCount: Int) -> Int {
        guard byteCount > 0 else { return 0 }
        let encoded = 4 * ((byteCount + 2) / 3)
        let lines = (encoded + 75) / 76
        return encoded + 2 * lines
    }

    /// Greedy, order-preserving split so each whole message (encoded bodies plus reserved MIME overhead)
    /// stays within `maxBytes` and `maxCount`. An item that exceeds `maxBytes` on its own gets a batch to itself.
    public static func batches(_ items: [Attachment], maxBytes: Int, maxCount: Int = 25) -> [[Attachment]] {
        var result: [[Attachment]] = []
        var current: [Attachment] = []
        var currentSize = messageOverhead
        for item in items {
            let size = encodedSize(item.data.count) + attachmentOverhead
            if !current.isEmpty, currentSize + size > maxBytes || current.count >= maxCount {
                result.append(current)
                current = []
                currentSize = messageOverhead
            }
            current.append(item)
            currentSize += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
