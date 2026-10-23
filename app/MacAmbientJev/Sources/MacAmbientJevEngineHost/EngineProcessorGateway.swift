import Foundation
import MacAmbientJevCore
import MacAmbientJevPipeline

enum EngineProcessorGatewayError: Error, LocalizedError {
    case notPrepared

    var errorDescription: String? {
        "モデルが準備されていません。models.prepare を実行してください"
    }
}

/// The processing and live-transcription coordinators keep one processor for their lifetime. The engine rebuilds the
/// processor when the settings' model profile changes, so the coordinators talk to this gateway, which forwards to
/// the current `NativeSessionProcessor`. Without one, work fails with `notPrepared`; it never runs on a substitute.
final class EngineProcessorGateway: SessionProcessingExecuting, LiveTranscriptionExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var processor: NativeSessionProcessor?
    private var pacing: ASRPacingMode = .normal

    func install(_ processor: NativeSessionProcessor, pacing: ASRPacingMode) {
        lock.lock()
        self.processor = processor
        self.pacing = pacing
        lock.unlock()
    }

    func setPacing(_ pacing: ASRPacingMode) {
        lock.lock()
        self.pacing = pacing
        lock.unlock()
    }

    /// Removes the processor and returns it so the caller can unload its models.
    func remove() -> NativeSessionProcessor? {
        lock.lock()
        defer { lock.unlock() }
        let removed = processor
        processor = nil
        return removed
    }

    /// Unloads the models of the current processor, if any; they load again on next use.
    func releaseIdleResources() async {
        guard let processor = try? current().processor else { return }
        await processor.releaseIdleResources()
    }

    var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return processor != nil
    }

    private func current() throws -> (processor: NativeSessionProcessor, pacing: ASRPacingMode) {
        lock.lock()
        defer { lock.unlock() }
        guard let processor else { throw EngineProcessorGatewayError.notPrepared }
        return (processor, pacing)
    }

    // MARK: SessionProcessingExecuting

    func processSession(
        sessionID: UUID,
        pacingMode: ASRPacingMode,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck,
        onPhase: @escaping NativeSessionProcessor.PhaseHandler,
        metadataPolicy: UnreadableMetadataPolicy,
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async -> SessionProcessingResult {
        let current: (processor: NativeSessionProcessor, pacing: ASRPacingMode)
        do {
            current = try self.current()
        } catch {
            return .failed(message: error.localizedDescription, metrics: nil, retained: nil)
        }
        return await current.processor.processSession(
            sessionID: sessionID,
            pacingMode: current.pacing,
            shouldPause: shouldPause,
            onPhase: onPhase,
            metadataPolicy: metadataPolicy,
            onStatus: onStatus,
            onUpdate: onUpdate
        )
    }

    func finishLiveTranscription(
        sessionID: UUID,
        checkpoint: AudioCheckpoint,
        finalSegments: [SegmentReference],
        pacingMode: ASRPacingMode,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck,
        onPhase: @escaping NativeSessionProcessor.PhaseHandler,
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async -> SessionProcessingResult {
        let current: (processor: NativeSessionProcessor, pacing: ASRPacingMode)
        do {
            current = try self.current()
        } catch {
            return .failed(message: error.localizedDescription, metrics: nil, retained: nil)
        }
        return await current.processor.finishLiveTranscription(
            sessionID: sessionID,
            checkpoint: checkpoint,
            finalSegments: finalSegments,
            pacingMode: current.pacing,
            shouldPause: shouldPause,
            onPhase: onPhase,
            onStatus: onStatus,
            onUpdate: onUpdate
        )
    }

    func retryContentPrioritySession(
        sessionID: UUID,
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference],
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async {
        let processor: NativeSessionProcessor
        do {
            processor = try current().processor
        } catch {
            await onStatus(error.localizedDescription)
            return
        }
        await processor.retryContentPrioritySession(
            sessionID: sessionID,
            boundarySegments: boundarySegments,
            clauses: clauses,
            onStatus: onStatus,
            onUpdate: onUpdate
        )
    }

    func cancelLiveTranscription(sessionID: UUID) async {
        guard let processor = try? current().processor else { return }
        await processor.cancelLiveTranscription(sessionID: sessionID)
    }

    // MARK: LiveTranscriptionExecuting

    func startLiveTranscription(sessionID: UUID, segmentationRunID: String, sampleRate: Double) async throws -> String {
        try await current().processor.startLiveTranscription(
            sessionID: sessionID, segmentationRunID: segmentationRunID, sampleRate: sampleRate
        )
    }

    func registerLiveSegments(sessionID: UUID, segments: [SegmentReference]) async throws -> LiveASRProgress {
        try await current().processor.registerLiveSegments(sessionID: sessionID, segments: segments)
    }

    func processLiveSegments(
        sessionID: UUID,
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint,
        onStatus: NativeSessionProcessor.StatusHandler?,
        onUpdate: NativeSessionProcessor.UpdateHandler?
    ) async throws -> LiveASRProgress {
        try await current().processor.processLiveSegments(
            sessionID: sessionID, segments: segments, checkpoint: checkpoint, onStatus: onStatus, onUpdate: onUpdate
        )
    }
}

/// The processing coordinators ask a `ThermalMonitoring` whether to pause finalization. Windows has no thermal
/// source, so this gate is the pause signal instead: the engine closes it on shutdown so a running finalization
/// stops at its next boundary and queued work is held, to be recovered on the next launch.
final class EngineProcessingPauseGate: ThermalMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false

    func pause() {
        lock.lock()
        paused = true
        lock.unlock()
    }

    var isCritical: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    var liveASRDecision: LiveASRThermalDecision { .processNow }

    @MainActor
    func observeChanges(_ onChange: @escaping @MainActor @Sendable () -> Void) -> any ThermalStateObservation {
        EnginePauseObservation()
    }
}

private final class EnginePauseObservation: ThermalStateObservation {}
