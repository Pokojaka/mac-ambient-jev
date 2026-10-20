import struct FluidAudio.OfflineDiarizerConfig
import Foundation
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevPipeline
@testable import MacAmbientJevRuntime
import Testing

private let tailProbeProvenance = RunProvenance(engine: "tail-probe", model: nil, version: "1", configuration: [:])
private let speechStart: Int64 = 90 * 16_000

@Test
func finalTranscriptVADProvenanceRecordsSegmentationConfiguration() {
    let provenance = FluidFinalTranscriptVADSegmenter().provenance
    #expect(provenance.engine == "fluidaudio-silero-vad")
    #expect(provenance.version == "FluidAudio@0.15.8")
    #expect(provenance.configuration == [
        "pre_roll_seconds": "0.1",
        "max_segment_seconds": "14.0",
        "min_silence_seconds": "0.75",
        "vad_threshold": "0.5",
        "split_search_window_seconds": "2.0",
        "split_energy_frame_seconds": "0.02",
        "minimum_independent_segment_seconds": "0.5",
    ])
}

private struct TailVAD: FinalTranscriptVADSegmenter {
    let provenance = tailProbeProvenance

    func segment(reader: any TimelineAudioReading, runID: String) async throws -> [SegmentReference] {
        let totalFrames = reader.info.committedFrames
        let maxSegmentFrames: Int64 = 14 * 16_000
        let searchWindowFrames: Int64 = 2 * 16_000
        var history = RollingFrameEnergyHistory(frameSampleCount: 320, capacity: 150)
        var assembler = SegmentationAssembler(
            segmentationRunID: runID,
            preRollFrames: 0,
            maxSegmentFrames: maxSegmentFrames,
            minimumIndependentSegmentFrames: 8_000
        )
        var segments: [SegmentReference] = []
        var cursor: Int64 = 0
        var checkedAudibleSamples = false

        while cursor < totalFrames {
            let readBoundary = cursor < speechStart ? speechStart : totalFrames
            let endFrame = min(cursor + 4_096, readBoundary)
            let samples = try reader.readSamples(frameRange: cursor..<endFrame)
            history.append(samples)
            cursor = endFrame

            if cursor == speechStart {
                assembler.speechStarted(atFrame: speechStart)
            } else if cursor > speechStart && !checkedAudibleSamples {
                #expect(samples.prefix(320).contains { abs($0) > 0.1 })
                checkedAudibleSamples = true
            }

            while let start = assembler.splitStartFrameIfNeeded(atFrame: cursor) {
                let range = (start + maxSegmentFrames - searchWindowFrames)..<(start + maxSegmentFrames)
                let cutFrame = history.quietestFrame(in: range)
                segments.append(assembler.split(atFrame: cutFrame))
            }
        }

        #expect(checkedAudibleSamples)
        segments.append(contentsOf: assembler.speechEnded(atFrame: totalFrames))
        return segments
    }
}

private struct TailWindowDiarizer: DiarizationEngine {
    let provenance = tailProbeProvenance
    func prepare() async throws {}
    func unload() async {}

