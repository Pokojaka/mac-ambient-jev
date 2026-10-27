import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevPortableRuntime

struct ClauseTaggerAssetsTests {
    @Test func bundledManifestPinsTheSourceAndFiveMembers() throws {
        let manifest = try ClauseTaggerManifest.bundled()

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.source == .init(
            repository: "Pokojaka/modernbert-ja-30m-utterance-tagger",
            commit: "5c0213592cf8d59fc0b665183ab7536ddde05d1f"
        ))
        #expect(manifest.model == .init(
            id: "Pokojaka/modernbert-ja-30m-utterance-tagger",
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
                role: .model, name: "ClauseTagger.onnx", path: "onnx/ClauseTagger.onnx",
                byteCount: 146_889_562,
                sha256: "1131898abd272f8bfb6e30828384e875971486cf9ba4f42f464f40b2f1119782"
            ),
            .init(
                role: .tokenizer, name: "tokenizer.json", path: "onnx/tokenizer.json", byteCount: 6_724_873,
                sha256: "0a94ac9a0a02c067bdef25b72ae9f4ee33f48f552e55988d444f6d25eeb1d062"
            ),
            .init(
                role: .export, name: "export.json", path: "onnx/export.json", byteCount: 253_707,
                sha256: "c62d12cba67447ba64c45d9e5471c65f69f0efebe9c2901852ec3ce8587c3a4a"
            ),
            .init(
                role: .license, name: "LICENSE.txt", path: "onnx/LICENSE.txt", byteCount: 1_292,
                sha256: "2e97bfc46df586a08bb5942dc2af608d1aced6023735f65797d0ced0ba7fd77a"
            ),
            .init(
                role: .modelLicense, name: "LICENSE.md", path: "LICENSE.md", byteCount: 2_185,
                sha256: "08b0eeee7efa0c43bcdefa95e64f0cf0e8f869eed4d01f3c5bcc2d99f112fb77"
            )
        ])
    }

    @Test func pinnedIdentityCarriesTheModelRevisionAndTokenizerHash() throws {
        let identity = try ClauseTaggerAssets.pinnedIdentity()

        #expect(identity.modelID == "Pokojaka/modernbert-ja-30m-utterance-tagger")
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

    @Test func invalidManifestsAreRejected() throws {
        let valid = try ClauseTaggerManifest.bundled()
        func with(
            source: ClauseTaggerManifest.Source? = nil,
            model: ClauseTaggerManifest.Model? = nil,
            members: [ClauseTaggerManifest.Member]? = nil,
            schemaVersion: Int = 1
        ) -> ClauseTaggerManifest {
            .init(
                schemaVersion: schemaVersion, source: source ?? valid.source, model: model ?? valid.model,
                onnx: valid.onnx, members: members ?? valid.members
            )
        }
        func member(
            _ index: Int, name: String? = nil, path: String? = nil,
            byteCount: Int? = nil, sha256: String? = nil
        ) -> [ClauseTaggerManifest.Member] {
            var copy = valid.members
            let old = copy[index]
            copy[index] = .init(
                role: old.role, name: name ?? old.name, path: path ?? old.path,
                byteCount: byteCount ?? old.byteCount, sha256: sha256 ?? old.sha256
            )
            return copy
        }
        let invalid: [(String, ClauseTaggerManifest)] = [
            ("schema version", with(schemaVersion: 2)),
            ("missing role", with(members: Array(valid.members.dropLast()))),
            ("missing model license", with(members: valid.members.filter { $0.role != .modelLicense })),
            ("duplicate role", with(members: valid.members + [valid.members[0]])),
            ("duplicate member name", with(members: member(1, name: valid.members[0].name))),
            ("duplicate member path", with(members: member(1, path: valid.members[0].path))),
            ("path in name", with(members: member(0, name: "../x"))),
            ("non-ASCII name", with(members: member(0, name: "モデル.onnx"))),
            ("backslash in name", with(members: member(0, name: "a\\b"))),
            ("invalid member path", with(members: member(0, path: "onnx/../ClauseTagger.onnx"))),
            ("uppercase sha", with(members: member(0, sha256: valid.members[0].sha256.uppercased()))),
            ("zero size", with(members: member(0, byteCount: 0))),
            ("tokenizer hash differs from model", with(members: member(1, sha256: String(repeating: "a", count: 64)))),
            ("invalid source commit", with(source: .init(
                repository: valid.source.repository, commit: String(repeating: "g", count: 40)
            ))),
            ("invalid source repository", with(source: .init(repository: "unsafe/repo/extra", commit: valid.source.commit))),
            ("model id differs from source", with(model: .init(
                id: "another/repository", revision: valid.model.revision,
                tokenizerSHA256: valid.model.tokenizerSHA256, encodingRevision: "1",
                unitPolicy: valid.model.unitPolicy, trainingStatus: "trained"
            ))),
            ("short revision", with(model: .init(
                id: valid.model.id, revision: "abc", tokenizerSHA256: valid.model.tokenizerSHA256,
                encodingRevision: "1", unitPolicy: valid.model.unitPolicy, trainingStatus: "trained"
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

    private struct ModelDirectory {
        let root: URL
        let manifest: ClauseTaggerManifest
    }

    /// Small stand-in members whose pins replace the real ones in the test manifest.
    private func makeModelDirectory(folderName: String = "clause-tagger-onnx") throws -> ModelDirectory {
        let bundled = try ClauseTaggerManifest.bundled()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClauseTaggerAssetsTests-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var members: [ClauseTaggerManifest.Member] = []
        for member in bundled.members {
            let payload = Data("stand-in \(member.name)".utf8)
            try payload.write(to: root.appendingPathComponent(member.name))
            members.append(.init(
                role: member.role, name: member.name, path: member.path,
                byteCount: payload.count, sha256: FileSHA256.hexDigest(of: payload)
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
                schemaVersion: bundled.schemaVersion, source: bundled.source, model: model,
                onnx: bundled.onnx, members: members
            )
        )
    }
}
