import MacAmbientJevCore

let testDecisionIdentity = try! DecisionModelIdentity(backend: "test-backend", model: "test-tagger", modelRevision: String(repeating: "0", count: 64))
