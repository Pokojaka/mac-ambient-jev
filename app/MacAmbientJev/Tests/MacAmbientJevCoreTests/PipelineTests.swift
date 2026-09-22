import Testing
@testable import MacAmbientJevCore

@Test
func recordingCanRemainActiveWhileProcessingIsBacklogged() async {
    let state = SessionProcessingState()

    await state.setCapture(.recording)
    await state.setProcessing(.backlogged)

    #expect(await state.captureState == .recording)
    #expect(await state.processingState == .backlogged)
}

@Test
func processingFailureDoesNotOverwriteCaptureState() async {
    let state = SessionProcessingState()

    await state.setCapture(.recording)
    await state.setProcessing(.partialFailure("ASR failed"))

    #expect(await state.captureState == .recording)
    #expect(await state.processingState == .partialFailure("ASR failed"))
}
