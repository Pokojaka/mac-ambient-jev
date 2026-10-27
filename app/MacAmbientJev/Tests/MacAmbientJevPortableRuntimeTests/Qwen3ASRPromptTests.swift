import Testing
@testable import MacAmbientJevPortableRuntime

struct Qwen3ASRPromptTests {
    @Test
    func promptIsTheMacPromptAroundTheAudioPadRun() throws {
        let prompt = try Qwen3ASRPrompt(audioTokenCount: 3)
        #expect(prompt.tokenIDs == [
            151644, 8948, 198, 151645, 198, 151644, 872, 198, 151669,
            151676, 151676, 151676,
            151670, 151645, 198, 151644, 77091, 198, 11528, 11937, 151704,
        ])
    }

    @Test
    func lengthIsTwentyTokensPlusTheAudioTokens() throws {
        #expect(try Qwen3ASRPrompt(audioTokenCount: 1).tokenIDs.count == 19)
        #expect(try Qwen3ASRPrompt(audioTokenCount: 390).tokenIDs.count == 408)
    }

    @Test(arguments: [0, -1])
    func nonPositiveAudioTokenCountFails(count: Int) {
        #expect(throws: Qwen3ASRError.invalidAudioTokenCount(count)) {
            try Qwen3ASRPrompt(audioTokenCount: count)
        }
    }
}
