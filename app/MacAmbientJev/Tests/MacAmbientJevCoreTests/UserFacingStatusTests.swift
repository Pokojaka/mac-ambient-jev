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
