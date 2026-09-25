import AVFoundation
import Dispatch
import Darwin
import Foundation
import MacAmbientJevCore
import MacAmbientJevRuntime

private enum ReplayError: LocalizedError {
    case usage
    case invalidOption(String)
    case invalidFormat
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            """
            usage: MacAmbientJevMeasureLiveLatency [--sample-rate HZ] [--channels COUNT] [--match-default-input] <existing-audio-file>
              Default: preserve the file's processing sample rate and channel count.
              --match-default-input: read the default input device's activeFormat only; no capture starts.
            """
        case .invalidOption(let option): "Invalid option: \(option)"
        case .invalidFormat: "Audio input or output format is not supported."
        case .modelUnavailable(let path): "Required cached model is missing: \(path)"
        }
    }
}

private struct Options {
    let sourceURL: URL
    var sampleRate: Double?
    var channelCount: Int?
    var matchDefaultInput = false

    static func parse(_ arguments: [String]) throws -> Options {
        var result = Options(sourceURL: URL(fileURLWithPath: "/"))
        var positional: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--sample-rate":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value > 0 else {
                    throw ReplayError.invalidOption(argument)
                }
                result.sampleRate = value
            case "--channels":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), (1...32).contains(value) else {
                    throw ReplayError.invalidOption(argument)
                }
                result.channelCount = value
            case "--match-default-input":
                result.matchDefaultInput = true
            case "--help", "-h":
                FileHandle.standardOutput.write(Data("\(ReplayError.usage.localizedDescription)\n".utf8))
                exit(0)
            default:
                if argument.hasPrefix("-") { throw ReplayError.invalidOption(argument) }
                positional.append(argument)
            }
            index += 1
        }
        guard positional.count == 1,
              !(result.matchDefaultInput && (result.sampleRate != nil || result.channelCount != nil)) else {
            throw ReplayError.usage
        }
        result = Options(
            sourceURL: URL(fileURLWithPath: positional[0]).standardizedFileURL,
            sampleRate: result.sampleRate,
            channelCount: result.channelCount,
            matchDefaultInput: result.matchDefaultInput
        )
        return result
    }
}

private struct FormatDescription {
    let sampleRate: Double
    let channelCount: Int
    let source: String
}

private struct LatencyRecord: Sendable {
    let segmentID: String
    let endSpeechFrame: Int64
    let endSpeechSeconds: Double
    let firstUpdateSeconds: Double
}

private actor MeasurementCollector {
    private var vadFramesBySegment: [String: (start: Int64, end: Int64)] = [:]
    private var firstUpdateBySegment: [String: Double] = [:]
    private var latestTexts: [String: String] = [:]
    private var finalSegmentsByID: [String: MaterializedTranscriptSegment] = [:]
    private var finalProcessingState: String?
    private let clockStart: UInt64

    init(clockStart: UInt64) { self.clockStart = clockStart }

    func register(_ segments: [SegmentReference]) {
        for segment in segments {
            vadFramesBySegment[segment.segmentID] = (segment.startFrame, segment.endFrame)
        }
    }

    func update(_ segments: [MaterializedTranscriptSegment]) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now >= clockStart ? now - clockStart : 0) / 1_000_000_000
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            latestTexts[segment.segmentID] = text
            if firstUpdateBySegment[segment.segmentID] == nil {
                firstUpdateBySegment[segment.segmentID] = elapsed
            }
        }
    }

    func recordFinalUpdate(_ segments: [MaterializedTranscriptSegment], state: ProcessingState) {
        switch state {
        case .complete:
            finalProcessingState = "complete"
        case .partialFailure(let message):
            finalProcessingState = "partialFailure: \(message)"
        case .idle, .running, .backlogged:
            return
        }
        finalSegmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.segmentID, $0) })
    }

    func results(sampleRate: Double) -> (
        records: [LatencyRecord],
        missing: [String],
        texts: [String: String],
        vadFrames: [String: (start: Int64, end: Int64)],
        finalSegments: [MaterializedTranscriptSegment],
        finalState: String?
    ) {
        let ids = vadFramesBySegment.keys.sorted()
        let records = ids.compactMap { id -> LatencyRecord? in
            guard let frames = vadFramesBySegment[id], let update = firstUpdateBySegment[id] else { return nil }
            return LatencyRecord(
                segmentID: id,
                endSpeechFrame: frames.end,
                endSpeechSeconds: Double(frames.end) / sampleRate,
                firstUpdateSeconds: update
            )
        }
        let missing = ids.filter { firstUpdateBySegment[$0] == nil }
        let finalSegments = finalSegmentsByID.values.sorted { $0.segmentID < $1.segmentID }
        return (records, missing, latestTexts, vadFramesBySegment, finalSegments, finalProcessingState)
    }
}

