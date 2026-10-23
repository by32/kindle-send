import Foundation
import Testing
@testable import KindleSendKit

@Suite struct GzipTests {
    private static func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The fixture's deflate stream and trailer, after its 10-byte header and FNAME field.
    private static func deflateAndTrailer() throws -> Data {
        let gz = try fixture("pg_catalog_sample.csv", "gz")
        #expect(gz[3] & 0x08 != 0, "fixture should carry FNAME")
        let nameEnd = try #require(gz[10...].firstIndex(of: 0))
        return gz[(nameEnd + 1)...]
    }

    private static func header(flags: UInt8) -> Data {
        Data([0x1f, 0x8b, 0x08, flags, 0, 0, 0, 0, 0, 0x03])
    }

    @Test func decompressesFixtureWithFileName() throws {
        let csv = try Self.fixture("pg_catalog_sample", "csv")
        #expect(try Gzip.decompress(Self.fixture("pg_catalog_sample.csv", "gz")) == csv)
    }

    @Test func decompressesWithoutOptionalFields() throws {
        let gz = Self.header(flags: 0) + (try Self.deflateAndTrailer())
        #expect(try Gzip.decompress(gz) == (try Self.fixture("pg_catalog_sample", "csv")))
    }

    @Test func skipsExtraCommentAndHeaderCRC() throws {
        let extra = Data([3, 0, 0xAA, 0xBB, 0xCC])            // FEXTRA: length 3 + bytes
        let comment = Data("a comment".utf8) + Data([0])     // FCOMMENT
        let crc = Data([0x12, 0x34])                          // FHCRC
        let gz = Self.header(flags: 0x04 | 0x10 | 0x02) + extra + comment + crc + (try Self.deflateAndTrailer())
        #expect(try Gzip.decompress(gz) == (try Self.fixture("pg_catalog_sample", "csv")))
    }

    @Test func rejectsNonGzip() {
        #expect(throws: GzipError.self) { try Gzip.decompress(Data("Text#,Type\n".utf8)) }
    }

    @Test func rejectsTruncatedData() throws {
        let gz = try Self.fixture("pg_catalog_sample.csv", "gz")
        #expect(throws: GzipError.self) { try Gzip.decompress(gz.prefix(gz.count / 2)) }
        #expect(throws: GzipError.self) { try Gzip.decompress(gz.prefix(12)) }
    }

    @Test func rejectsSizeMismatch() throws {
        var gz = try Self.fixture("pg_catalog_sample.csv", "gz")
        gz[gz.count - 1] ^= 0xFF
        #expect(throws: GzipError.sizeMismatch) { try Gzip.decompress(gz) }
    }
}
