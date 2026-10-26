import Foundation
import Testing
import MacAmbientJevEngineProtocol

struct EngineProtocolDiagnosticsTests {
    @Test func diagnosticsValuesRoundTripWithExactWireKeys() throws {
        let boundary = try sampleRequest(sendCount: 4, inputTokens: 17, successCount: 2, failureCount: 1)
        let priority = try sampleRequest(sendCount: 3, inputTokens: 23, successCount: 1, failureCount: 1)
        let snapshot = try sampleSnapshot(boundaryRequests: boundary, priorityRequests: priority)
        let available = EngineDecisionUsage.available(snapshot)
        let unavailable = EngineDecisionUsage.unavailable(try sampleFailure())
        let availableResult = sampleResult(decisionUsage: available)
        let unavailableResult = sampleResult(decisionUsage: unavailable)

        #expect(try roundTrip(boundary) == boundary)
        #expect(try roundTrip(snapshot) == snapshot)
        #expect(try roundTrip(available) == available)
        #expect(try roundTrip(unavailable) == unavailable)
        #expect(try roundTrip(EngineDiagnosticsScope.engineProcess) == .engineProcess)
        #expect(try roundTrip(EngineUnavailableCapability.none) == .none)
        #expect(try roundTrip(availableResult) == availableResult)
        #expect(try roundTrip(unavailableResult) == unavailableResult)

        let requestObject = try jsonObject(boundary)
        #expect(Set(requestObject.keys) == Set(["send_count", "input_tokens", "success_count", "failure_count"]))

        let snapshotObject = try jsonObject(snapshot)
        #expect(Set(snapshotObject.keys) == Set([
            "send_count", "input_tokens", "success_count", "failure_count",
            "pending_boundary_segment_count", "pending_priority_clause_count", "boundary_requests", "priority_requests"
        ]))
        #expect(Set(try nestedObject(snapshotObject, "boundary_requests").keys) == Set([
            "send_count", "input_tokens", "success_count", "failure_count"
        ]))

        let availableObject = try jsonObject(available)
        #expect(Set(availableObject.keys) == Set(["kind", "snapshot"]))
        #expect(availableObject["kind"] as? String == "available")
        let unavailableObject = try jsonObject(unavailable)
        #expect(Set(unavailableObject.keys) == Set(["kind", "error"]))
        #expect(unavailableObject["kind"] as? String == "unavailable")

        let scopeObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(EngineDiagnosticsScope.engineProcess), options: [.fragmentsAllowed]
        )
        #expect(scopeObject as? String == "engine_process")
        #expect(EngineDiagnosticsScope.allCases.map(\.rawValue) == ["engine_process"])

        let resultObject = try jsonObject(availableResult)
        #expect(Set(resultObject.keys) == Set(["scope", "decision_usage", "automatic_input_volume", "thermal_monitoring"]))
        #expect(resultObject["scope"] as? String == "engine_process")
        #expect(resultObject["automatic_input_volume"] as? String == "none")
        #expect(resultObject["thermal_monitoring"] as? String == "none")
    }

    @Test func requestUsageRequiresExactTypedNonnegativeFields() throws {
        let valid = try jsonObject(sampleRequest(sendCount: 5, inputTokens: 8, successCount: 2, failureCount: 1))
        let fields = ["send_count", "input_tokens", "success_count", "failure_count"]
        for field in fields {
            var missing = valid
            missing.removeValue(forKey: field)
            #expect(decodingFails(EngineDecisionRequestUsage.self, object: missing))

            var nullValue = valid
            nullValue[field] = NSNull()
            #expect(decodingFails(EngineDecisionRequestUsage.self, object: nullValue))

            var wrongType = valid
            wrongType[field] = "not-an-integer"
            #expect(decodingFails(EngineDecisionRequestUsage.self, object: wrongType))

            var negative = valid
            negative[field] = -1
            #expect(decodingFails(EngineDecisionRequestUsage.self, object: negative))
        }

        var unknown = valid
        unknown["unexpected"] = NSNull()
        #expect(decodingFails(EngineDecisionRequestUsage.self, object: unknown))
        var alias = valid
        alias["sendCount"] = alias.removeValue(forKey: "send_count")
        #expect(decodingFails(EngineDecisionRequestUsage.self, object: alias))

        #expect(throws: (any Error).self) {
            try EngineDecisionRequestUsage(sendCount: 2, inputTokens: 0, successCount: 2, failureCount: 1)
        }
        #expect(throws: (any Error).self) {
            try EngineDecisionRequestUsage(sendCount: 0, inputTokens: 0, successCount: 1, failureCount: 0)
        }
    }

    @Test func usageSnapshotRequiresExactFieldsAndMatchingTotals() throws {
        let snapshot = try sampleSnapshot(
            boundaryRequests: sampleRequest(sendCount: 4, inputTokens: 17, successCount: 2, failureCount: 1),
            priorityRequests: sampleRequest(sendCount: 3, inputTokens: 23, successCount: 1, failureCount: 1)
        )
        let valid = try jsonObject(snapshot)
        let fields = [
            "send_count", "input_tokens", "success_count", "failure_count",
            "pending_boundary_segment_count", "pending_priority_clause_count", "boundary_requests", "priority_requests"
        ]
        for field in fields {
            var missing = valid
            missing.removeValue(forKey: field)
            #expect(decodingFails(EngineDecisionUsageSnapshot.self, object: missing))

            var nullValue = valid
            nullValue[field] = NSNull()
            #expect(decodingFails(EngineDecisionUsageSnapshot.self, object: nullValue))

            var wrongType = valid
            wrongType[field] = "wrong-type"
            #expect(decodingFails(EngineDecisionUsageSnapshot.self, object: wrongType))
        }
        for field in ["send_count", "input_tokens", "success_count", "failure_count", "pending_boundary_segment_count", "pending_priority_clause_count"] {
            var negative = valid
            negative[field] = -1
            #expect(decodingFails(EngineDecisionUsageSnapshot.self, object: negative))
        }

        var unknown = valid
        unknown["unexpected"] = 1
        #expect(decodingFails(EngineDecisionUsageSnapshot.self, object: unknown))
        for field in ["send_count", "input_tokens", "success_count", "failure_count"] {
            var mismatch = valid
            mismatch[field] = (mismatch[field] as! Int) + 1
            #expect(decodingFails(EngineDecisionUsageSnapshot.self, object: mismatch))
        }

        for nestedField in ["boundary_requests", "priority_requests"] {
            for requestField in ["send_count", "input_tokens", "success_count", "failure_count"] {
                var missingNested = valid
                var nested = try nestedObject(missingNested, nestedField)
                nested.removeValue(forKey: requestField)
                missingNested[nestedField] = nested
                #expect(decodingFails(EngineDecisionUsageSnapshot.self, object: missingNested))

                var nullNested = valid
                nested = try nestedObject(nullNested, nestedField)
                nested[requestField] = NSNull()
                nullNested[nestedField] = nested
                #expect(decodingFails(EngineDecisionUsageSnapshot.self, object: nullNested))

                var wrongTypeNested = valid
                nested = try nestedObject(wrongTypeNested, nestedField)
                nested[requestField] = "wrong-type"
                wrongTypeNested[nestedField] = nested
                #expect(decodingFails(EngineDecisionUsageSnapshot.self, object: wrongTypeNested))

                var negativeNested = valid
                nested = try nestedObject(negativeNested, nestedField)
                nested[requestField] = -1
                negativeNested[nestedField] = nested
                #expect(decodingFails(EngineDecisionUsageSnapshot.self, object: negativeNested))
            }

            var unknownNested = valid
            var nested = try nestedObject(unknownNested, nestedField)
            nested["unexpected"] = 0
            unknownNested[nestedField] = nested
            #expect(decodingFails(EngineDecisionUsageSnapshot.self, object: unknownNested))
        }
    }

    @Test func decisionUsageDiscriminatorRequiresExactlyItsOwnArm() throws {
        let snapshot = try sampleSnapshot(
            boundaryRequests: sampleRequest(sendCount: 4, inputTokens: 17, successCount: 2, failureCount: 1),
            priorityRequests: sampleRequest(sendCount: 3, inputTokens: 23, successCount: 1, failureCount: 1)
        )
        let snapshotObject = try jsonObject(snapshot)
        let failureObject = try jsonObject(sampleFailure())
        let available: [String: Any] = ["kind": "available", "snapshot": snapshotObject]
        let unavailable: [String: Any] = ["kind": "unavailable", "error": failureObject]

        #expect(decodingFails(EngineDecisionUsage.self, object: [:]))
        #expect(decodingFails(EngineDecisionUsage.self, object: ["snapshot": snapshotObject]))
        for invalidKind: Any in [NSNull(), 1, "other"] {
            #expect(decodingFails(EngineDecisionUsage.self, object: ["kind": invalidKind, "snapshot": snapshotObject]))
        }
        #expect(decodingFails(EngineDecisionUsage.self, object: ["kind": "available"]))
        #expect(decodingFails(EngineDecisionUsage.self, object: ["kind": "available", "snapshot": NSNull()]))
        #expect(decodingFails(EngineDecisionUsage.self, object: ["kind": "available", "snapshot": "not-an-object"]))
        var availableWithError = available
        availableWithError["error"] = NSNull()
        #expect(decodingFails(EngineDecisionUsage.self, object: availableWithError))
        var availableUnknown = available
        availableUnknown["extra"] = 0
        #expect(decodingFails(EngineDecisionUsage.self, object: availableUnknown))

        #expect(decodingFails(EngineDecisionUsage.self, object: ["kind": "unavailable"]))
        #expect(decodingFails(EngineDecisionUsage.self, object: ["kind": "unavailable", "error": NSNull()]))
        #expect(decodingFails(EngineDecisionUsage.self, object: ["kind": "unavailable", "error": "not-an-object"]))
        var unavailableWithSnapshot = unavailable
        unavailableWithSnapshot["snapshot"] = NSNull()
        #expect(decodingFails(EngineDecisionUsage.self, object: unavailableWithSnapshot))
        var unavailableUnknown = unavailable
        unavailableUnknown["extra"] = 0
        #expect(decodingFails(EngineDecisionUsage.self, object: unavailableUnknown))
    }

    @Test func diagnosticsResultAndRawEnumsRejectUnknownValuesAndMalformedFields() throws {
        let result = sampleResult(decisionUsage: .available(try sampleSnapshot(
            boundaryRequests: sampleRequest(sendCount: 4, inputTokens: 17, successCount: 2, failureCount: 1),
            priorityRequests: sampleRequest(sendCount: 3, inputTokens: 23, successCount: 1, failureCount: 1)
        )))
        let valid = try jsonObject(result)
        let fields = ["scope", "decision_usage", "automatic_input_volume", "thermal_monitoring"]
        for field in fields {
            var missing = valid
            missing.removeValue(forKey: field)
            #expect(decodingFails(EngineDiagnosticsResult.self, object: missing))

            var nullValue = valid
            nullValue[field] = NSNull()
            #expect(decodingFails(EngineDiagnosticsResult.self, object: nullValue))

            var wrongType = valid
            wrongType[field] = 4
            #expect(decodingFails(EngineDiagnosticsResult.self, object: wrongType))
        }
        var unknown = valid
        unknown["unexpected"] = false
        #expect(decodingFails(EngineDiagnosticsResult.self, object: unknown))

        var unknownScope = valid
        unknownScope["scope"] = "another_process"
        #expect(decodingFails(EngineDiagnosticsResult.self, object: unknownScope))
        var unknownUsageKind = valid
        unknownUsageKind["decision_usage"] = ["kind": "future", "snapshot": [:]]
        #expect(decodingFails(EngineDiagnosticsResult.self, object: unknownUsageKind))
        for field in ["automatic_input_volume", "thermal_monitoring"] {
            var unknownCapability = valid
            unknownCapability[field] = "supported"
            #expect(decodingFails(EngineDiagnosticsResult.self, object: unknownCapability))
        }

        #expect(decodingFails(EngineDiagnosticsScope.self, from: "\"unknown\""))
        #expect(decodingFails(EngineDiagnosticsScope.self, from: "null"))
        #expect(decodingFails(EngineUnavailableCapability.self, from: "\"supported\""))
        #expect(decodingFails(EngineUnavailableCapability.self, from: "null"))
        #expect(EngineUnavailableCapability.allCases.map(\.rawValue) == ["none"])
    }

    @Test func countsUseOverflowSafeSumsAndAllowInFlightRequests() throws {
        let inFlight = try EngineDecisionRequestUsage(sendCount: 5, inputTokens: 9, successCount: 1, failureCount: 1)
        #expect(inFlight.sendCount - inFlight.successCount - inFlight.failureCount == 3)
        #expect(try roundTrip(inFlight) == inFlight)

        let maximumRequest = try EngineDecisionRequestUsage(
            sendCount: Int.max, inputTokens: Int.max, successCount: Int.max, failureCount: 0
        )
        #expect(try roundTrip(maximumRequest) == maximumRequest)
        #expect(throws: (any Error).self) {
            try EngineDecisionRequestUsage(sendCount: Int.max, inputTokens: 0, successCount: Int.max, failureCount: 1)
        }
        #expect(throws: (any Error).self) {
            try EngineDecisionRequestUsage(sendCount: 0, inputTokens: -1, successCount: 0, failureCount: 0)
        }
        for field in ["send_count", "input_tokens", "success_count", "failure_count"] {
            var negative = try jsonObject(inFlight)
            negative[field] = -1
            #expect(decodingFails(EngineDecisionRequestUsage.self, object: negative))
        }

        let zeroRequest = try sampleRequest(sendCount: 0, inputTokens: 0, successCount: 0, failureCount: 0)
        let maximumSnapshot = try EngineDecisionUsageSnapshot(
            sendCount: Int.max,
            inputTokens: Int.max,
            successCount: Int.max,
            failureCount: 0,
            pendingBoundarySegmentCount: Int.max,
            pendingPriorityClauseCount: Int.max,
            boundaryRequests: maximumRequest,
            priorityRequests: zeroRequest
        )
        #expect(try roundTrip(maximumSnapshot) == maximumSnapshot)

        let maxTokenRequests = [
            try sampleRequest(sendCount: 1, inputTokens: Int.max, successCount: 0, failureCount: 0),
            try sampleRequest(sendCount: 1, inputTokens: 1, successCount: 0, failureCount: 0)
        ]
        #expect(throws: (any Error).self) {
            try EngineDecisionUsageSnapshot(
                sendCount: 2, inputTokens: Int.max, successCount: 0, failureCount: 0,
                pendingBoundarySegmentCount: 0, pendingPriorityClauseCount: 0,
                boundaryRequests: maxTokenRequests[0], priorityRequests: maxTokenRequests[1]
            )
        }
        #expect(throws: (any Error).self) {
            try EngineDecisionUsageSnapshot(
                sendCount: Int.max, inputTokens: Int.max, successCount: Int.max, failureCount: 0,
                pendingBoundarySegmentCount: -1, pendingPriorityClauseCount: 0,
                boundaryRequests: maximumRequest, priorityRequests: zeroRequest
            )
        }

        var overflowSnapshot = try jsonObject(maximumSnapshot)
        var boundary = try nestedObject(overflowSnapshot, "boundary_requests")
        var priority = try nestedObject(overflowSnapshot, "priority_requests")
        boundary["send_count"] = Int.max
        priority["send_count"] = 1
        overflowSnapshot["send_count"] = Int.max
        overflowSnapshot["boundary_requests"] = boundary
        overflowSnapshot["priority_requests"] = priority
        #expect(decodingFails(EngineDecisionUsageSnapshot.self, object: overflowSnapshot))

        var overflowTokens = try jsonObject(maximumSnapshot)
        boundary = try nestedObject(overflowTokens, "boundary_requests")
        priority = try nestedObject(overflowTokens, "priority_requests")
        boundary["input_tokens"] = Int.max
        priority["input_tokens"] = 1
        overflowTokens["boundary_requests"] = boundary
        overflowTokens["priority_requests"] = priority
        #expect(decodingFails(EngineDecisionUsageSnapshot.self, object: overflowTokens))

        #expect(throws: (any Error).self) {
            try EngineDecisionUsageSnapshot(
                sendCount: 7, inputTokens: 40, successCount: 4, failureCount: 2,
                pendingBoundarySegmentCount: 2, pendingPriorityClauseCount: 3,
                boundaryRequests: try sampleRequest(sendCount: 4, inputTokens: 17, successCount: 2, failureCount: 1),
                priorityRequests: try sampleRequest(sendCount: 3, inputTokens: 23, successCount: 1, failureCount: 1)
            )
        }
    }
}

