import Foundation
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevPipeline
@testable import MacAmbientJevRuntime
import Testing

private let tailProbeProvenance = RunProvenance(engine: "tail-probe", model: nil, version: "1", configuration: [:])
private let speechStart: Int64 = 90 * 16_000

@Test
func finalTranscriptVADProvenanceRecordsSegmentationConfiguration() throws {
    let paths = AppPaths(applicationSupportURL: URL(fileURLWithPath: "/tmp/unused-support"),
        cacheURL: URL(fileURLWithPath: "/tmp/unused-cache"), sessionsRootOverride: nil)
    let provenance = FluidFinalTranscriptVADSegmenter(models: try MacModelStore(paths: paths)).provenance
    #expect(provenance.engine == "fluidaudio-silero-vad")
    #expect(provenance.version == "FluidAudio@0.15.8")
    #expect(provenance.configuration == [
        "pre_roll_seconds": "0.1",
        "max_speech_range_seconds": "14.0",
        "max_segment_span_seconds": "30.0",
        "min_silence_seconds": "0.75",
        "vad_threshold": "0.5",
        "split_search_window_seconds": "2.0",
        "split_energy_frame_seconds": "0.02",
        "minimum_independent_speech_range_seconds": "0.5",
    ])
}

private let splitFrame: Int64 = 103 * 16_000

private func savedPrefixSegment(runID: String) -> SegmentReference {
    SegmentReference(
        segmentationRunID: runID, segmentID: "speech_001",
        speechRanges: [speechStart - 1_600..<splitFrame]
    )
}

private func recordingSegments(runID: String, frameCount: Int64) -> [SegmentReference] {
    [
        savedPrefixSegment(runID: runID),
        SegmentReference(
            segmentationRunID: runID, segmentID: "speech_002",
            speechRanges: [splitFrame..<frameCount]
        ),
    ]
}

private struct TailVAD: FinalTranscriptVADSegmenter {
    let provenance = tailProbeProvenance

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        let totalFrames = reader.info.committedFrames
        #expect(totalFrames == 1_716_000)
        let audibleSamples = try reader.readSamples(frameRange: speechStart..<speechStart + 320)
        #expect(audibleSamples.contains { abs($0) > 0.1 })
        return recordingSegments(runID: runID, frameCount: totalFrames)
    }
}

private actor TailASR: ASREngine {
    nonisolated let provenance = tailProbeProvenance
    private(set) var calls = 0

    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        calls += 1
        #expect(input.sampleRate == 16_000)
        #expect(input.samples.contains { abs($0) > 0.1 })
        return ASRResult(text: calls == 1 ? "保存済み区間" : "末尾の発話", detectedLanguage: "ja")
    }
}

