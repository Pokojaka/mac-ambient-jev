import Foundation
import Testing
@testable import MacAmbientJevCore

struct FileSHA256Tests {
    private static let vectors: [(count: Int, byte: UInt8, digest: String)] = [
        (0, 0x61, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        (55, 0x61, "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"),
        (56, 0x61, "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"),
        (63, 0x61, "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34"),
        (64, 0x61, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"),
        (65, 0x61, "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0"),
        (119, 0x61, "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb"),
        (120, 0x61, "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c"),
        (127, 0x61, "c57e9278af78fa3cab38667bef4ce29d783787a2f731d4e12200270f0c32320a"),
        (128, 0x61, "6836cf13bac400e9105071cd6af47084dfacad4e5e302c94bfed24e013afb73e"),
        (129, 0x61, "c12cb024a2e5551cca0e08fce8f1c5e314555cc3fef6329ee994a3db752166ae"),
        (1_000, 0x61, "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    ]

    @Test func dataDigestMatchesStandardVectorsAndPaddingBoundaries() {
        #expect(FileSHA256.hexDigest(of: Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        for vector in Self.vectors {
            #expect(FileSHA256.hexDigest(of: Data(repeating: vector.byte, count: vector.count)) == vector.digest)
        }
    }

    @Test func fileDigestIsIndependentOfChunkSize() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for vector in Self.vectors {
            let url = directory.appendingPathComponent("vector-\(vector.count).bin")
            try Data(repeating: vector.byte, count: vector.count).write(to: url)
            for chunkSize in [1, 7, 63, 64, 65, 4_096, FileSHA256.chunkSize] {
                #expect(try FileSHA256.hexDigest(ofFileAt: url, chunkSize: chunkSize) == vector.digest)
            }
            #expect(try FileSHA256.hexDigest(ofFileAt: url) == vector.digest)
        }
    }

    @Test func fileLargerThanOneChunkMatchesDataDigest() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data((0..<(FileSHA256.chunkSize + 12_345)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let url = directory.appendingPathComponent("large.bin")
        try payload.write(to: url)

        #expect(try FileSHA256.hexDigest(ofFileAt: url) == FileSHA256.hexDigest(of: payload))
    }

    @Test func nist448BitVectorMatchesDataAndFile() throws {
        let payload = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
        let digest = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        #expect(payload.count == 56)
        #expect(FileSHA256.hexDigest(of: payload) == digest)

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nist-448-bit-vector.bin")
        try payload.write(to: url)
        for chunkSize in [1, 7, 55, 56, 63, 64, 65, FileSHA256.chunkSize] {
            #expect(try FileSHA256.hexDigest(ofFileAt: url, chunkSize: chunkSize) == digest)
        }
    }

    @Test func millionByteKnownVectorMatchesDataAndFile() throws {
        let digest = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        let payload = Data(repeating: 0x61, count: 1_000_000)
        #expect(FileSHA256.hexDigest(of: payload) == digest)

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("million-as.bin")
        try payload.write(to: url)
        for chunkSize in [63, 65, 4_093, FileSHA256.chunkSize] {
            #expect(try FileSHA256.hexDigest(ofFileAt: url, chunkSize: chunkSize) == digest)
        }
    }

    @Test func missingFileThrows() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: (any Error).self) {
            try FileSHA256.hexDigest(ofFileAt: directory.appendingPathComponent("missing.bin"))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSHA256Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