private func sampleRequest(sendCount: Int, inputTokens: Int, successCount: Int, failureCount: Int) throws -> EngineDecisionRequestUsage {
    try EngineDecisionRequestUsage(
        sendCount: sendCount, inputTokens: inputTokens, successCount: successCount, failureCount: failureCount
    )
}

private func sampleSnapshot(
    boundaryRequests: EngineDecisionRequestUsage,
    priorityRequests: EngineDecisionRequestUsage
) throws -> EngineDecisionUsageSnapshot {
    try EngineDecisionUsageSnapshot(
        sendCount: boundaryRequests.sendCount + priorityRequests.sendCount,
        inputTokens: boundaryRequests.inputTokens + priorityRequests.inputTokens,
        successCount: boundaryRequests.successCount + priorityRequests.successCount,
        failureCount: boundaryRequests.failureCount + priorityRequests.failureCount,
        pendingBoundarySegmentCount: 2,
        pendingPriorityClauseCount: 3,
        boundaryRequests: boundaryRequests,
        priorityRequests: priorityRequests
    )
}

private func sampleFailure() throws -> EngineFailure {
    try EngineFailure(
        code: .internalError,
        message: "Decision usage is unavailable",
        stage: .decisions,
        requestID: nil,
        sessionID: nil,
        severity: .warning,
        recoveryAction: .none,
        details: [],
        cleanupErrors: []
    )
}

private func sampleResult(decisionUsage: EngineDecisionUsage) -> EngineDiagnosticsResult {
    EngineDiagnosticsResult(
        scope: .engineProcess,
        decisionUsage: decisionUsage,
        automaticInputVolume: .none,
        thermalMonitoring: .none
    )
}

private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
}

private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] else {
        throw DiagnosticsTestError.expectedObject
    }
    return object
}

private func nestedObject(_ object: [String: Any], _ key: String) throws -> [String: Any] {
    guard let nested = object[key] as? [String: Any] else {
        throw DiagnosticsTestError.expectedObject
    }
    return nested
}

private func decodingFails<Value: Decodable>(_ type: Value.Type, object: [String: Any]) -> Bool {
    do {
        let data = try JSONSerialization.data(withJSONObject: object)
        _ = try JSONDecoder().decode(type, from: data)
        return false
    } catch {
        return true
    }
}

private func decodingFails<Value: Decodable>(_ type: Value.Type, from json: String) -> Bool {
    do {
        _ = try JSONDecoder().decode(type, from: Data(json.utf8))
        return false
    } catch {
        return true
    }
}

private enum DiagnosticsTestError: Error {
    case expectedObject
}
