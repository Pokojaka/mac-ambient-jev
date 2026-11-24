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

    func retryContentPrioritySession(
        sessionID: UUID,
        boundarySegments: [SegmentTextReference],
        clauses: [ClauseReference],
        onStatus: @escaping NativeSessionProcessor.StatusHandler,
        onUpdate: @escaping NativeSessionProcessor.UpdateHandler
    ) async -> SessionProcessingResult {
        let processor: NativeSessionProcessor
        do {
            processor = try current().processor
        } catch {
            let message = "発話文の判定を再試行できませんでした: \(error.localizedDescription)"
            await onStatus(.message(message))
            return .failed(message: message, metrics: nil, retained: nil)
        }
        return await processor.retryContentPrioritySession(
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

    func startLiveTranscription(sessionID: UUID, sampleRate: Double) async throws -> String {
        try await current().processor.startLiveTranscription(sessionID: sessionID, sampleRate: sampleRate)
    }

    func hasUnresolvedASRFailure(sessionID: UUID) async throws -> Bool {
        try await current().processor.hasUnresolvedASRFailure(sessionID: sessionID)
    }

    func sealLiveSegmentation(sessionID: UUID, frameCount: Int64) async throws {
        try await current().processor.sealLiveSegmentation(sessionID: sessionID, frameCount: frameCount)
    }

    func completeLiveSegmentation(sessionID: UUID, frameCount: Int64, segmentCount: Int) async throws {
        try await current().processor.completeLiveSegmentation(
            sessionID: sessionID, frameCount: frameCount, segmentCount: segmentCount
        )
    }

    func registerLiveSegments(sessionID: UUID, segments: [SegmentReference]) async throws -> LiveASRProgress {
        try await current().processor.registerLiveSegments(sessionID: sessionID, segments: segments)
    }

    func processLiveSegments(
        sessionID: UUID,
        segments: [SegmentReference],
        checkpoint: AudioCheckpoint,
        shouldPause: @escaping NativeSessionProcessor.PauseCheck,
        onStatus: NativeSessionProcessor.StatusHandler?,
        onUpdate: NativeSessionProcessor.UpdateHandler?
    ) async throws -> LiveASRProgress {
        try await current().processor.processLiveSegments(
            sessionID: sessionID, segments: segments, checkpoint: checkpoint, shouldPause: shouldPause,
            onStatus: onStatus, onUpdate: onUpdate
        )
    }
}
