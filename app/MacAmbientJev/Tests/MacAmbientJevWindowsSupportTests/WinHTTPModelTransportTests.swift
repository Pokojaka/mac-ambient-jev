import Foundation
import MacAmbientJevCore
import Testing
@testable import MacAmbientJevWindowsSupport

private let networkTestsEnabled = ProcessInfo.processInfo.environment["MAC_AMBIENT_JEV_NETWORK_TESTS"] == "1"

// The pinned Qwen3-ASR 0.6B tokenizer, which Hugging Face serves through a redirect.
private let commit = "4fc24a1402e74db89c4d2ef256875e71680128c4"
private let tokenizerSize: Int64 = 11_429_377
private let tokenizerURL = URL(string: "https://huggingface.co/andrewleech/qwen3-asr-0.6b-onnx/resolve/\(commit)/tokenizer.json")!
private let tokenizerEntry = ModelManifestEntry(
    repository: "andrewleech/qwen3-asr-0.6b-onnx",
    commit: commit,
    files: [ModelManifestFile(
        name: "tokenizer.json", role: "tokenizer", byteCount: tokenizerSize,
        sha256: "bd2a97b55c8f7f9c328c73ee9b9178771037e9f566dfca8e238a063d41cbac92"
    )]
)

private final class LastProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ModelDownloadProgress?
    func set(_ progress: ModelDownloadProgress) { lock.lock(); value = progress; lock.unlock() }
    var last: ModelDownloadProgress? { lock.lock(); defer { lock.unlock() }; return value }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "winhttp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

@Suite(.enabled(if: networkTestsEnabled, "MAC_AMBIENT_JEV_NETWORK_TESTS=1 でネットワークテストを有効にします"))
struct WinHTTPModelTransportTests {
    @Test func downloadsAndVerifiesTheWholeFileThroughARedirect() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let progress = LastProgress()
        try await ModelFetcher.fetch(into: directory, entry: tokenizerEntry, transport: WinHTTPModelTransport()) { progress.set($0) }
        #expect(progress.last?.bytesDone == tokenizerSize)
        #expect(progress.last?.bytesTotal == tokenizerSize)
    }

    @Test func resumesAPartialFileWithRange() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = WinHTTPModelTransport()
        var head = Data()
        let first = try await transport.open(ModelDownloadRequest(url: tokenizerURL, startOffset: nil))
        for try await chunk in first.chunks {
            head.append(chunk)
            if head.count >= 1_000_000 { break }
        }
        try head.prefix(1_000_000).write(to: directory.appending(path: "tokenizer.json.partial"))

        let resumed = try await transport.open(ModelDownloadRequest(url: tokenizerURL, startOffset: 1_000_000))
        #expect(resumed.statusCode == 206)
        #expect(resumed.contentRange == "bytes 1000000-11429376/11429377")

        try await ModelFetcher.fetch(into: directory, entry: tokenizerEntry, transport: transport) { _ in }
        #expect(try Data(contentsOf: directory.appending(path: "tokenizer.json")).count == Int(tokenizerSize))
    }

    @Test func aSlowConsumerReceivesEachByteExactlyOnce() async throws {
        let response = try await WinHTTPModelTransport().open(ModelDownloadRequest(url: tokenizerURL, startOffset: nil))
        var total: Int64 = 0
        for try await chunk in response.chunks {
            total += Int64(chunk.count)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(total == tokenizerSize)
    }
}

@Test func nonHTTPSURLIsRejected() async {
    let request = ModelDownloadRequest(url: URL(string: "http://huggingface.co/")!, startOffset: nil)
    do {
        _ = try await WinHTTPModelTransport().open(request)
        Issue.record("open accepted a non-https URL")
    } catch let error as WinHTTPError {
        #expect(error.call == "https required")
    } catch {
        Issue.record("unexpected error \(error)")
    }
}
