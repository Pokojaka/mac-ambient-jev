import Foundation
import MacAmbientJevCore
import MacAmbientJevEngineProtocol
import MacAmbientJevPipeline

struct EngineResourceSnapshot: Equatable {
    let settingsRevision: EngineID
    let workload: EngineResourceWorkload
    let result: EngineResourceReadiness
    let reason: EngineResourceReason
}

struct EngineResourceAssessmentEntry: Equatable {
    let snapshot: EngineResourceSnapshot, assessment: EngineResourceAssessment
    var acknowledged: Bool
}

extension EngineApplicationCore {
    func preflight(_ payload: EngineResourcesPreflightPayload, context: EngineRequestContext) async throws -> EngineResourceAssessment {
        let result = try currentResourceAssessment(payload.workload)
        let acknowledged = result.assessment.result == .warning
            && resourceAssessments.first(where: { $0.snapshot == result.snapshot })?.acknowledged == true
        storeResourceAssessment(result.snapshot, result.assessment, acknowledged: acknowledged)
        return result.assessment
    }

    func acknowledge(_ payload: EngineResourcesAcknowledgePayload, context: EngineRequestContext) async throws -> EngineResourcesAcknowledgePayload {
        guard !isShuttingDown else {
            throw EngineFailures.commandError(.cancelled, "終了処理中のためリソース確認を完了できません", stage: .shutdown)
        }
        guard let index = resourceAssessments.firstIndex(where: { $0.assessment.assessmentID == payload.assessmentID }) else {
            throw EngineFailures.commandError(
                .staleRevision, "assessment_id が見つかりません。resources.preflight を再実行してください", stage: .protocolValidation
            )
        }
        let entry = resourceAssessments[index]
        guard entry.snapshot.workload != .finalization else {
            throw EngineFailures.commandError(.invalidRequest, "確定処理には確認応答を使用しません", stage: .finalization)
        }
        guard settingsResult?.revision == entry.snapshot.settingsRevision else {
            resourceAssessments.remove(at: index)
            throw EngineFailures.commandError(
                .staleRevision, "設定が変更されています。resources.preflight を再実行してください",
                stage: stage(for: entry.snapshot.workload)
            )
        }
        guard entry.assessment.result != .blocked else {
            throw EngineFailures.commandError(.modelFailure, entry.assessment.explanation, stage: stage(for: entry.snapshot.workload))
        }
        resourceAssessments[index].acknowledged = true
        return payload
    }

    func admitResources(_ workload: EngineResourceWorkload) throws {
        let (snapshot, freshAssessment) = try currentResourceAssessment(workload)
        switch freshAssessment.result {
        case .blocked:
            storeResourceAssessment(snapshot, freshAssessment, acknowledged: false)
            throw EngineFailures.commandError(.modelFailure, freshAssessment.explanation, stage: stage(for: workload))
        case .ready:
            invalidateResourceAssessment(for: workload)
        case .warning:
            if resourceAssessments.contains(where: { $0.snapshot == snapshot && $0.acknowledged }) {
                return
            }
            storeResourceAssessment(snapshot, freshAssessment, acknowledged: false)
            throw EngineFailures.commandError(
                .invalidRequest,
                "\(freshAssessment.explanation) resources.preflight と resources.acknowledge で明示的に確認してください。assessment_id: \(freshAssessment.assessmentID)",
                stage: stage(for: workload)
            )
        }
    }

    private func currentResourceAssessment(_ workload: EngineResourceWorkload) throws -> (snapshot: EngineResourceSnapshot, assessment: EngineResourceAssessment) {
        do { return try freshResourceAssessment(workload) }
        catch { invalidateResourceAssessment(for: workload); throw error }
    }

    private func freshResourceAssessment(_ workload: EngineResourceWorkload) throws -> (snapshot: EngineResourceSnapshot, assessment: EngineResourceAssessment) {
        let stage = stage(for: workload)
        guard !isShuttingDown else {
            throw EngineFailures.commandError(.cancelled, "終了処理中のためリソースを確認できません", stage: stage)
        }
        let settings = try requireSettings(stage: stage)
        guard let savedSettings = settingsResult else { preconditionFailure("requireSettings returns only when settingsResult exists") }
        let admission: InferenceAdmission
        let facts: InferenceMemoryFacts
        do {
            facts = try memoryProber.memoryFacts()
            admission = try admitInference(
                physicalMemoryBytes: facts.physicalMemoryBytes, freePhysicalMemoryBytes: facts.freePhysicalMemoryBytes,
                commitHeadroomBytes: facts.commitHeadroomBytes, envelope: .unmeasured, measuredRTF: .unmeasured,
                threads: settings.threads, logicalCPUCount: logicalCPUCount,
                workload: coreWorkload(for: workload), lowMemorySignal: facts.lowMemorySignal
            )
        } catch {
            throw EngineFailures.commandError(
                .modelFailure, "推論リソースを確認できません: \(error.localizedDescription)",
                stage: stage, recoveryAction: .retry
            )
        }
        let assessment = try resourceAssessment(for: admission)
        let snapshot = EngineResourceSnapshot(
            settingsRevision: savedSettings.revision, workload: workload,
            result: assessment.result, reason: assessment.reason
        )
        return (snapshot, assessment)
    }

    private func invalidateResourceAssessment(for workload: EngineResourceWorkload) {
        resourceAssessments.removeAll { $0.snapshot.workload == workload }
    }

    private func storeResourceAssessment(
        _ snapshot: EngineResourceSnapshot, _ assessment: EngineResourceAssessment, acknowledged: Bool
    ) {
        invalidateResourceAssessment(for: snapshot.workload)
        resourceAssessments.append(.init(snapshot: snapshot, assessment: assessment, acknowledged: acknowledged))
    }

    private func stage(for workload: EngineResourceWorkload) -> EngineStage { workloadInfo(workload).stage }
    private func coreWorkload(for workload: EngineResourceWorkload) -> InferenceWorkload { workloadInfo(workload).core }

    private func workloadInfo(_ workload: EngineResourceWorkload) -> (stage: EngineStage, core: InferenceWorkload) {
        switch workload {
        case .load: (.loadingModels, .load)
        case .live: (.capture, .live)
        case .finalization: (.finalization, .finalization)
        }
    }

    private func resourceAssessment(for admission: InferenceAdmission) throws -> EngineResourceAssessment {
        let (result, reason): (EngineResourceReadiness, EngineResourceReason) = switch admission {
        case .admit: (.ready, .ready)
        case .warn(let reason): (.warning, resourceReason(for: reason))
        case .block(let reason): (.blocked, resourceReason(for: reason))
        }
        return try EngineResourceAssessment(
            assessmentID: UUID().uuidString.lowercased(), result: result, reason: reason, explanation: admission.explanation
        )
    }

    private func resourceReason(for reason: InferenceAdmissionReason) -> EngineResourceReason {
        switch reason {
        case .unsupportedCPUCount: .unsupportedCPUCount
        case .invalidThreads: .invalidThreads
        case .lowMemory: .lowMemory
        case .insufficientPhysicalMemory: .insufficientPhysicalMemory
        case .insufficientCommitHeadroom: .insufficientCommitHeadroom
        case .envelopeUnmeasured: .envelopeUnmeasured
        case .envelopeStale: .envelopeStale
        case .rtfUnmeasured: .rtfUnmeasured
        case .rtfStale: .rtfStale
        case .liveTooSlow: .liveTooSlow
        }
    }
}
