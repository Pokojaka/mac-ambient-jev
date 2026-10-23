#if os(Windows)
import Foundation
import Testing
import WinSDK
@testable import MacAmbientJevCore

struct WindowsTokenizerMemoryTests {
    // Keep the parent process's blocking subprocess wait off the cooperative executor.
    @Test func maximumVocabularyParsingDoesNotRetainPerValueErrors() async throws {
        try await withTaskExecutorPreference(BlockingIOExecutor.shared) {
            switch ProcessInfo.processInfo.environment["MJA_TOKENIZER_MEMORY_CHILD"] {
            case nil:
                let process = Process()
                process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                process.arguments = [
                    "--testing-library", "swift-testing",
                    "--filter", "MacAmbientJevWindowsSupportTests.WindowsTokenizerMemoryTests/maximumVocabularyParsingDoesNotRetainPerValueErrors"
                ]
                var environment = ProcessInfo.processInfo.environment
                environment["MJA_TOKENIZER_MEMORY_CHILD"] = "1"
                process.environment = environment
                try process.run()
                process.waitUntilExit()
                #expect(process.terminationStatus == 0)
            case "1":
                try runMaximumVocabularyMemoryProbe()
            case let marker?:
                throw NSError(
                    domain: "WindowsTokenizerMemoryTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected MJA_TOKENIZER_MEMORY_CHILD value: \(marker)"]
                )
            }
        }
    }
}

private func runMaximumVocabularyMemoryProbe() throws {
    let tokenizerData = try maximumVocabularyTokenizerData()

    try parseAndCheckMaximumVocabulary(tokenizerData)
    let before = try privateBytes()
    print("WindowsTokenizerMemoryTests phase=warmup private_bytes=\(before)")

    var after = before
    for iteration in 1...3 {
        try parseAndCheckMaximumVocabulary(tokenizerData)
        after = try privateBytes()
        print("WindowsTokenizerMemoryTests iteration=\(iteration) private_bytes=\(after)")
    }

    #expect(
        after <= before + 64 * 1024 * 1024,
        "Retained private-byte growth exceeded 64 MiB: before=\(before), after=\(after)"
    )
}

private func parseAndCheckMaximumVocabulary(_ data: Data) throws {
    let configuration = try ClauseTaggerTokenizerConfiguration(data: data)
    guard configuration.vocabulary.count == 102_400,
          configuration.unknownID == 0,
          configuration.vocabulary[275].token == "、",
          configuration.vocabulary[configuration.vocabulary.count - 1].token == "token-102399",
          configuration.addedTokens.count == 15
    else {
        throw NSError(
            domain: "WindowsTokenizerMemoryTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Parsed tokenizer did not match the maximum-vocabulary fixture."]
        )
    }
}

private func privateBytes() throws -> UInt64 {
    var counters = PROCESS_MEMORY_COUNTERS_EX()
    let byteCount = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS_EX>.size)
    counters.cb = byteCount
    let succeeded = withUnsafeMutablePointer(to: &counters) { countersPointer in
        countersPointer.withMemoryRebound(to: PROCESS_MEMORY_COUNTERS.self, capacity: 1) { apiCountersPointer in
            K32GetProcessMemoryInfo(GetCurrentProcess(), apiCountersPointer, byteCount)
        }
    }
    guard succeeded else {
        throw NSError(
            domain: "WindowsTokenizerMemoryTests",
            code: Int(GetLastError())
        )
    }
    return UInt64(counters.PrivateUsage)
}

private func maximumVocabularyTokenizerData() throws -> Data {
    let fixedTokens = [
        "<unk>", "<s>", "</s>", "<pad>", "<sep>", "<mask>", "<cls>",
        "<|system|>", "<|assistant|>", "<|user|>", "<|available_tools|>",
        "<|tool_calls|>", "<|tool_results|>", "<|code|>", "<|file|>"
    ]
    var vocabulary: [[Any]] = fixedTokens.map { [$0, Double(-1)] }
    vocabulary.reserveCapacity(102_400)
    for byte in 0..<256 {
        vocabulary.append([String(format: "<0x%02X>", byte), Double(-1)])
    }
    for token in ["▁", "a", "b", "c", "、"] {
        vocabulary.append([token, Double(-1)])
    }
    for id in 276..<102_400 {
        vocabulary.append(["token-\(id)", Double(-1)])
    }

    let addedTokens: [[String: Any]] = fixedTokens.enumerated().map { id, content in
        [
            "id": id,
            "content": content,
            "single_word": false,
            "lstrip": false,
            "rstrip": false,
            "normalized": false,
            "special": id <= 6
        ]
    }
    let postProcessor: [String: Any] = [
        "type": "TemplateProcessing",
        "single": [
            ["SpecialToken": ["id": "<s>", "type_id": 0]],
            ["Sequence": ["id": "A", "type_id": 0]],
            ["SpecialToken": ["id": "</s>", "type_id": 0]]
        ],
        "pair": [
            ["SpecialToken": ["id": "<s>", "type_id": 0]],
            ["Sequence": ["id": "A", "type_id": 0]],
            ["SpecialToken": ["id": "</s>", "type_id": 0]],
            ["SpecialToken": ["id": "<s>", "type_id": 1]],
            ["Sequence": ["id": "B", "type_id": 1]],
            ["SpecialToken": ["id": "</s>", "type_id": 1]]
        ],
        "special_tokens": [
            "</s>": ["id": "</s>", "ids": [2], "tokens": ["</s>"]],
            "<s>": ["id": "<s>", "ids": [1], "tokens": ["<s>"]]
        ]
    ]
    let decoder: [String: Any] = [
        "type": "Sequence",
        "decoders": [
            ["type": "Replace", "pattern": ["String": "▁"], "content": " "],
            ["type": "ByteFallback"],
            ["type": "Fuse"]
        ]
    ]
    let root: [String: Any] = [
        "version": "1.0",
        "truncation": NSNull(),
        "padding": NSNull(),
        "added_tokens": addedTokens,
        "normalizer": NSNull(),
        "pre_tokenizer": [
            "type": "Metaspace",
            "replacement": "▁",
            "prepend_scheme": "never",
            "split": false
        ],
        "post_processor": postProcessor,
        "decoder": decoder,
        "model": [
            "type": "Unigram",
            "unk_id": 0,
            "byte_fallback": true,
            "vocab": vocabulary
        ]
    ]
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}
#endif
