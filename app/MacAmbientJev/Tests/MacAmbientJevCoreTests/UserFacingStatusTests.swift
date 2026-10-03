import Testing
@testable import MacAmbientJevCore

@Test
func userFacingStatusStringsRemainJapanese() {
    #expect(
        UserFacingStatus.loadingASR.text
            == "音声認識モデルを読み込んでいます"
    )
    #expect(
        UserFacingStatus.jevDeferred.text
            == "意味分類を後で再試行します"
    )
    #expect(
        UserFacingStatus.detectingSpeech.text
            == "発話区間を検出しています"
    )
}

@Test
func pausedAndSuspendedStatusesNameTheirCause() {
    #expect(
        UserFacingStatus.finalizationPausedForHeat.text
            == "発熱のため確定処理を一時停止中"
    )
    #expect(
        UserFacingStatus.jevAuthorizationRequired.text
            == "Jev の API キーの修正が必要です。意味分類を保留しました"
    )
    #expect(
        UserFacingStatus.liveTranscriptionThermalSuspended.text
            == "発熱のためライブ表示を一時停止中"
    )
}
