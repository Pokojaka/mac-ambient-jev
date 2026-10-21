import Foundation
import Testing
@testable import MacAmbientJevCore

struct FileSHA256Tests {
    private static let vectors: [(count: Int, byte: UInt8, digest: String)] = [
        (0, 0x61, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        (55, 0x61, "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"),
        (56, 0x61, "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"),
        (64, 0x61, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"),
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
