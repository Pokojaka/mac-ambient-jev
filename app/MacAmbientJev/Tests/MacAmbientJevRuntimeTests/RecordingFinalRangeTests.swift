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

private struct TailVAD: FinalTranscriptVADSegmenter {
    let provenance = tailProbeProvenance

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        let totalFrames = reader.info.committedFrames
        var state = VADSegmentationState(segmentationRunID: runID, canonicalSampleRate: 16_000)
        var segments: [SegmentReference] = [], cursor: Int64 = 0, checkedAudibleSamples = false
        while cursor < totalFrames {
            let readBoundary = cursor < speechStart ? speechStart : totalFrames
            let endFrame = min(cursor + 4_096, readBoundary), samples = try reader.readSamples(frameRange: cursor..<endFrame)
            cursor = endFrame
            let event = cursor == speechStart ? VADStreamEvent(kind: .speechStart, sampleIndex: Int(speechStart)) : nil
            segments += state.process(samples: samples, event: event, processedSamples: cursor)
            if cursor > speechStart && !checkedAudibleSamples {
                #expect(samples.prefix(320).contains { abs($0) > 0.1 })
                checkedAudibleSamples = true
            }
        }
        #expect(checkedAudibleSamples)
        segments += state.finish(totalCanonicalFrames: totalFrames)
        return segments
    }
}

private struct TailASR: ASREngine {
    let provenance = tailProbeProvenance
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        #expect(input.sampleRate == 16_000)
        #expect(input.samples.contains { abs($0) > 0.1 })
        return ASRResult(text: "末尾の発話", detectedLanguage: "ja")
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
    let processor = NativeSessionProcessor(paths: paths,
        engines: SessionProcessingEngines(asr: TailASR(), finalTranscriptVAD: TailVAD()),
        audioHandling: SessionProcessingAudio(timelineBuilder: AudioFileTimelineBuilder()),
        contentPriority: .disabled, sleep: { _ in })
    let liveRun = "seg_live_tail"
    _ = try await processor.startLiveTranscription(sessionID: sessionID, segmentationRunID: liveRun, sampleRate: 16_000)
    let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 0.5, sessionURL: layout.sessionURL)
    let ring = AudioBlockRing(capacity: 4, blockFrameCapacity: 4096, sampleRate: sampleRate)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: sampleRate))
    let totalDeviceFrames = Int(107.25 * sampleRate)
    var offset = 0, liveSplitDelivered = false, block = [Float](repeating: 0, count: 4096)
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
                segments: [SegmentReference(segmentationRunID: liveRun, segmentID: "live_split",
                                            speechRanges: [speechStart..<104 * 16_000])], checkpoint: checkpoint,
                onStatus: nil, onUpdate: nil)
            #expect(progress.materializedSegments.map(\.text) == ["末尾の発話"])
            liveSplitDelivered = true
        }
    }
    ring.finish(tailFrame: Int64(totalDeviceFrames))
    let checkpoint = try await drain.finish()
    #expect(checkpoint.committedFrames == 1_716_000)
    #expect(checkpoint.sampleRate == 16_000)
    #expect(checkpoint.gapEvents.isEmpty)
    let result = await processor.finishLiveTranscription(sessionID: sessionID, checkpoint: checkpoint,
        finalSegments: [SegmentReference(segmentationRunID: liveRun, segmentID: "live_tail",
                                         speechRanges: [104 * 16_000..<checkpoint.committedFrames])],
        pacingMode: .normal, shouldPause: { nil }, onPhase: { _ in }, onStatus: { _ in }, onUpdate: { _, _ in })
    #expect(result.disposition == .completed, "\(result.message ?? "no failure message")")
    let metadata = try #require(try ProcessingMetadataStore(sessionURL: url).load())
    #expect(metadata.finalizationAttempt?.state == .complete)
    let activeRuns = try #require(metadata.activeRuns)
    let lines = try SessionRecovery.recoverJSONL(Data(contentsOf: layout.eventsURL)).lines
    let events = try EventLogTranscriptReader().events(lines: lines, activeRuns: activeRuns)
    let transcript = try TranscriptMaterializer(sampleRate: 16_000).materialize(events: events, activeRuns: activeRuns)
    #expect(transcript.map(\.text) == ["末尾の発話"])
    #expect(transcript.count == 1)
    let transcriptRow = try #require(transcript.first)
    #expect(transcriptRow.startMilliseconds == 89_900)
    #expect(transcriptRow.endMilliseconds == 107_250)
    let createdRanges = try lines.compactMap { line -> (startFrame: Int64, endFrame: Int64, speechRanges: [[Int]])? in
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["event_type"] as? String == "segment.created",
              object["segmentation_run_id"] as? String == activeRuns.segmentation,
              let start = (object["source_start_frame"] as? NSNumber)?.int64Value,
              let end = (object["source_end_frame"] as? NSNumber)?.int64Value,
              let payload = object["payload"] as? [String: Any],
              let speechRanges = payload["speech_ranges"] as? [[Int]] else { return nil }
        return (start, end, speechRanges)
    }
    #expect(createdRanges.count == 1)
    let createdRange = try #require(createdRanges.first)
    #expect(createdRange.startFrame == speechStart - 1_600)
    #expect(createdRange.endFrame == checkpoint.committedFrames)
    #expect(createdRange.speechRanges.count == 2)
    let firstRange = try #require(createdRange.speechRanges.first)
    let secondRange = try #require(createdRange.speechRanges.dropFirst().first)
    #expect(Int64(firstRange[0]) == createdRange.startFrame)
    #expect(firstRange[1] == secondRange[0])
    #expect((createdRange.startFrame + 192_000...createdRange.startFrame + 224_000).contains(Int64(firstRange[1])))
    #expect(Int64(secondRange[1]) == checkpoint.committedFrames)
    guard case .recordingFLAC(let info) = try SessionAudioStorageStore(layout: layout).load() else {
        Issue.record("Finalized recording must be compacted to FLAC")
        return
    }
    #expect(info.committedFrames == checkpoint.committedFrames)
    #expect(!FileManager.default.fileExists(atPath: layout.processingDirectory.path))
}
