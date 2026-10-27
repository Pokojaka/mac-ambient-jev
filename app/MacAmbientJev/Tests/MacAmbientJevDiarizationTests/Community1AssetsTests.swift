import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevDiarization

struct Community1AssetsTests {
    @Test func committedPLDAFixturesMatchTheManifestPins() throws {
        let manifest = try Community1Manifest.bundled()
        let plda = try DiarizationParityFixtures.data(named: "plda-parameters.json")
        let xvector = try DiarizationParityFixtures.data(named: "xvector-transform.json")

        #expect(FileSHA256.hexDigest(of: plda) == (try manifest.file(.plda).sha256))
        #expect(plda.count == (try manifest.file(.plda).byteCount))
        #expect(FileSHA256.hexDigest(of: xvector) == (try manifest.file(.xvector).sha256))
        #expect(xvector.count == (try manifest.file(.xvector).byteCount))
    }

    @Test func verifiedDirectoryYieldsPathsAndPLDAWithManifestSigns() throws {
        let directory = try makeModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory.root) }

        let assets = try Community1Assets(modelDirectory: directory.root, manifest: directory.manifest)

        #expect(assets.segmentationURL.lastPathComponent == "segmentation-3.0.onnx")
        #expect(assets.embeddingURL.lastPathComponent == "wespeaker-multimask-tail.onnx")
        #expect(assets.plda.projectionRows.count == 128)
        for (row, sign) in directory.manifest.coordinateSigns.enumerated() {
            let largest = assets.plda.projectionRows[row].max { abs($0) < abs($1) }
            #expect((try #require(largest) < 0 ? -1 : 1) == sign)
        }
    }

    @Test func directoryWithSpacesAndNonASCIIIsAccepted() throws {
        let directory = try makeModelDirectory(folderName: "モデル 置き場 ü")
        defer { try? FileManager.default.removeItem(at: directory.root.deletingLastPathComponent()) }

        _ = try Community1Assets(modelDirectory: directory.root, manifest: directory.manifest)
    }

    @Test func missingFileNamesTheFileAndTheFetchCommand() throws {
        let directory = try makeModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory.root) }
        try FileManager.default.removeItem(at: directory.root.appendingPathComponent("wespeaker-multimask-tail.onnx"))

        let error = try #require(throwsError { try Community1Assets(modelDirectory: directory.root, manifest: directory.manifest) })
        guard case let .missingFile(name, _) = error else {
            Issue.record("expected missingFile, got \(error)")
            return
        }
        #expect(name == "wespeaker-multimask-tail.onnx")
        #expect(error.description.contains("scripts/fetch_community1_diarization.py"))
    }

    @Test func corruptContentWithTheRightSizeFailsTheHash() throws {
        let directory = try makeModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory.root) }
        let url = directory.root.appendingPathComponent("segmentation-3.0.onnx")
        var bytes = try Data(contentsOf: url)
        bytes[0] ^= 0xff
        try bytes.write(to: url)

        let error = try #require(throwsError { try Community1Assets(modelDirectory: directory.root, manifest: directory.manifest) })
        guard case let .hashMismatch(name, expected, actual) = error else {
            Issue.record("expected hashMismatch, got \(error)")
            return
        }
        #expect(name == "segmentation-3.0.onnx")
        #expect(expected != actual)
    }

    @Test func wrongSizeFailsBeforeHashing() throws {
        let directory = try makeModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory.root) }
        let url = directory.root.appendingPathComponent("plda-parameters.json")
        try (try Data(contentsOf: url) + Data([0x20])).write(to: url)

        let error = try #require(throwsError { try Community1Assets(modelDirectory: directory.root, manifest: directory.manifest) })
        guard case let .sizeMismatch(name, expected, actual) = error else {
            Issue.record("expected sizeMismatch, got \(error)")
            return
        }
        #expect(name == "plda-parameters.json")
        #expect(actual == expected + 1)
    }

    @Test func directoryInPlaceOfFileIsRejected() throws {
        let directory = try makeModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory.root) }
        let url = directory.root.appendingPathComponent("xvector-transform.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        let error = try #require(throwsError { try Community1Assets(modelDirectory: directory.root, manifest: directory.manifest) })
        guard case .notRegularFile = error else {
            Issue.record("expected notRegularFile, got \(error)")
            return
        }
    }

    @Test func missingDirectoryReportsMissingFile() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("community1-missing-\(UUID().uuidString)", isDirectory: true)

        let error = try #require(throwsError { try Community1Assets(modelDirectory: missing, manifest: try Community1Manifest.bundled()) })
        guard case .missingFile = error else {
            Issue.record("expected missingFile, got \(error)")
            return
        }
    }

    @Test func invalidManifestsAreRejected() throws {
        let valid = try Community1Manifest.bundled()
        var invalid: [(String, Community1Manifest)] = []
        invalid.append(("missing role", .init(sources: valid.sources, files: Array(valid.files.dropLast()), coordinateSigns: valid.coordinateSigns)))
        invalid.append(("duplicate role", .init(sources: valid.sources, files: valid.files + [valid.files[0]], coordinateSigns: valid.coordinateSigns)))
        invalid.append(("short signs", .init(sources: valid.sources, files: valid.files, coordinateSigns: Array(valid.coordinateSigns.dropLast()))))
        invalid.append(("zero sign", .init(sources: valid.sources, files: valid.files, coordinateSigns: [0] + valid.coordinateSigns.dropFirst())))
        invalid.append(("unknown source", .init(sources: [:], files: valid.files, coordinateSigns: valid.coordinateSigns)))
        invalid.append(("path in name", .init(sources: valid.sources, files: replacing(valid.files, 0) { .init(role: $0.role, source: $0.source, name: "../x", byteCount: $0.byteCount, sha256: $0.sha256) }, coordinateSigns: valid.coordinateSigns)))
        invalid.append(("uppercase sha", .init(sources: valid.sources, files: replacing(valid.files, 0) { .init(role: $0.role, source: $0.source, name: $0.name, byteCount: $0.byteCount, sha256: $0.sha256.uppercased()) }, coordinateSigns: valid.coordinateSigns)))
        invalid.append(("zero size", .init(sources: valid.sources, files: replacing(valid.files, 0) { .init(role: $0.role, source: $0.source, name: $0.name, byteCount: 0, sha256: $0.sha256) }, coordinateSigns: valid.coordinateSigns)))
        for (name, manifest) in invalid {
            #expect(throws: Community1AssetsError.self, "\(name) must be rejected") {
                try manifest.validate()
            }
        }
        #expect(throws: Community1AssetsError.self) {
            try Community1Manifest.parse(Data("{}".utf8))
        }
    }

    private func replacing(
        _ files: [Community1Manifest.File],
        _ index: Int,
        with transform: (Community1Manifest.File) -> Community1Manifest.File
    ) -> [Community1Manifest.File] {
        var copy = files
        copy[index] = transform(copy[index])
        return copy
    }

    private func throwsError(_ body: () throws -> Void) -> Community1AssetsError? {
        do {
            try body()
            return nil
        } catch let error as Community1AssetsError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    private struct ModelDirectory {
        let root: URL
        let manifest: Community1Manifest
    }

    /// The real PLDA JSON files with the bundled manifest's pins; the two ONNX files are small stand-ins
    /// whose pins replace the real ones in the test manifest.
    private func makeModelDirectory(folderName: String = "models") throws -> ModelDirectory {
        let bundled = try Community1Manifest.bundled()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("Community1AssetsTests-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var files: [Community1Manifest.File] = []
        for file in bundled.files {
            switch file.role {
            case .plda, .xvector:
                try DiarizationParityFixtures.data(named: file.name).write(to: root.appendingPathComponent(file.name))
                files.append(file)
            case .segmentation, .embedding:
                let payload = Data("stand-in \(file.name)".utf8)
                try payload.write(to: root.appendingPathComponent(file.name))
                files.append(.init(
                    role: file.role, source: file.source, name: file.name,
                    byteCount: payload.count, sha256: FileSHA256.hexDigest(of: payload)
                ))
            }
        }
        return ModelDirectory(
            root: root,
            manifest: .init(sources: bundled.sources, files: files, coordinateSigns: bundled.coordinateSigns)
        )
    }
}
