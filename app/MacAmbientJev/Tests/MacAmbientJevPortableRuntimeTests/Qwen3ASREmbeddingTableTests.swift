import Foundation
import Testing
@testable import MacAmbientJevPortableRuntime

struct Qwen3ASREmbeddingTableTests {
    @Test
    func readsLittleEndianRowsAndConvertsEveryColumn() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let words: [UInt16] = [
            0xBC00, 0x0000, 0x8000, 0x3C00, 0x7BFF, 0x0001,
            0x03FF, 0x0400, 0xC000, 0x4000, 0xC200, 0x0001,
            0x7C00, 0xFC00, 0x7E00, 0xFE00, 0x0000, 0x8000,
        ]
        let url = try write(words, named: "embeddings.bin", to: directory)
        let table = try Qwen3ASREmbeddingTable(contentsOf: url, vocabSize: 3, hiddenSize: 6)

        #expect(table.vocabSize == 3)
        #expect(table.hiddenSize == 6)
        let firstRowBits: [UInt32] = [0xBF80_0000, 0x0000_0000, 0x8000_0000, 0x3F80_0000, 0x477F_E000, 0x3380_0000]
        let secondRowBits: [UInt32] = [0x387F_C000, 0x3880_0000, 0xC000_0000, 0x4000_0000, 0xC040_0000, 0x3380_0000]
        let firstRow = try table.row(0)
        let secondRow = try table.row(1)
        #expect(firstRow.map(\.bitPattern) == firstRowBits)
        #expect(secondRow.map(\.bitPattern) == secondRowBits)
        #expect(try table.row(0).map(\.bitPattern) == firstRowBits)
        #expect(try table.row(1).map(\.bitPattern) == secondRowBits)
    }

    @Test
    func convertsInfinitiesAndNaNs() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try write([0x7C00, 0xFC00, 0x7E00, 0xFE00], named: "embeddings.bin", to: directory)
        let table = try Qwen3ASREmbeddingTable(contentsOf: url, vocabSize: 1, hiddenSize: 4)
        let row = try table.row(0)

        #expect(row[0] == .infinity)
        #expect(row[1] == -.infinity)
        #expect(row[2].isNaN)
        #expect(row[3].isNaN)
    }

    @Test
    func tokenIDsOutsideVocabularyFail() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try write([0x3C00, 0x4000], named: "embeddings.bin", to: directory)
        let table = try Qwen3ASREmbeddingTable(contentsOf: url, vocabSize: 2, hiddenSize: 1)
        #expect(throws: Qwen3ASREmbeddingError.invalidTokenID(-1)) { try table.row(-1) }
        #expect(throws: Qwen3ASREmbeddingError.invalidTokenID(2)) { try table.row(2) }
    }

    @Test
    func fileSizeMustMatchExactExpectedByteCount() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cases: [(name: String, words: [UInt16], actualByteCount: UInt64)] = [
            ("short", [0, 0, 0, 0, 0], 10),
            ("long", [0, 0, 0, 0, 0, 0, 0], 14),
            ("empty", [], 0),
        ]
        for fixture in cases {
            let url = try write(fixture.words, named: fixture.name, to: directory)
            #expect(throws: Qwen3ASREmbeddingError.sizeMismatch(expected: 12, actual: fixture.actualByteCount)) {
                try Qwen3ASREmbeddingTable(contentsOf: url, vocabSize: 2, hiddenSize: 3)
            }
        }
    }

    @Test
    func invalidDimensionsAndSizeOverflowFailBeforeReadingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("Qwen3ASREmbeddingTableTests-absent-\(UUID().uuidString)")
        #expect(throws: Qwen3ASREmbeddingError.invalidDimensions(vocabSize: 0, hiddenSize: 1)) {
            try Qwen3ASREmbeddingTable(contentsOf: missing, vocabSize: 0, hiddenSize: 1)
        }
        #expect(throws: Qwen3ASREmbeddingError.invalidDimensions(vocabSize: 1, hiddenSize: -1)) {
            try Qwen3ASREmbeddingTable(contentsOf: missing, vocabSize: 1, hiddenSize: -1)
        }
        #expect(throws: Qwen3ASREmbeddingError.sizeOverflow) {
            try Qwen3ASREmbeddingTable(contentsOf: missing, vocabSize: Int.max, hiddenSize: 2)
        }
    }

    @Test
    func missingFileIsReportedAsUnreadable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("missing.bin")
        #expect(throws: Qwen3ASREmbeddingError.self) {
            try Qwen3ASREmbeddingTable(contentsOf: missing, vocabSize: 2, hiddenSize: 1)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Qwen3ASREmbeddingTableTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func write(_ words: [UInt16], named name: String, to directory: URL) throws -> URL {
        let bytes = words.flatMap { word in
            [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8)]
        }
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }
}