@main
struct MeasureLiveLatencyCommand {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            if case ReplayError.usage = error { exit(2) }
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        let paths = AppPaths.systemDefault()
        let fileManager = FileManager.default
        let qwenDirectory = ModelStore(paths: paths).qwen3ASRCacheRoot
        guard fileManager.fileExists(atPath: qwenDirectory.appending(path: "model.safetensors").path) else {
            throw ReplayError.modelUnavailable(qwenDirectory.path)
        }
        let vadModel = paths.applicationSupportURL
            .appending(path: "FluidAudio/Models/silero-vad/silero-vad-unified-256ms-v6.2.1.mlmodelc")
        guard fileManager.fileExists(atPath: vadModel.path) else {
            throw ReplayError.modelUnavailable(vadModel.path)
        }

        let sourceInfo = try options.sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let sourceFile = try AVAudioFile(
            forReading: options.sourceURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let sourceFormat = sourceFile.processingFormat
        let target = try outputFormat(options: options, sourceFormat: sourceFormat)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0,
              target.sampleRate > 0, target.channelCount > 0 else { throw ReplayError.invalidFormat }
        let sourceDuration = Double(sourceFile.length) / sourceFormat.sampleRate

        let sessionID = UUID()
        let sessionsRoot = URL(fileURLWithPath: "/private/tmp/mac-ambient-jev-live-latency", isDirectory: true)
            .appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        let sessionDirectory = sessionsRoot.appending(path: sessionID.uuidString, directoryHint: .isDirectory)
        let processingDirectory = sessionDirectory
            .appending(path: "audio", directoryHint: .isDirectory)
            .appending(path: "processing", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let writer = try DurableAudioWriter(
            directory: processingDirectory,
            sampleRate: target.sampleRate,
            channelCount: Int(target.channelCount),
            chunkDurationSeconds: LiveTranscriptionCadence.durableChunkDurationSeconds
        )
        var checkpoint = try await writer.checkpoint()
        let processor = NativeSessionProcessor(paths: paths, sessionsRoot: sessionsRoot)
        try await processor.prepareASR { progress, message in
            FileHandle.standardError.write(Data("ASR model \(Int(progress * 100))%: \(message)\n".utf8))
        }
        let segmentationRunID = "seg_live_\(UUID().uuidString.lowercased())"
        _ = try await processor.startLiveTranscription(
            sessionID: sessionID,
            segmentationRunID: segmentationRunID,
            sampleRate: target.sampleRate
        )
        let vadSession = try await LiveVADSession.make(
            processingDirectory: processingDirectory,
            initialCheckpoint: checkpoint
        )

        let started = DispatchTime.now().uptimeNanoseconds
        let collector = MeasurementCollector(clockStart: started)
        let state = ReplayInputState()
        let producer = Task {
            do {
                let finalCheckpoint = try await feedAudio(
                    options.sourceURL,
                    sourceFormat: sourceFormat,
                    targetFormat: target,
                    into: writer
                )
                await state.finish()
                return finalCheckpoint
            } catch {
                await state.finish()
                throw error
            }
        }

        var pollCount = 0
        var processedFrames: Int64 = 0
        while !(await state.hasFinished()) {
            try await Task.sleep(for: .milliseconds(LiveTranscriptionCadence.checkpointPollIntervalMilliseconds))
            pollCount += 1
            let committed = await writer.committedSnapshot()
            if committed.committedFrames > processedFrames {
                checkpoint = committed
                let progress = try await vadSession.processAvailable(checkpoint: checkpoint)
                if !progress.emittedSegments.isEmpty {
                    await collector.register(progress.emittedSegments)
                    _ = try await processor.processLiveSegments(
                        sessionID: sessionID,
                        segments: progress.emittedSegments,
                        checkpoint: checkpoint,
                        onUpdate: { segments, _ in await collector.update(segments) }
                    )
                }
                processedFrames = checkpoint.committedFrames
            }
        }

        checkpoint = try await producer.value
        if checkpoint.committedFrames > processedFrames {
            let progress = try await vadSession.processAvailable(checkpoint: checkpoint)
            if !progress.emittedSegments.isEmpty {
                await collector.register(progress.emittedSegments)
                _ = try await processor.processLiveSegments(
                    sessionID: sessionID,
                    segments: progress.emittedSegments,
                    checkpoint: checkpoint,
                    onUpdate: { segments, _ in await collector.update(segments) }
                )
            }
        }
        let finalVAD = try await vadSession.finish(checkpoint: checkpoint)
        if !finalVAD.emittedSegments.isEmpty {
            await collector.register(finalVAD.emittedSegments)
            _ = try await processor.processLiveSegments(
                sessionID: sessionID,
                segments: finalVAD.emittedSegments,
                checkpoint: checkpoint,
                onUpdate: { segments, _ in await collector.update(segments) }
            )
        }
        let finalResult = await processor.finishLiveTranscription(
            sessionID: sessionID,
            checkpoint: checkpoint,
            onUpdate: { segments, state in
                await collector.update(segments)
                await collector.recordFinalUpdate(segments, state: state)
            }
        )
        let collected = await collector.results(sampleRate: target.sampleRate)
        let latencies = collected.records.map { $0.firstUpdateSeconds - $0.endSpeechSeconds }.sorted()
        let finalSegmentByID = Dictionary(uniqueKeysWithValues: collected.finalSegments.map { ($0.segmentID, $0) })
        let finalSpeakerLabels = speakerLabels(for: collected.finalSegments)
        let finalSegments: [[String: Any]] = collected.finalSegments.map { segment in
            let speakers: [[String: Any]] = segment.speakers.map { span in
                [
                    "speaker_id": span.id,
                    "display_label": span.displayLabel ?? SpeakerDisplayMapper.label(for: span.id, labels: finalSpeakerLabels),
                    "start_ms": span.startMilliseconds,
                    "end_ms": span.endMilliseconds,
                    "confidence": span.confidence as Any? ?? NSNull()
                ]
            }
            return [
                "segment_id": segment.segmentID,
                "start_ms": segment.startMilliseconds,
                "end_ms": segment.endMilliseconds,
                "text": segment.text,
                "speaker_spans": speakers,
                "display_speaker_label": speakerLabel(for: segment, labels: finalSpeakerLabels)
            ]
        }
        let latencySamples: [[String: Any]] = collected.records.map { record in
            [
                "segment_id": record.segmentID,
                "vad_end_frame": record.endSpeechFrame,
                "end_of_speech_seconds": record.endSpeechSeconds,
                "first_update_seconds": record.firstUpdateSeconds,
                "latency_seconds": record.firstUpdateSeconds - record.endSpeechSeconds
            ]
        }
        let vadSegments: [[String: Any]] = collected.vadFrames.keys.sorted().map { segmentID in
            guard let frames = collected.vadFrames[segmentID] else { return [:] }
            let finalSegment = finalSegmentByID[segmentID]
            let speakers: [[String: Any]] = (finalSegment?.speakers ?? []).map { span in
                [
                    "speaker_id": span.id,
                    "display_label": span.displayLabel ?? SpeakerDisplayMapper.label(for: span.id, labels: finalSpeakerLabels),
                    "start_ms": span.startMilliseconds,
                    "end_ms": span.endMilliseconds,
                    "confidence": span.confidence as Any? ?? NSNull()
                ]
            }
            return [
                "segment_id": segmentID,
                "vad_start_frame": frames.start,
                "vad_end_frame": frames.end,
                "final_start_ms": finalSegment?.startMilliseconds as Any? ?? NSNull(),
                "final_end_ms": finalSegment?.endMilliseconds as Any? ?? NSNull(),
                "final_text": finalSegment?.text as Any? ?? NSNull(),
                "speaker_spans": speakers,
                "display_speaker_label": finalSegment.map { speakerLabel(for: $0, labels: finalSpeakerLabels) } as Any? ?? NSNull()
            ]
        }
        let output: [String: Any] = [
            "measurement_scope": "end_of_vad_speech_to_first_nonempty_view_model_update",
            "source": options.sourceURL.path,
            "source_bytes": sourceInfo.fileSize as Any? ?? NSNull(),
            "source_duration_seconds": sourceDuration,
            "source_sample_rate_hz": sourceFormat.sampleRate,
            "source_channels": Int(sourceFormat.channelCount),
            "processing_sample_rate_hz": target.sampleRate,
            "processing_channels": Int(target.channelCount),
            "processing_format_source": targetFormatSource(options: options),
            "microphone_capture_started": false,
            "frame_count": checkpoint.committedFrames,
            "timeline_duration_seconds": Double(checkpoint.committedFrames) / checkpoint.sampleRate,
            "checkpoint_poll_count": pollCount,
            "segment_count": collected.records.count + collected.missing.count,
            "updated_count": collected.records.count,
            "missing_count": collected.missing.count,
            "latency_sample_count": latencies.count,
            "latency_sample_basis": "segments_with_nonempty_view_model_update",
            "missing_segment_ids": collected.missing,
            "latency_samples_seconds": latencies,
            "latency_samples": latencySamples,
            "final_processing_state": collected.finalState as Any? ?? NSNull(),
            "final_segments": finalSegments,
            "vad_segments": vadSegments,
            "p50_seconds": percentile(latencies, 0.50) as Any? ?? NSNull(),
            "p95_seconds": percentile(latencies, 0.95) as Any? ?? NSNull(),
            "maximum_seconds": latencies.last as Any? ?? NSNull(),
            "final_processing_result": String(describing: finalResult),
            "transcripts": collected.texts
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        try? fileManager.removeItem(at: sessionsRoot)
    }

    private static func outputFormat(options: Options, sourceFormat: AVAudioFormat) throws -> AVAudioFormat {
        var sampleRate = options.sampleRate ?? sourceFormat.sampleRate
        var channels = options.channelCount ?? Int(sourceFormat.channelCount)
        if options.matchDefaultInput {
            guard let device = AVCaptureDevice.default(for: .audio),
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee,
                  stream.mSampleRate > 0, stream.mChannelsPerFrame > 0 else { throw ReplayError.invalidFormat }
            sampleRate = stream.mSampleRate
            channels = Int(stream.mChannelsPerFrame)
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else { throw ReplayError.invalidFormat }
        return format
    }

    private static func targetFormatSource(options: Options) -> String {
        if options.matchDefaultInput { return "read_only_default_input_active_format" }
        if options.sampleRate != nil || options.channelCount != nil { return "explicit_options" }
        return "source_file_processing_format"
    }

    private static func percentile(_ sorted: [Double], _ quantile: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = Int((Double(sorted.count - 1) * quantile).rounded(.up))
        return sorted[min(sorted.count - 1, index)]
    }

    private static func speakerLabels(
        for segments: [MaterializedTranscriptSegment]
    ) -> [String: String] {
        SpeakerDisplayMapper.makeLabels(spans: segments.flatMap(\.speakers).map { span in
            SpeakerSpan(
                speakerID: span.id,
                startFrame: span.startMilliseconds,
                endFrame: span.endMilliseconds,
                confidence: span.confidence
            )
        })
    }

    private static func speakerLabel(
        for segment: MaterializedTranscriptSegment,
        labels: [String: String]
    ) -> String {
        var overlapBySpeaker: [String: Int64] = [:]
        for span in segment.speakers {
            let overlap = max(
                0,
                min(segment.endMilliseconds, span.endMilliseconds)
                    - max(segment.startMilliseconds, span.startMilliseconds)
            )
            if overlap > 0 { overlapBySpeaker[span.id, default: 0] += overlap }
        }
        let total = overlapBySpeaker.values.reduce(Int64.zero, +)
        guard total > 0 else { return "話者不明" }
        guard let dominant = overlapBySpeaker.max(by: { $0.value < $1.value }) else {
            return "話者不明"
        }
        if Double(dominant.value) / Double(total) >= 0.8 {
            return segment.speakers.first(where: { $0.id == dominant.key })?.displayLabel
                ?? SpeakerDisplayMapper.label(for: dominant.key, labels: labels)
        }
        return overlapBySpeaker.count > 1 ? "複数話者" : "話者不明"
    }

    private static func feedAudio(
        _ sourceURL: URL,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        into writer: DurableAudioWriter
    ) async throws -> AudioCheckpoint {
        let audioFile = try AVAudioFile(forReading: sourceURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        let sourceCapacity = AVAudioFrameCount(max(1, Int((sourceFormat.sampleRate * 0.5).rounded())))
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceCapacity) else {
            throw ReplayError.invalidFormat
        }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(max(1024, Int((Double(sourceCapacity) * ratio).rounded()) + 1024))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw ReplayError.invalidFormat
        }

        while audioFile.framePosition < audioFile.length {
            let requested = AVAudioFrameCount(min(Int64(sourceCapacity), audioFile.length - audioFile.framePosition))
            sourceBuffer.frameLength = 0
            try audioFile.read(into: sourceBuffer, frameCount: requested)
            guard sourceBuffer.frameLength > 0 else { break }
            let converted: AVAudioPCMBuffer
            let needsConversion = sourceFormat.sampleRate != targetFormat.sampleRate
                || sourceFormat.channelCount != targetFormat.channelCount
            if let converter, needsConversion {
                outputBuffer.frameLength = 0
                var supplied = false
                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                    if supplied {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    inputStatus.pointee = .haveData
                    return sourceBuffer
                }
                if let conversionError { throw conversionError }
                guard status != .error else { throw ReplayError.invalidFormat }
                converted = outputBuffer
            } else {
                converted = sourceBuffer
            }
            let frameCount = Int(converted.frameLength)
            guard frameCount > 0 else { continue }
            try await appendPaced(
                converted,
                targetFormat: targetFormat,
                into: writer
            )
        }

        if let converter {
            while true {
                outputBuffer.frameLength = 0
                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if let conversionError { throw conversionError }
                guard status != .error else { throw ReplayError.invalidFormat }
                if outputBuffer.frameLength > 0 {
                    try await appendPaced(
                        outputBuffer,
                        targetFormat: targetFormat,
                        into: writer
                    )
                }
                if status == .endOfStream || outputBuffer.frameLength == 0 { break }
            }
        }
        return try await writer.finish()
    }

    private static func appendPaced(
        _ buffer: AVAudioPCMBuffer,
        targetFormat: AVAudioFormat,
        into writer: DurableAudioWriter
    ) async throws {
        guard let channels = buffer.floatChannelData else { throw ReplayError.invalidFormat }
        let frameCount = Int(buffer.frameLength)
        var interleaved = Array(repeating: Float.zero, count: frameCount * Int(targetFormat.channelCount))
        for frame in 0..<frameCount {
            for channel in 0..<Int(targetFormat.channelCount) {
                interleaved[frame * Int(targetFormat.channelCount) + channel] = channels[channel][frame]
            }
        }
        let duration = Double(frameCount) / targetFormat.sampleRate
        try await Task.sleep(for: .nanoseconds(UInt64((duration * 1_000_000_000).rounded())))
        try await writer.append(samples: interleaved)
    }
}

private actor ReplayInputState {
    private var finished = false
    func finish() { finished = true }
    func hasFinished() -> Bool { finished }
}
