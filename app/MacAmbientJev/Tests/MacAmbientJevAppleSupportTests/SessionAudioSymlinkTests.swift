import AVFoundation
import Foundation
import MacAmbientJevPipeline
import Testing
@testable import MacAmbientJevAppleSupport
@testable import MacAmbientJevCore

private struct SecureAudioFixture {
    let root: URL
    let layout: SessionLayout
    let outside: URL
    let sentinel: URL
    let original = Data("outside audio sentinel".utf8)

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        layout = SessionLayout(sessionURL: root.appending(path: "session"))
        outside = root.appending(path: "outside")
        sentinel = outside.appending(path: "sentinel.caf")
        try FileManager.default.createDirectory(at: layout.sessionURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try original.write(to: sentinel)
    }

    func pcm() async throws -> ProcessingTimelineReader {
        let writer = try DurableAudioWriter(directory: layout.processingDirectory, chunkDurationSeconds: 1, sessionURL: layout.sessionURL)
        try await writer.append(samples: [0.25, -0.5, 0.75])
        return try ProcessingTimelineReader(directory: layout.processingDirectory, checkpoint: await writer.finish(), sessionURL: layout.sessionURL)
    }

    func link(_ url: URL, to target: URL? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target ?? sentinel)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func retainedAudioReaderAndEncoderRefuseLeafSymlinks() async throws {
    let fixture = try SecureAudioFixture()
    defer { fixture.cleanup() }
    let pcm = try await fixture.pcm()
    try fixture.link(fixture.layout.recordingFLACURL)
    try fixture.link(fixture.layout.recordingFLACPartialURL)
    #expect(throws: CocoaError.self) {
        _ = try FLACTimelineReader(url: fixture.layout.recordingFLACURL, info: pcm.info, sessionURL: fixture.layout.sessionURL)
    }
    #expect(throws: CocoaError.self) {
        try RecordingFLAC.write(reader: pcm, to: fixture.layout.recordingFLACPartialURL, sessionURL: fixture.layout.sessionURL)
    }
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
}

@Test func importDecoderRejectsLinkedOriginalBeforeRemovingProcessingAudio() async throws {
    let fixture = try SecureAudioFixture()
    defer { fixture.cleanup() }
    let pcm = try await fixture.pcm()
    let originalURL = fixture.layout.audioDirectory.appending(path: "original.caf")
    try fixture.link(originalURL)
    await #expect(throws: CocoaError.self) {
        try await AudioFileTimelineBuilder().build(from: originalURL, into: fixture.layout.processingDirectory, sessionURL: fixture.layout.sessionURL)
    }
    #expect(try pcm.readSamples(frameRange: 0..<3) == [0.25, -0.5, 0.75])
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
}

@Test func derivedAudioPublicationRejectsLinkedDestination() async throws {
    let fixture = try SecureAudioFixture()
    defer { fixture.cleanup() }
    let pcm = try await fixture.pcm()
    try fixture.link(fixture.layout.diarizationInputURL)
    #expect(throws: CocoaError.self) {
        try ProcessingTimelineAudioExporter(framesPerBuffer: 2).export(reader: pcm, to: fixture.layout.diarizationInputURL, sessionURL: fixture.layout.sessionURL)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.layout.derivedDirectory.path) == [fixture.layout.diarizationInputURL.lastPathComponent])
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
}

@Test func audioReadersAndDerivedWriterRejectLinkedAudioParent() async throws {
    let fixture = try SecureAudioFixture()
    defer { fixture.cleanup() }
    let pcm = try await fixture.pcm()
    try FileManager.default.moveItem(at: fixture.layout.audioDirectory, to: fixture.layout.sessionURL.appending(path: "retained-audio"))
    try fixture.link(fixture.layout.audioDirectory, to: fixture.outside)
    #expect(throws: CocoaError.self) { _ = try SessionAudioReaders.open(.recordedPCM(pcm.checkpoint), layout: fixture.layout) }
    #expect(throws: CocoaError.self) {
        _ = try FLACTimelineReader(url: fixture.layout.recordingFLACURL, info: pcm.info, sessionURL: fixture.layout.sessionURL)
    }
    #expect(throws: CocoaError.self) {
        try ProcessingTimelineAudioExporter(framesPerBuffer: 2).export(reader: pcm, to: fixture.layout.diarizationInputURL, sessionURL: fixture.layout.sessionURL)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outside.path) == [fixture.sentinel.lastPathComponent])
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
}

@Test func descriptorDecoderKeepsOpenedCAFWhenPathIsReplaced() async throws {
    let fixture = try SecureAudioFixture()
    defer { fixture.cleanup() }
    let pcm = try await fixture.pcm()
    let url = fixture.layout.diarizationInputURL
    try ProcessingTimelineAudioExporter(framesPerBuffer: 2).export(reader: pcm, to: url, sessionURL: fixture.layout.sessionURL)
    let reader = try DescriptorAudioReader(url: url, sessionURL: fixture.layout.sessionURL)
    let retained = fixture.layout.derivedDirectory.appending(path: "retained.caf")
    try FileManager.default.moveItem(at: url, to: retained)
    try fixture.link(url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 3))
    try reader.read(into: buffer, frameCount: 3)
    #expect(buffer.frameLength == 3)
    let samples = try #require(buffer.floatChannelData?[0])
    #expect(Array(UnsafeBufferPointer(start: samples, count: 3)) == [0.25, -0.5, 0.75])
    #expect(try Data(contentsOf: fixture.sentinel) == fixture.original)
    #expect(throws: CocoaError.self) { _ = try DescriptorAudioReader(url: url, sessionURL: fixture.layout.sessionURL) }
}
