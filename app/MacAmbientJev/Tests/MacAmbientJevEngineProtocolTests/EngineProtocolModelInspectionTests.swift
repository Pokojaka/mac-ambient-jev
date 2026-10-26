import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolModelInspectionTests {
    @Test func identityRejectsMalformedHashesAndWhitespaceNames() throws {
        let malformedHashes = [
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "A", count: 64),
            String(repeating: "a", count: 63) + "g"
        ]
        for field in ["revision", "tokenizer_sha256"] {
            for malformed in malformedHashes {
                var object = identityObject()
                object[field] = malformed
                #expect(decodingFails(EngineClauseTaggerIdentity.self, object: object))
            }
        }

        for whitespace in ["", " ", "\t\n", "\u{00A0}"] {
            var backend = identityObject()
            backend["backend"] = whitespace
            #expect(decodingFails(EngineClauseTaggerIdentity.self, object: backend))

            var modelID = identityObject()
            modelID["model_id"] = whitespace
            #expect(decodingFails(EngineClauseTaggerIdentity.self, object: modelID))
        }

        #expect(throws: (any Error).self) {
            try EngineClauseTaggerIdentity(
                backend: " \t", modelID: "model", revision: validHash, tokenizerSHA256: validHash
            )
        }
        #expect(throws: (any Error).self) {
            try EngineClauseTaggerIdentity(
                backend: "backend", modelID: "\u{00A0}", revision: validHash, tokenizerSHA256: validHash
            )
        }
    }

    @Test func invalidInspectionPreservesStrictEngineFailureValidation() throws {
        var failure = try jsonObject(JSONEncoder().encode(try sampleFailure()))
        var missingField = failure
        missingField.removeValue(forKey: "message")
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: ["kind": "invalid", "error": missingField]))

        var extraField = failure
        extraField["unexpected"] = NSNull()
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: ["kind": "invalid", "error": extraField]))

        failure["message"] = NSNull()
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: ["kind": "invalid", "error": failure]))
    }
}

private let validHash = String(repeating: "a", count: 64)

private func sampleFailure() throws -> EngineFailure {
    try EngineFailure(
        code: .modelFailure,
        message: "Clause tagger model validation failed",
        stage: .validatingModels,
        requestID: nil,
        sessionID: nil,
        severity: .error,
        recoveryAction: .prepareModels,
        details: [],
        cleanupErrors: []
    )
}

private func identityObject() -> [String: Any] {
    [
        "backend": "coreml",
        "model_id": "clause-tagger-v1",
        "revision": validHash,
        "tokenizer_sha256": String(repeating: "b", count: 64)
    ]
}

private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func decodingFails<Value: Decodable>(_ type: Value.Type, object: [String: Any]) -> Bool {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        _ = try JSONDecoder().decode(type, from: data)
        return false
    } catch {
        return true
    }
}
