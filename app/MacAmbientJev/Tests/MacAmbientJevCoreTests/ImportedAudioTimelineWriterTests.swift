import Foundation
import Testing
@testable import MacAmbientJevCore

private final class ImportedAudioTimelineConverterStub: CanonicalAudioConverting, @unchecked Sendable {
    let sourceSampleRate = CanonicalAudio.sampleRate
    private let finishTail: [Float]
    private let conversionError: CanonicalAudioError?

    init(finishTail: [Float] = [], conversionError: CanonicalAudioError? = nil) {
        self.finishTail = finishTail
        self.conversionError = conversionError
    }

    // ImportedAudioTimelineWriter owns converter calls on its serialized actor lane.
    func convert(mono: [Float]) throws -> [Float] {
        if let conversionError { throw conversionError }
        return mono
    }

    func finish() throws -> [Float] { finishTail }
}

private func expectImportedAudioTimelineError(
    _ predicate: (CanonicalAudioError) -> Bool,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected a CanonicalAudioError")
    } catch let error as CanonicalAudioError {
        #expect(predicate(error))
    } catch {
        Issue.record("Expected CanonicalAudioError, received \(error)")
    }
}

private func expectImportedAudioTimelineError(
    _ predicate: (CanonicalAudioError) -> Bool,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected a CanonicalAudioError")
    } catch let error as CanonicalAudioError {
        #expect(predicate(error))
    } catch {
        Issue.record("Expected CanonicalAudioError, received \(error)")
    }
}

@Test func importedAudioTimelineDownmixAveragesAscendingMultichannelFramesExactly() throws {
    let input: [[Float]] = [
        [1, 2, 3],
        [3, 4, 5],
        [-3, -2, -1]
    ]

    let mono = try ImportedAudioPCM.downmix(frameCount: input.count, channelCount: 3) {
        frame, channel in input[frame][channel]
    }

    #expect(mono == [2, 4, -2])
}

@Test func importedAudioTimelineDownmixAcceptsEmptyInput() throws {
    let mono = try ImportedAudioPCM.downmix(frameCount: 0, channelCount: 2) { _, _ in
        Issue.record("An empty input must not request samples")
        return 0
    }

    #expect(mono == [])
}

@Test func importedAudioTimelineDownmixRejectsInvalidDimensions() {
    expectImportedAudioTimelineError(
        { if case .invalidSourceFormat = $0 { true } else { false } },
        operation: {
            _ = try ImportedAudioPCM.downmix(frameCount: -1, channelCount: 1) { _, _ in 0 }
        }
    )
    expectImportedAudioTimelineError(
        { if case .invalidSourceFormat = $0 { true } else { false } },
        operation: {
            _ = try ImportedAudioPCM.downmix(frameCount: 1, channelCount: 0) { _, _ in 0 }
        }
    )
}

@Test func importedAudioTimelineDownmixRejectsNonfiniteSamplesAndOverflowingSums() {
    expectImportedAudioTimelineError(
        { if case .invalidSamples = $0 { true } else { false } },
        operation: {
            _ = try ImportedAudioPCM.downmix(frameCount: 1, channelCount: 1) { _, _ in .infinity }
        }
    )
    expectImportedAudioTimelineError(
        { if case .invalidSamples = $0 { true } else { false } },
        operation: {
            _ = try ImportedAudioPCM.downmix(frameCount: 1, channelCount: 2) { _, _ in
                .greatestFiniteMagnitude
            }
        }
    )
}

@Test func importedAudioTimelineLocalizesCanonicalAudioErrors() {
    #expect(CanonicalAudioError.noncanonicalFormat.errorDescription ==
        "内部音声は16,000 Hz・mono・float32 PCMである必要があります")
    #expect(CanonicalAudioError.invalidSourceFormat.errorDescription ==
        "入力音声のサンプルレートまたはフレーム範囲が不正です")
    #expect(CanonicalAudioError.invalidSamples.errorDescription ==
        "PCMバッファが不正か、非有限の音声サンプルが含まれています")
    #expect(CanonicalAudioError.alreadyFinished.errorDescription ==
        "終端処理後の音声変換器には入力できません")
    #expect(CanonicalAudioError.conversionFailed("test").errorDescription ==
        "正規音声への変換に失敗しました: test")
    #expect(CanonicalAudioError.frameCountMismatch(expected: 12, actual: 10).errorDescription ==
        "正規音声の変換結果は10フレームです（期待値: 12）。")
}

@Test func importedAudioTimelineWriterPersistsCanonicalAudioAndFinishTail() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "ImportedAudioTimelineWriter-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directory = root.appending(path: "audio", directoryHint: .isDirectory)
    let writer = try ImportedAudioTimelineWriter(
        directory: directory,
        sessionURL: root,
        converter: ImportedAudioTimelineConverterStub(finishTail: [0.25])
    )

    try await writer.append(mono: [0.5, -0.5])
    try await writer.append(mono: [1, 0])
    let checkpoint = try await writer.finish()

    #expect(checkpoint.committedFrames == 5)
    #expect(checkpoint.sampleRate == CanonicalAudio.sampleRate)
    #expect(checkpoint.channelCount == CanonicalAudio.channelCount)
    #expect(checkpoint.sampleFormat == CanonicalAudio.sampleFormat)
    #expect(checkpoint.chunkFiles == ["chunk-000000.f32le"])
    #expect(checkpoint.chunkFrameCounts == [5])
    #expect(checkpoint.gapEvents.isEmpty)
    let reader = try ProcessingTimelineReader(directory: directory, checkpoint: checkpoint, sessionURL: root)
    #expect(try reader.readSamples(frameRange: 0..<5) == [0.5, -0.5, 1, 0, 0.25])
    #expect(try await writer.finish() == checkpoint)

    await expectImportedAudioTimelineError(
        { if case .alreadyFinished = $0 { true } else { false } },
        operation: { try await writer.append(mono: [2]) }
    )
}

@Test func importedAudioTimelineWriterKeepsConversionFailureTerminal() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "ImportedAudioTimelineWriter-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directory = root.appending(path: "audio", directoryHint: .isDirectory)
    let writer = try ImportedAudioTimelineWriter(
        directory: directory,
        sessionURL: root,
        converter: ImportedAudioTimelineConverterStub(conversionError: .conversionFailed("input rejected"))
    )

    let isTerminalConversionFailure: (CanonicalAudioError) -> Bool = {
        if case .conversionFailed("input rejected") = $0 { true } else { false }
    }
    await expectImportedAudioTimelineError(isTerminalConversionFailure) {
        try await writer.append(mono: [1])
    }
    await expectImportedAudioTimelineError(isTerminalConversionFailure) {
        _ = try await writer.finish()
    }

    let recovered = try #require(try AudioCheckpoint.loadRecovered(from: directory, relativeTo: root))
    #expect(recovered.committedFrames == 0)
    #expect(recovered.chunkFiles.isEmpty)
    #expect(recovered.chunkFrameCounts.isEmpty)
    #expect(recovered.gapEvents.isEmpty)
}
