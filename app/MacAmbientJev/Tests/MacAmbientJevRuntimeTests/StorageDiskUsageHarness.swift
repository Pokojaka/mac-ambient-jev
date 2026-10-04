import AVFoundation
import Foundation
import MacAmbientJevAppleSupport
import MacAmbientJevCore
import MacAmbientJevRuntime
import Testing

private let storageHarnessProvenance = RunProvenance(
    engine: "storage-harness", model: nil, version: "1", configuration: [:]
)

private struct StorageHarnessVAD: FinalTranscriptVADSegmenter {
    let provenance = storageHarnessProvenance

    func segment(reader: ProcessingTimelineReader, runID: String) async throws -> [SegmentReference] {
        try reader.validateChunkFiles()
        return [SegmentReference(
            segmentationRunID: runID, segmentID: "synthetic-speech",
            startFrame: 0, endFrame: Int64(reader.checkpoint.sampleRate)
        )]
    }
}

private struct StorageHarnessDiarizer: DiarizationEngine {
    let provenance = storageHarnessProvenance
    func prepare() async throws {}
    func unload() async {}

    func diarize(fileURL: URL, canonicalSampleRate: Double) async throws -> [SpeakerSpan] {
        let file = try AVAudioFile(forReading: fileURL)
        guard file.processingFormat.sampleRate == canonicalSampleRate, file.length > 0 else {
            throw StorageHarnessError.invalidAudio
        }
        return [SpeakerSpan(
            speakerID: "synthetic-speaker", startFrame: 0,
            endFrame: Int64(canonicalSampleRate), confidence: 1
        )]
    }
}

private struct StorageHarnessASR: ASREngine {
    let provenance = storageHarnessProvenance
    func prepare() async throws {}
    func unload() async {}
    func transcribe(_ input: ASRAudioInput) async throws -> ASRResult {
        guard input.samples.count == input.sampleRate else { throw StorageHarnessError.invalidAudio }
        return ASRResult(text: "保存容量の合成計測", detectedLanguage: "ja")
    }
}

private enum StorageHarnessError: Error {
    case missingConfiguration
    case invalidAudio
    case finalizationFailed(String?)
    case catalogUnreadable
}

private func storageHarnessBytes(_ directory: URL) throws -> Int64 {
    var enumerationFailure: Error?
    guard let files = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [], errorHandler: { _, error in
            enumerationFailure = error
            return false
        }
    ) else { throw StorageHarnessError.catalogUnreadable }
    var total: Int64 = 0
    while let url = files.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values.isRegularFile == true {
            guard let bytes = values.fileSize else { throw StorageHarnessError.catalogUnreadable }
            total += Int64(bytes)
        }
    }
    if let enumerationFailure { throw enumerationFailure }
    return total
}

