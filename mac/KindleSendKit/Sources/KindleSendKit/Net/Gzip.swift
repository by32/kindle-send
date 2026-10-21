import Foundation

public enum GzipError: Error, Equatable {
    case notGzip
    case truncated
    case inflateFailed
    /// The inflated length disagrees with the trailer's ISIZE.
    case sizeMismatch
}

/// Single-member gzip (RFC 1952) decoding with Foundation only.
enum Gzip {
    private static let fhcrc: UInt8 = 0x02, fextra: UInt8 = 0x04, fname: UInt8 = 0x08, fcomment: UInt8 = 0x10

    /// Skips the header and its optional fields, inflates the raw DEFLATE body (Apple's `.zlib`
    /// is raw DEFLATE, RFC 1951) and checks the result against the trailer's ISIZE.
    static func decompress(_ gz: Data) throws -> Data {
        let bytes = [UInt8](gz)
        guard bytes.count >= 2, bytes[0] == 0x1f, bytes[1] == 0x8b else { throw GzipError.notGzip }
        guard bytes.count >= 18 else { throw GzipError.truncated }
        guard bytes[2] == 8 else { throw GzipError.notGzip }   // CM = deflate
        let flags = bytes[3]
        var offset = 10

        func skipZeroTerminated() throws {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { throw GzipError.truncated }
            offset = end + 1
        }
        if flags & fextra != 0 {
            guard offset + 2 <= bytes.count else { throw GzipError.truncated }
            offset += 2 + (Int(bytes[offset]) | Int(bytes[offset + 1]) << 8)
        }
        if flags & fname != 0 { try skipZeroTerminated() }
        if flags & fcomment != 0 { try skipZeroTerminated() }
        if flags & fhcrc != 0 { offset += 2 }

        let trailer = bytes.count - 8
        guard offset <= trailer else { throw GzipError.truncated }
        let inflated: Data
        do {
            inflated = try (Data(bytes[offset..<trailer]) as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw GzipError.inflateFailed
        }
        let isize = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[trailer + 4 + $1]) << (8 * UInt32($1)) }
        guard UInt32(truncatingIfNeeded: inflated.count) == isize else { throw GzipError.sizeMismatch }
        return inflated
    }
}