@Test(arguments: [48_000.0, 44_100.0])
func recordingStopFinalizesTailAtNon16kHzDeviceRate(sampleRate: Double) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root.appending(path: "support"), cacheURL: root.appending(path: "cache"),
                         sessionsRootOverride: root.appending(path: "sessions"))
    let sessionID = UUID(), createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let url = try SessionBootstrapper(fileManager: .default).createSession(paths: paths, sessionID: sessionID,
        source: .recording(.microphone), createdAt: createdAt, timeZone: TimeZone(secondsFromGMT: 0)!)
    let layout = SessionLayout(sessionURL: url)
    let asr = TailASR()
    let processor = NativeSessionProcessor(paths: paths,
        engines: SessionProcessingEngines(asr: asr, finalTranscriptVAD: TailVAD()),
        audioHandling: SessionProcessingAudio(timelineBuilder: AudioFileTimelineBuilder()),
        contentPriority: .disabled, sleep: { _ in })
    let segmentationRunID = "seg_recording"
    _ = try await processor.startLiveTranscription(sessionID: sessionID, segmentationRunID: segmentationRunID, sampleRate: 16_000)
    let initialState = try #require(try ProcessingLogState(eventsURL: layout.eventsURL, sessionID: sessionID))
    let generationID = initialState.generation.id
    let initialRuns = initialState.runs
    let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 0.5, sessionURL: layout.sessionURL)
    let ring = AudioBlockRing(capacity: 4, blockFrameCapacity: 4096, sampleRate: sampleRate)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: sampleRate))
    let totalDeviceFrames = Int(107.25 * sampleRate)
    var offset = 0, liveSplitDelivered = false, block = [Float](repeating: 0, count: 4096)
    var savedPrefixSource: SegmentTextReference?
    while offset < totalDeviceFrames {
        let count = min(block.count, totalDeviceFrames - offset)
        for frame in 0..<count {
            let seconds = Double(offset + frame) / sampleRate
            block[frame] = seconds >= 90 ? Float(0.3 * sin(2 * .pi * 440 * seconds)) : 0
        }
        let accepted = block.withUnsafeMutableBufferPointer { samples in
            var channel = samples.baseAddress!
            return withUnsafePointer(to: &channel) {
                ring.pushPlanarFloat32(channelData: $0, channelCount: 1, frameCount: count, startFrame: Int64(offset))
            }
        }
        #expect(accepted)
        _ = try await drain.drainAvailable()
        offset += count
        if !liveSplitDelivered, Double(offset) / sampleRate >= 104.5 {
            let checkpoint = try await drain.committedSnapshot()
            let progress = try await processor.processLiveSegments(sessionID: sessionID,
                segments: [savedPrefixSegment(runID: segmentationRunID)], checkpoint: checkpoint,
                onStatus: nil, onUpdate: nil)
            #expect(progress.materializedSegments.map(\.text) == ["保存済み区間"])
            savedPrefixSource = try #require(progress.materializedSegments.first?.source)
            #expect(await asr.calls == 1)
            liveSplitDelivered = true
        }
    }
    #expect(liveSplitDelivered)
    let savedPrefix = try #require(savedPrefixSource)
    ring.finish(tailFrame: Int64(totalDeviceFrames))
    let checkpoint = try await drain.finish()
    #expect(checkpoint.committedFrames == 1_716_000)
    #expect(checkpoint.sampleRate == 16_000)
    #expect(checkpoint.gapEvents.isEmpty)
    let result = await processor.finishLiveTranscription(sessionID: sessionID, checkpoint: checkpoint,
        pacingMode: .normal, shouldPause: { nil }, onPhase: { _ in }, onStatus: { _ in }, onUpdate: { _, _ in })
    #expect(result.disposition == .completed, "\(result.message ?? "no failure message")")
    #expect(await asr.calls == 2)
    let stored = try EventLogTranscriptReader().validateCompletion(
        eventsURL: layout.eventsURL, sessionID: sessionID, frameCount: checkpoint.committedFrames
    )
    #expect(stored.state.generation.id == generationID)
    #expect(stored.state.runs.selectsSameRuns(as: initialRuns))
    #expect(stored.state.runs.segmentation == segmentationRunID)
    let expectedSegments = recordingSegments(runID: segmentationRunID, frameCount: checkpoint.committedFrames)
    #expect(stored.state.segments == expectedSegments)
    let transcript = try TranscriptMaterializer(sampleRate: stored.state.generation.sampleRate)
        .materialize(events: stored.events, activeRuns: stored.state.runs)
    #expect(transcript.map(\.segmentID) == ["speech_001", "speech_002"])
    #expect(transcript.first?.source == savedPrefix)
    #expect(transcript.map(\.text) == ["保存済み区間", "末尾の発話"])
    #expect(transcript.map(\.startMilliseconds) == [89_900, 103_000])
    #expect(transcript.map(\.endMilliseconds) == [103_000, 107_250])
    guard case .recordingFLAC(let info) = try SessionAudioStorageStore(layout: layout).load() else {
        Issue.record("Finalized recording must be compacted to FLAC")
        return
    }
    #expect(info.committedFrames == checkpoint.committedFrames)
    #expect(!FileManager.default.fileExists(atPath: layout.processingDirectory.path))
}
