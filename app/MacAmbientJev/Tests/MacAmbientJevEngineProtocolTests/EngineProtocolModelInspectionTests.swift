import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolModelInspectionTests {
    @Test func identityAndInspectionVariantsRoundTripWithExactWireKeys() throws {
        let identity = try sampleIdentity()
        let validated = EngineClauseTaggerInspection.validated(identity)
        let failure = try sampleFailure()
        let invalid = EngineClauseTaggerInspection.invalid(failure)

        #expect(try roundTrip(identity) == identity)
        #expect(try roundTrip(validated) == validated)
        #expect(try roundTrip(invalid) == invalid)
        #expect(try roundTrip(EngineModelsInspection(clauseTagger: validated)) == EngineModelsInspection(clauseTagger: validated))
        #expect(try roundTrip(EngineModelsInspection(clauseTagger: invalid)) == EngineModelsInspection(clauseTagger: invalid))

        let identityObject = try jsonObject(JSONEncoder().encode(identity))
        #expect(Set(identityObject.keys) == Set(["backend", "model_id", "revision", "tokenizer_sha256"]))
        #expect(identityObject["backend"] as? String == identity.backend)
        #expect(identityObject["model_id"] as? String == identity.modelID)
        #expect(identityObject["revision"] as? String == identity.revision)
        #expect(identityObject["tokenizer_sha256"] as? String == identity.tokenizerSHA256)

        let validatedObject = try jsonObject(JSONEncoder().encode(validated))
        #expect(Set(validatedObject.keys) == Set(["kind", "identity"]))
        #expect(validatedObject["kind"] as? String == "validated")
        let invalidObject = try jsonObject(JSONEncoder().encode(invalid))
        #expect(Set(invalidObject.keys) == Set(["kind", "error"]))
        #expect(invalidObject["kind"] as? String == "invalid")
        let modelsObject = try jsonObject(JSONEncoder().encode(EngineModelsInspection(clauseTagger: validated)))
        #expect(Set(modelsObject.keys) == Set(["clause_tagger"]))
    }

    @Test func identityRequiresEveryStringFieldAndRejectsUnknownKeys() throws {
        let valid = identityObject()
        let fields = ["backend", "model_id", "revision", "tokenizer_sha256"]

        for field in fields {
            var missing = valid
            missing.removeValue(forKey: field)
            #expect(decodingFails(EngineClauseTaggerIdentity.self, object: missing))

            var nullValue = valid
            nullValue[field] = NSNull()
            #expect(decodingFails(EngineClauseTaggerIdentity.self, object: nullValue))

            var wrongType = valid
            wrongType[field] = 7
            #expect(decodingFails(EngineClauseTaggerIdentity.self, object: wrongType))
        }

        var extra = valid
        extra["unexpected"] = NSNull()
        #expect(decodingFails(EngineClauseTaggerIdentity.self, object: extra))
        var camelCaseAlias = valid
        camelCaseAlias["modelID"] = valid["model_id"]
        #expect(decodingFails(EngineClauseTaggerIdentity.self, object: camelCaseAlias))
    }

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

    @Test func inspectionObjectsRequireTheirTaggedArmAndRejectUnknownKinds() throws {
        let identity = identityObject()
        let failure = try jsonObject(JSONEncoder().encode(try sampleFailure()))
        let validated: [String: Any] = ["kind": "validated", "identity": identity]
        let invalid: [String: Any] = ["kind": "invalid", "error": failure]

        #expect(decodingFails(EngineClauseTaggerInspection.self, object: ["identity": identity]))
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: ["kind": "validated"]))
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: ["kind": "invalid"]))
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: ["kind": NSNull(), "identity": identity]))
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: ["kind": 1, "identity": identity]))
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: ["kind": "other", "identity": identity]))
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: ["kind": "validated", "identity": NSNull()]))
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: ["kind": "validated", "identity": "not-an-object"]))
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: ["kind": "invalid", "error": NSNull()]))
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: ["kind": "invalid", "error": "not-an-object"]))

        var validatedWithAlternateArm = validated
        validatedWithAlternateArm["error"] = NSNull()
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: validatedWithAlternateArm))
        var invalidWithAlternateArm = invalid
        invalidWithAlternateArm["identity"] = NSNull()
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: invalidWithAlternateArm))
        var unknownField = validated
        unknownField["unexpected"] = 1
        #expect(decodingFails(EngineClauseTaggerInspection.self, object: unknownField))
    }

    @Test func modelsInspectionRequiresClauseTaggerAndRejectsUnknownKeys() throws {
        let valid = ["clause_tagger": ["kind": "validated", "identity": identityObject()]] as [String: Any]
        #expect(decodingFails(EngineModelsInspection.self, object: [:]))
        #expect(decodingFails(EngineModelsInspection.self, object: ["clause_tagger": NSNull()]))
        #expect(decodingFails(EngineModelsInspection.self, object: ["clause_tagger": "not-an-object"]))
        var extra = valid
        extra["unexpected"] = NSNull()
        #expect(decodingFails(EngineModelsInspection.self, object: extra))
        var alias = valid
        alias["clauseTagger"] = valid["clause_tagger"]
        #expect(decodingFails(EngineModelsInspection.self, object: alias))
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

private func sampleIdentity() throws -> EngineClauseTaggerIdentity {
    try EngineClauseTaggerIdentity(
        backend: "coreml", modelID: "clause-tagger-v1", revision: validHash,
        tokenizerSHA256: String(repeating: "b", count: 64)
    )
}

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

private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
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