    func diarize(fileURL: URL, canonicalSampleRate: Double, sessionURL: URL) async throws -> [SpeakerSpan] {
        let source = try CanonicalCAFAudioSource(fileURL: fileURL, sessionURL: sessionURL)
        let config = OfflineDiarizerConfig.default
        var window = [Float](repeating: 0, count: config.samplesPerWindow)
        // OfflineEmbeddingExtractor requests the full window, including at EOF, after zeroing its buffer.
        for offset in stride(from: 0, to: source.sampleCount, by: config.samplesPerStep) {
            window.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
            try window.withUnsafeMutableBufferPointer {
                try source.copySamples(into: $0.baseAddress!, offset: offset, count: $0.count)
            }
            let available = min(window.count, source.sampleCount - offset)
            #expect(window[available...].allSatisfy { $0 == 0 })
            if offset >= Int(speechStart) {
                #expect(window[..<available].contains { abs($0) > 0.1 })
            }
        }
        return [SpeakerSpan(speakerID: "tail", startFrame: speechStart,
            endFrame: Int64(source.sampleCount), confidence: 1)]
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
func micCaptureStopFinalizesSpeechThroughTheLastPartialDiarizationWindow(sampleRate: Double) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(applicationSupportURL: root.appending(path: "support"),
        cacheURL: root.appending(path: "cache"), sessionsRootOverride: root.appending(path: "sessions"))
    let sessionID = UUID()
    let url = try SessionBootstrapper(fileManager: .default).createSession(paths: paths,
        sessionID: sessionID, source: .recording(.microphone), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        timeZone: TimeZone(secondsFromGMT: 0)!)
    let layout = SessionLayout(sessionURL: url)
    let processor = NativeSessionProcessor(paths: paths,
        engines: SessionProcessingEngines(asr: TailASR(), diarization: TailWindowDiarizer(), finalTranscriptVAD: TailVAD()),
        audioHandling: MacSessionProcessingAudio(),
        contentPriority: .disabled,
        sleep: { _ in })
    let liveRun = "seg_live_tail"
    _ = try await processor.startLiveTranscription(sessionID: sessionID, segmentationRunID: liveRun, sampleRate: 16_000)
    let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 0.5, sessionURL: layout.sessionURL)
    let ring = AudioBlockRing(capacity: 4, blockFrameCapacity: 4096, sampleRate: sampleRate)
    let drain = AudioCaptureDrain(ring: ring, writer: writer, converter: try CanonicalAudioResampler(sampleRate: sampleRate))
    let totalDeviceFrames = Int(107.25 * sampleRate)
    var offset = 0
    var liveSplitDelivered = false
    var block = [Float](repeating: 0, count: 4096)
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
                    startFrame: speechStart, endFrame: 104 * 16_000)], checkpoint: checkpoint,
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
            startFrame: 104 * 16_000, endFrame: checkpoint.committedFrames)], pacingMode: .normal,
        shouldPause: { false }, onPhase: { _ in }, onStatus: { _ in }, onUpdate: { _, _ in })
    #expect(result.disposition == .completed, "\(result.message ?? "no failure message")")
    let metadata = try #require(try ProcessingMetadataStore(sessionURL: url).load())
    #expect(metadata.finalizationAttempt?.state == .complete)
    let activeRuns = try #require(metadata.activeRuns)
    let lines = try SessionRecovery.recoverJSONL(Data(contentsOf: layout.eventsURL)).lines
    let events = try EventLogTranscriptReader().events(lines: lines, activeRuns: activeRuns)
    let transcript = try TranscriptMaterializer(sampleRate: 16_000).materialize(events: events, activeRuns: activeRuns)
    #expect(transcript.map(\.text) == ["末尾の発話", "末尾の発話"])
    #expect(transcript.count == 2)
    let firstTranscript = try #require(transcript.first)
    let secondTranscript = try #require(transcript.dropFirst().first)
    #expect(firstTranscript.startMilliseconds == 90_000)
    #expect(secondTranscript.endMilliseconds == 107_250)
    #expect(firstTranscript.endMilliseconds == secondTranscript.startMilliseconds)
    #expect((102_000...104_000).contains(firstTranscript.endMilliseconds))

    let createdRanges = try lines.compactMap { line -> (startFrame: Int64, endFrame: Int64)? in
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["event_type"] as? String == "segment.created",
              object["segmentation_run_id"] as? String == activeRuns.segmentation,
              let startFrame = (object["source_start_frame"] as? NSNumber)?.int64Value,
              let endFrame = (object["source_end_frame"] as? NSNumber)?.int64Value else {
            return nil
        }
        return (startFrame, endFrame)
    }
    #expect(createdRanges.count == 2)
    let firstCreatedRange = try #require(createdRanges.first)
    let secondCreatedRange = try #require(createdRanges.dropFirst().first)
    #expect(firstCreatedRange.startFrame == speechStart)
    #expect(secondCreatedRange.startFrame == firstCreatedRange.endFrame)
    #expect(secondCreatedRange.endFrame == checkpoint.committedFrames)
    #expect((speechStart + 192_000...speechStart + 224_000).contains(firstCreatedRange.endFrame))

    guard case .recordingFLAC(let info) = try SessionAudioStorageStore(layout: layout).load() else {
        Issue.record("Finalized recording must be compacted to FLAC")
        return
    }
    #expect(info.committedFrames == checkpoint.committedFrames)
    #expect(!FileManager.default.fileExists(atPath: layout.processingDirectory.path))
}
