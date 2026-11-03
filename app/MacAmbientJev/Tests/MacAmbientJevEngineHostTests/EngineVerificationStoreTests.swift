import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost

private struct Fixture {
    let base = FileManager.default.temporaryDirectory.appending(path: "EngineVerificationStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    var paths: AppPaths { AppPaths(applicationSupportURL: base, cacheURL: base, sessionsRootOverride: nil) }
    var store: EngineVerificationStore { EngineVerificationStore(paths: paths) }
    let key: EngineVerificationKey
    init() throws {
        let fields: [String: Any] = [
            "providerName": "provider", "packageFullName": "package", "libraryHash": "library", "packageArchitecture": "x64",
            "deviceKey": "gpu:0000:0000", "description": "GPU", "driverVersion": "driver", "ortVersion": "1.31.0",
            "adapterIdentity": "adapter", "dependencyHashes": [String](),
            "modelRevision": "revision", "modelSize": "small", "decodingSettings": "settings", "fixtureHash": "fixture",
            "verificationPolicyVersion": "policy", "threads": 2]
        key = try JSONDecoder().decode(EngineVerificationKey.self, from: JSONSerialization.data(withJSONObject: fields))
    }
    func cleanUp() { try? FileManager.default.removeItem(at: base) }
    func receipt(_ key: EngineVerificationKey, _ output: String, _ passed: Bool) -> EngineVerificationReceipt {
        .init(key: key, observedOutput: output, passed: passed, rtf: 0.5,
              timestamp: Date(timeIntervalSince1970: 1_700_000_000))
    }
}

@Suite(.timeLimit(.minutes(10)))
struct EngineVerificationStoreTests {
    @Test func lookupIdentityAndCorruptReceipts() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        #expect(try f.store.load(for: f.key) == nil)
        let id = try f.store.publish(f.receipt(f.key, "ok", true))
        let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.key)) as? [String: Any])
        for field in fields.keys {
            var changed = fields
            if field == "threads" { changed[field] = 3 } else if field == "dependencyHashes" { changed[field] = ["other"] } else { changed[field] = "other" }
            let key = try JSONDecoder().decode(EngineVerificationKey.self,
                from: JSONSerialization.data(withJSONObject: changed))
            #expect(try f.store.load(for: key) == nil)
        }
        for field in ["adapterIdentity", "dependencyHashes"] {
            var missing = fields; missing.removeValue(forKey: field)
            #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(EngineVerificationKey.self, from: JSONSerialization.data(withJSONObject: missing)) }
        }
        let url = f.paths.root.appending(path: "accelerators/\(id).json")
        try Data([0xFF, 0x00]).write(to: url)
        expectCorrupt { try f.store.load(for: f.key) }
        var mismatch = fields; mismatch["description"] = "other"
        let key = try JSONDecoder().decode(EngineVerificationKey.self, from: JSONSerialization.data(withJSONObject: mismatch))
        try JSONEncoder().encode(f.receipt(key, "ok", true)).write(to: url)
        expectCorrupt { try f.store.load(for: f.key) }
    }

    @Test func passingAndFailingReceiptsRoundTripExactOutput() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(f.key)) as? [String: Any])
        fields["description"] = "other"
        let failingKey = try JSONDecoder().decode(EngineVerificationKey.self, from: JSONSerialization.data(withJSONObject: fields))
        let pass = f.receipt(f.key, "こんにちは\n🙂", true), fail = f.receipt(failingKey, "mismatch: \"音声\"", false)
        let passID = try f.store.publish(pass), failID = try f.store.publish(fail)
        #expect(passID != failID)
        let loadedPass = try #require(try f.store.load(for: pass.key)), loadedFail = try #require(try f.store.load(for: fail.key))
        #expect(loadedPass == pass && Data(loadedPass.observedOutput.utf8) == Data(pass.observedOutput.utf8))
        #expect(loadedFail == fail && Data(loadedFail.observedOutput.utf8) == Data(fail.observedOutput.utf8))
        #expect(try f.store.publish(f.receipt(pass.key, "replacement", false)) == passID)
    }

    @Test func refusedPublishLeavesNoTemporaryFileOrChangesToDestination() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        let receipt = f.receipt(f.key, "ok", true), id = try f.store.publish(receipt)
        let url = f.paths.root.appending(path: "accelerators/\(id).json"), directory = url.deletingLastPathComponent()
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let sentinel = url.appending(path: "sentinel"), bytes = Data("unchanged".utf8)
        try bytes.write(to: sentinel)
        #expect(throws: (any Error).self) { try f.store.publish(receipt) }
        #expect(try SessionFileAccess.contentsOfDirectory(directory, relativeTo: f.paths.root)
            .map(\.lastPathComponent).sorted() == [url.lastPathComponent])
        #expect(try Data(contentsOf: sentinel) == bytes)
    }
}

private func expectCorrupt(_ operation: () throws -> EngineVerificationReceipt?) {
    do { _ = try operation(); Issue.record("expected corrupt") }
    catch let error as EngineVerificationStoreError {
        if case .corrupt = error { return }; Issue.record("expected corrupt, got \(error)")
    } catch { Issue.record("expected corrupt, got \(error)") }
}
