import Testing
import MacAmbientJevCore
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevWindowsSupport
@testable import MacAmbientJevEngine

@Suite @MainActor struct WindowsEngineCaptureTests {
    @Test func didOverflowReflectsAnyCheckpointGap() throws {
        let overflow = try WindowsEngineCaptureSession.stopResult(
            WindowsCaptureStopResult(
                checkpoint: checkpoint(gaps: [gap(.overflow, frames: 7)]),
                healthyPrefixOnly: false,
                errors: []
            )
        )
        let missingCallback = try WindowsEngineCaptureSession.stopResult(
            WindowsCaptureStopResult(
                checkpoint: checkpoint(gaps: [gap(.missingCallback, frames: 11)]),
                healthyPrefixOnly: false,
                errors: []
            )
        )
        let noGap = try WindowsEngineCaptureSession.stopResult(
            WindowsCaptureStopResult(
                checkpoint: checkpoint(gaps: []),
                healthyPrefixOnly: false,
                errors: []
            )
        )

        #expect(overflow.didOverflow)
        #expect(missingCallback.didOverflow)
        #expect(!noGap.didOverflow)
    }

    @Test func healthyPrefixMapsWriterDiagnosticsAndCheckpointStatistics() throws {
        let checkpoint = checkpoint(gaps: [
            gap(.overflow, frames: 7),
            gap(.missingCallback, frames: 11)
        ])
        let result = try WindowsEngineCaptureSession.stopResult(
            WindowsCaptureStopResult(
                checkpoint: checkpoint,
                healthyPrefixOnly: true,
                errors: ["writer append failed", "writer finish failed"]
            )
        )

        #expect(result.checkpoint == checkpoint)
        #expect(result.didOverflow)
        #expect(result.dropoutCount == 2)
        #expect(result.gapCount == 2)
        #expect(result.totalGapFrames == 18)
        #expect(!result.sleepAssertionHeld)
        #expect(result.writerFailure == "writer append failed; writer finish failed")
        #expect(result.systemAudioReleaseFailure == nil)
    }

    @Test func healthyPrefixWithoutErrorsIsRejectedAsCaptureFailure() {
        do {
            _ = try WindowsEngineCaptureSession.stopResult(
                WindowsCaptureStopResult(
                    checkpoint: checkpoint(gaps: []),
                    healthyPrefixOnly: true,
                    errors: []
                )
            )
            Issue.record("Expected a healthy-prefix result without diagnostics to fail")
        } catch let error as EngineAdapterError {
            #expect(error.code == .captureFailure)
            #expect(error.details.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func checkpointAbsenceIsRejectedWithStopErrorDetails() {
        do {
            _ = try WindowsEngineCaptureSession.stopResult(
                WindowsCaptureStopResult(
                    checkpoint: nil,
                    healthyPrefixOnly: false,
                    errors: ["native stop failed"]
                )
            )
            Issue.record("Expected a missing checkpoint to fail")
        } catch let error as EngineAdapterError {
            #expect(error.code == .captureFailure)
            #expect(error.details.map(\.message) == ["native stop failed"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func cleanupErrorDetailsRemainAvailable() throws {
        let result = try WindowsEngineCaptureSession.stopResult(
            WindowsCaptureStopResult(
                checkpoint: checkpoint(gaps: []),
                healthyPrefixOnly: false,
                errors: ["capture device release failed"]
            )
        )

        #expect(result.writerFailure == nil)
        #expect(result.systemAudioReleaseFailure == "capture device release failed")
    }
}

private func checkpoint(gaps: [AudioGapEvent]) -> AudioCheckpoint {
    AudioCheckpoint(
        committedFrames: 48_000,
        sampleRate: 16_000,
        channelCount: 1,
        sampleFormat: .float32LE,
        chunkFiles: ["00000000.caf"],
        chunkFrameCounts: [48_000],
        gapEvents: gaps
    )
}

private func gap(_ reason: AudioGapReason, frames: Int64) -> AudioGapEvent {
    AudioGapEvent(startFrame: 0, frameCount: frames, reason: reason)
}