/// Opt-in measurement, not a compression-ratio or recognition-quality test.
/// Engines are injected; the durable writer, import builder, finalization and export are real.
@Test(.enabled(if: ProcessInfo.processInfo.environment["STORAGE_HARNESS_ROOT"] != nil))
func storageDiskUsageHarness() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let rootPath = environment["STORAGE_HARNESS_ROOT"],
          let secondsText = environment["STORAGE_HARNESS_SECONDS"],
          let seconds = Int(secondsText), seconds > 0 else {
        throw StorageHarnessError.missingConfiguration
    }
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let paths = AppPaths(
        applicationSupportURL: root.appending(path: "support"),
        cacheURL: root.appending(path: "cache"),
        sessionsRootOverride: root.appending(path: "sessions")
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "synthetic-stereo.caf")
    let sourceFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let sourceFile = try AVAudioFile(forWriting: source, settings: sourceFormat.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 48_000))
    buffer.frameLength = 48_000
    let channels = try #require(buffer.floatChannelData)

    let recordingID = UUID()
    let recordingURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: recordingID, source: .recording(.systemAudio),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let writer = try DurableAudioWriter(
        directory: SessionLayout(sessionURL: recordingURL).processingDirectory,
        sampleRate: 48_000, channelCount: 1, chunkDurationSeconds: 0.5
    )
    // Deterministic amplitude-modulated, low-pass noise; not a human speech corpus.
    var randomState: UInt64 = 0x501_16_48
    var filtered: Float = 0
    var mono = [Float](repeating: 0, count: 48_000)
    for second in 0..<seconds {
        for frame in 0..<48_000 {
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
            let noise = Float(Int32(bitPattern: UInt32(truncatingIfNeeded: randomState >> 32))) / Float(Int32.max)
            filtered = 0.85 * filtered + 0.15 * noise
            let amplitude: Float = second % 5 == 4 ? 0.002 : 0.3
            let sample = amplitude * filtered
            channels[0][frame] = sample
            channels[1][frame] = sample * 0.8
            mono[frame] = sample * 0.9
        }
        try sourceFile.write(from: buffer)
        try await writer.append(samples: mono)
    }
    sourceFile.close()
    let checkpoint = try await writer.finish()
    let recordingDuring = try storageHarnessBytes(recordingURL)
    let processor = NativeSessionProcessor(
        paths: paths,
        engines: SessionProcessingEngines(
            asr: StorageHarnessASR(), diarization: StorageHarnessDiarizer(),
            finalTranscriptVAD: StorageHarnessVAD()
        ),
        contentPriority: .disabled
    )
    let recordingResult = await processor.processFinalTranscript(
        sessionID: recordingID, checkpoint: checkpoint, pacingMode: .normal,
        shouldPause: { false }, onPhase: { _ in }, metadataPolicy: .reject,
        onStatus: { _ in }, onUpdate: { _, _ in }
    )
    guard recordingResult.disposition == .completed else {
        throw StorageHarnessError.finalizationFailed(recordingResult.message)
    }
    let recordingAfter = try storageHarnessBytes(recordingURL)

    let importID = UUID()
    let importURL = try SessionBootstrapper(fileManager: .default).createSession(
        paths: paths, sessionID: importID, source: .imported(originalFilename: source.lastPathComponent),
        createdAt: Date(timeIntervalSince1970: 1_700_000_001), timeZone: TimeZone(secondsFromGMT: 0)!
    )
    let original = try AudioImporter().importFile(source, into: importURL).originalURL
    // Snapshot the same import timeline that finalization builds from the original.
    _ = try await AudioFileTimelineBuilder().build(
        from: original, into: SessionLayout(sessionURL: importURL).processingDirectory
    )
    let importDuring = try storageHarnessBytes(importURL)
    let importResult = await processor.processImportedSession(
        sessionID: importID, originalURL: original, pacingMode: .normal,
        shouldPause: { false }, onPhase: { _ in }, metadataPolicy: .reject,
        onStatus: { _ in }, onUpdate: { _, _ in }
    )
    guard importResult.disposition == .completed else {
        throw StorageHarnessError.finalizationFailed(importResult.message)
    }
    let importAfter = try storageHarnessBytes(importURL)
    let exportRoot = root.appending(path: "exports")
    try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
    var exportSizes: [UUID: Int64] = [:]
    for row in try SavedSessionCatalog(fileManager: .default).list(sessionsRoot: paths.sessionsRoot) {
        guard case .readable(let session) = row else { throw StorageHarnessError.catalogUnreadable }
        let exported = try SessionExporter().export(session: session, to: exportRoot)
        exportSizes[session.sessionID] = try storageHarnessBytes(exported)
    }
    let report: [String: Any] = [
        "duration_seconds": seconds,
        "fixture": "48-kHz stereo float32 CAF; seeded low-pass noise; injected engines",
        "byte_measure": "sum of logical regular-file lengths, including metadata",
        "recording": [
            "session_path": recordingURL.path,
            "during_recording_bytes": recordingDuring,
            "after_finalization_bytes": recordingAfter,
            "export_bytes": try #require(exportSizes[recordingID]),
        ],
        "import": [
            "session_path": importURL.path,
            "processing_timeline_ready_bytes": importDuring,
            "after_finalization_bytes": importAfter,
            "export_bytes": try #require(exportSizes[importID]),
        ],
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appending(path: "disk-usage.json"), options: .atomic)
}
