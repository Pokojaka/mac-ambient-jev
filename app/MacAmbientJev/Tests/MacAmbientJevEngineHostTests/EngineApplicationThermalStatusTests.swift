import Testing
import MacAmbientJevCore
@testable import MacAmbientJevEngineHost
import MacAmbientJevPipeline

@Test(arguments: [
    UserFacingStatus.idle,
    .checkingMicrophone,
    .startingRecording,
    .importingAudio,
    .convertingTimeline,
    .detectingSpeech,
    .preparingASR,
    .loadingASR,
    .asrBacklogged,
    .preparingDiarization,
    .diarizing,
    .classifyingContent,
    .decisionDeferred
])
func processorPresentationTextPreservesNonthermalActivity(_ activity: UserFacingStatus) {
    #expect(
        EngineApplicationCore.processorPresentationText(.activity(activity)) == activity.text
    )
}

@Test
func processorPresentationTextPreservesDynamicMessages() {
    let message = "processor detail: dynamic status"
    #expect(EngineApplicationCore.processorPresentationText(.message(message)) == message)
}

@Test
func processorPresentationTextRejectsFinalizationPausedForHeat() async {
    await #expect(processExitsWith: .failure) {
        _ = EngineApplicationCore.processorPresentationText(.activity(.finalizationPausedForHeat))
    }
}

@Test
func processorPresentationTextRejectsLiveTranscriptionThermalSuspended() async {
    await #expect(processExitsWith: .failure) {
        _ = EngineApplicationCore.processorPresentationText(.activity(.liveTranscriptionThermalSuspended))
    }
}
