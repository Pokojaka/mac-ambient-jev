import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevPortableRuntime

struct ClauseTaggerAssetsTests {
    @Test func bundledManifestPinsTheReleaseAndTheFourMembers() throws {
        let manifest = try ClauseTaggerManifest.bundled()

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.release == .init(
            repository: "Pokojaka/mac-ambient-jev",
            tag: "clause-tagger-onnx-90501ea3-v1",
            asset: "clause-tagger-onnx-90501ea3-v1.tar.gz",
            byteCount: 110_829_019,
            sha256: "95985c53bacb0feea79b1f627864026cd22767f44eaf330eb0e5a0b4887ac30d",
            directory: "clause-tagger-onnx"
        ))
        #expect(manifest.model == .init(
            id: "sbintuitions/modernbert-ja-30m-multitagger",
            revision: "90501ea32d56d71f34287039512346537e0aaa4c8fd830e0c3b5746d8fb544c9",
            tokenizerSHA256: "0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062",
            encodingRevision: "1",
            unitPolicy: "btsj-utterance-sentence",
            trainingStatus: "trained"
        ))
        #expect(manifest.onnx.opset == 18)
        #expect(manifest.onnx.minimumSequenceLength == 2)
        #expect(manifest.onnx.maximumSequenceLength == 192)
        #expect(manifest.onnx.inputs == [
            .init(name: "input_ids", dtype: "int64", shape: [.fixed(1), .symbolic("seq")])
        ])
        #expect(manifest.onnx.outputs == [
            .init(name: "boundary_probs", dtype: "float32", shape: [.fixed(1), .symbolic("seq"), .fixed(2)]),
            .init(name: "span_probs", dtype: "float32", shape: [.fixed(1), .symbolic("seq"), .fixed(4)]),
            .init(name: "priority_probs", dtype: "float32", shape: [.fixed(1), .fixed(2)])
        ])
        #expect(manifest.members == [
            .init(
                role: .model, name: "ClauseTagger.onnx", byteCount: 146_889_561,
                sha256: "8f9e7d3e4f72f2b7d18db1c59bac6b9506d135f976512ae8afbff1386687b699"
            ),
            .init(
                role: .tokenizer, name: "tokenizer.json", byteCount: 6_724_873,
                sha256: "0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062"
            ),
            .init(
                role: .export, name: "export.json", byteCount: 253_705,
                sha256: "2d8d8e8585f9d34476d4e1377c8bcf90f47004c1aa4a7efe05f7d05acd292627"
            ),
            .init(
                role: .license, name: "LICENSE.txt", byteCount: 1_292,
                sha256: "2e97bfc46df586a08bb5942dc2af608d1aced6023735f65797d0ced0ba7fd77a"
            )
        ])
    }

    @Test func pinnedIdentityCarriesTheModelRevisionAndTokenizerHash() throws {
        let identity = try ClauseTaggerAssets.pinnedIdentity()

        #expect(identity.modelID == "sbintuitions/modernbert-ja-30m-multitagger")
        #expect(identity.revision == "90501ea32d56d71f34287039512346537e0aaa4c8fd830e0c3b5746d8fb544c9")
        #expect(identity.tokenizerSHA256 == "0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062")
    }

    @Test func verifiedDirectoryYieldsURLsAndIdentity() throws {
        let directory = try makeModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory.root.deletingLastPathComponent()) }

        let assets = try ClauseTaggerAssets(modelDirectory: directory.root, manifest: directory.manifest)

        #expect(assets.modelURL.lastPathComponent == "ClauseTagger.onnx")
        #expect(assets.tokenizerURL.lastPathComponent == "tokenizer.json")
        #expect(assets.identity == (try directory.manifest.identity()))
        #expect(assets.identity.backend == "onnx-clause-tagger")
    }

    @Test func directoryWithSpacesAndNonASCIIIsAccepted() throws {
        let directory = try makeModelDirectory(folderName: "モデル 置き場 ü")
        defer { try? FileManager.default.removeItem(at: directory.root.deletingLastPathComponent()) }

        _ = try ClauseTaggerAssets(modelDirectory: directory.root, manifest: directory.manifest)
    }

    @Test func missingMemberNamesTheFileAndTheFetchCommand() throws {
        let directory = try makeModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory.root.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: directory.root.appendingPathComponent("export.json"))

        let error = try #require(failure { try ClauseTaggerAssets(modelDirectory: directory.root, manifest: directory.manifest) })
        guard case let .missingFile(name, _) = error else {
            Issue.record("expected missingFile, got \(error)")
            return
        }
        #expect(name == "export.json")
        #expect(error.description.contains("python3 scripts/fetch_clause_tagger.py"))
    }

    @Test func wrongSizeMemberReportsExpectedAndActualSizes() throws {
        let directory = try makeModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory.root.deletingLastPathComponent()) }
        let url = directory.root.appendingPathComponent("tokenizer.json")
        try Data("longer tokenizer stand-in".utf8).write(to: url)

        let error = try #require(failure { try ClauseTaggerAssets(modelDirectory: directory.root, manifest: directory.manifest) })
        guard case let .sizeMismatch(name, expected, actual) = error else {
            Issue.record("expected sizeMismatch, got \(error)")
            return
        }
        #expect(name == "tokenizer.json")
        #expect(expected == directory.payloads["tokenizer.json"]?.count)
        #expect(actual == "longer tokenizer stand-in".utf8.count)
        #expect(error.description.contains("python3 scripts/fetch_clause_tagger.py"))
    }

    @Test func sameSizeDifferentContentReportsBothHashes() throws {
        let directory = try makeModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory.root.deletingLastPathComponent()) }
        let original = try #require(directory.payloads["ClauseTagger.onnx"])
        let tampered = Data(original.map { $0 ^ 0xFF })
        try tampered.write(to: directory.root.appendingPathComponent("ClauseTagger.onnx"))

        let error = try #require(failure { try ClauseTaggerAssets(modelDirectory: directory.root, manifest: directory.manifest) })
        guard case let .hashMismatch(name, expected, actual) = error else {
            Issue.record("expected hashMismatch, got \(error)")
            return
        }
        #expect(name == "ClauseTagger.onnx")
        #expect(expected == FileSHA256.hexDigest(of: original))
        #expect(actual == FileSHA256.hexDigest(of: tampered))
    }

    @Test func directoryInPlaceOfMemberIsRejected() throws {
        let directory = try makeModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory.root.deletingLastPathComponent()) }
        let url = directory.root.appendingPathComponent("LICENSE.txt")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

        let error = try #require(failure { try ClauseTaggerAssets(modelDirectory: directory.root, manifest: directory.manifest) })
        guard case .notRegularFile = error else {
            Issue.record("expected notRegularFile, got \(error)")
            return
        }
    }

    @Test func missingAndRelativeDirectoriesAreRejected() throws {
        let manifest = try ClauseTaggerManifest.bundled()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClauseTaggerAssetsTests-\(UUID().uuidString)", isDirectory: true)

        let missingError = try #require(failure { try ClauseTaggerAssets(modelDirectory: missing, manifest: manifest) })
        guard case .directoryMissing = missingError else {
            Issue.record("expected directoryMissing, got \(missingError)")
            return
        }

        let relative = try #require(URL(string: "relative/models"))
        let relativeError = try #require(failure { try ClauseTaggerAssets(modelDirectory: relative, manifest: manifest) })
        guard case .directoryNotAbsolute = relativeError else {
            Issue.record("expected directoryNotAbsolute, got \(relativeError)")
            return
        }
    }

    @Test func invalidManifestsAreRejected() throws {
        let valid = try ClauseTaggerManifest.bundled()
        func with(
            release: ClauseTaggerManifest.Release? = nil,
            model: ClauseTaggerManifest.Model? = nil,
            members: [ClauseTaggerManifest.Member]? = nil,
            schemaVersion: Int = 1
        ) -> ClauseTaggerManifest {
            .init(
                schemaVersion: schemaVersion, release: release ?? valid.release, model: model ?? valid.model,
                onnx: valid.onnx, members: members ?? valid.members
            )
        }
        func member(_ index: Int, name: String? = nil, byteCount: Int? = nil, sha256: String? = nil) -> [ClauseTaggerManifest.Member] {
            var copy = valid.members
            let old = copy[index]
            copy[index] = .init(
                role: old.role, name: name ?? old.name, byteCount: byteCount ?? old.byteCount, sha256: sha256 ?? old.sha256
            )
            return copy
        }
        let invalid: [(String, ClauseTaggerManifest)] = [
            ("schema version", with(schemaVersion: 2)),
            ("missing role", with(members: Array(valid.members.dropLast()))),
            ("duplicate role", with(members: valid.members + [valid.members[0]])),
            ("path in name", with(members: member(0, name: "../x"))),
            ("backslash in name", with(members: member(0, name: "a\\b"))),
            ("uppercase sha", with(members: member(0, sha256: valid.members[0].sha256.uppercased()))),
            ("zero size", with(members: member(0, byteCount: 0))),
            ("tokenizer hash differs from model", with(members: member(1, sha256: String(repeating: "a", count: 64)))),
            ("short revision", with(model: .init(
                id: valid.model.id, revision: "abc", tokenizerSHA256: valid.model.tokenizerSHA256,
                encodingRevision: "1", unitPolicy: valid.model.unitPolicy, trainingStatus: "trained"
            ))),
            ("zero release size", with(release: .init(
                repository: valid.release.repository, tag: valid.release.tag, asset: valid.release.asset,
                byteCount: 0, sha256: valid.release.sha256, directory: valid.release.directory
            )))
        ]
        for (name, manifest) in invalid {
            #expect(throws: ClauseTaggerAssetsError.self, "\(name) must be rejected") {
                try manifest.validate()
            }
        }
        #expect(throws: ClauseTaggerAssetsError.self) {
            try ClauseTaggerManifest.parse(Data("{}".utf8))
        }
    }

    private func failure(_ body: () throws -> Void) -> ClauseTaggerAssetsError? {
        do {
            try body()
            return nil
        } catch let error as ClauseTaggerAssetsError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    private struct ModelDirectory {
        let root: URL
        let manifest: ClauseTaggerManifest
        let payloads: [String: Data]
    }

    /// Small stand-in members whose pins replace the real ones in the test manifest.
    private func makeModelDirectory(folderName: String = "clause-tagger-onnx") throws -> ModelDirectory {
        let bundled = try ClauseTaggerManifest.bundled()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClauseTaggerAssetsTests-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var members: [ClauseTaggerManifest.Member] = []
        var payloads: [String: Data] = [:]
        for member in bundled.members {
            let payload = Data("stand-in \(member.name)".utf8)
            try payload.write(to: root.appendingPathComponent(member.name))
            payloads[member.name] = payload
            members.append(.init(
                role: member.role, name: member.name, byteCount: payload.count, sha256: FileSHA256.hexDigest(of: payload)
            ))
        }
        guard let tokenizerHash = members.first(where: { $0.role == .tokenizer })?.sha256 else {
            throw ClauseTaggerAssetsError.invalidManifest("bundled manifest has no tokenizer member")
        }
        let model = ClauseTaggerManifest.Model(
            id: bundled.model.id, revision: bundled.model.revision, tokenizerSHA256: tokenizerHash,
            encodingRevision: bundled.model.encodingRevision, unitPolicy: bundled.model.unitPolicy,
            trainingStatus: bundled.model.trainingStatus
        )
        return ModelDirectory(
            root: root,
            manifest: .init(
                schemaVersion: bundled.schemaVersion, release: bundled.release, model: model,
                onnx: bundled.onnx, members: members
            ),
            payloads: payloads
        )
    }
}
