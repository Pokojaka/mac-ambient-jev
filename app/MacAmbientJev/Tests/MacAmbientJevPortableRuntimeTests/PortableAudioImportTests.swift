import Foundation
import Testing
import MacAmbientJevCore
import MacAmbientJevPortableRuntime

struct PortableAudioImportTests {
    @Test
    func storedOriginalBuilderDoesNotImportOrCopyAgain() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, named: "builder-session")
        let layout = SessionLayout(sessionURL: session)
        let source = root.appendingPathComponent("input.wav")
        let sourceSamples: [Int16] = [0, 16_384, -16_384, -32_768, 8_192]
        try writePCM16Wave(to: source, sampleRate: 16_000, channelCount: 1, samples: sourceSamples)
        let originalBytes = try Data(contentsOf: source)

        let imported = try AudioImporter().importFile(source, into: session)
        try FileManager.default.removeItem(at: source)

        let builder: any ImportedAudioTimelineBuilding = PortableImportedAudioTimelineBuilder()
        let checkpoint = try await builder.build(
            from: imported.originalURL,
            into: layout.processingDirectory,
            sessionURL: session
        )
        let reader = try ProcessingTimelineReader(
            directory: layout.processingDirectory,
            checkpoint: checkpoint,
            sessionURL: session
        )
        try assertCanonicalSamples(in: reader)
        #expect(try Data(contentsOf: imported.originalURL) == originalBytes)
        #expect(try originalFileNames(in: layout) == ["original.wav"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.path) == ["audio"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [session.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: layout.audioStorageURL.path))
        #expect(!FileManager.default.fileExists(atPath: session.appendingPathComponent("processing").path))
        #expect(FileManager.default.fileExists(atPath: layout.processingDirectory.path))

        try SessionTransientAudio.remove(
            layout: layout,
            source: .imported(originalFilename: "input.wav")
        )
        #expect(!FileManager.default.fileExists(atPath: layout.processingDirectory.path))

        let rebuiltCheckpoint = try await builder.build(
            from: imported.originalURL,
            into: layout.processingDirectory,
            sessionURL: session
        )
        let rebuiltReader = try ProcessingTimelineReader(
            directory: layout.processingDirectory,
            checkpoint: rebuiltCheckpoint,
            sessionURL: session
        )
        try assertCanonicalSamples(in: rebuiltReader)
        #expect(try Data(contentsOf: imported.originalURL) == originalBytes)
        #expect(try originalFileNames(in: layout) == ["original.wav"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.audioDirectory.path).sorted() == ["original.wav", "processing"])
        #expect(!FileManager.default.fileExists(atPath: layout.audioStorageURL.path))
        #expect(FileManager.default.fileExists(atPath: layout.processingDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: session.appendingPathComponent("processing").path))
    }

    @Test
    func storedOriginalBuilderReplacesExistingTimelineWithoutAppending() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, named: "replace-session")
        let layout = SessionLayout(sessionURL: session)
        let source = root.appendingPathComponent("input.wav")
        let sourceSamples: [Int16] = [0, 16_384, -16_384, -32_768, 8_192]
        try writePCM16Wave(to: source, sampleRate: 16_000, channelCount: 1, samples: sourceSamples)
        let originalBytes = try Data(contentsOf: source)
        let imported = try AudioImporter().importFile(source, into: session)
        try FileManager.default.removeItem(at: source)

        let existingWriter = try DurableAudioWriter(
            directory: layout.processingDirectory,
            chunkDurationSeconds: 5,
            sessionURL: session
        )
        try await existingWriter.append(samples: [-0.125, 0.375, -0.875])
        #expect(try await existingWriter.finish().committedFrames == 3)

        let builder: any ImportedAudioTimelineBuilding = PortableImportedAudioTimelineBuilder()
        let checkpoint = try await builder.build(
            from: imported.originalURL,
            into: layout.processingDirectory,
            sessionURL: session
        )
        #expect(checkpoint.committedFrames == 5)
        let reader = try ProcessingTimelineReader(
            directory: layout.processingDirectory,
            checkpoint: checkpoint,
            sessionURL: session
        )
        try assertCanonicalSamples(in: reader)

        let rebuiltCheckpoint = try await builder.build(
            from: imported.originalURL,
            into: layout.processingDirectory,
            sessionURL: session
        )
        #expect(rebuiltCheckpoint.committedFrames == 5)
        let rebuiltReader = try ProcessingTimelineReader(
            directory: layout.processingDirectory,
            checkpoint: rebuiltCheckpoint,
            sessionURL: session
        )
        try assertCanonicalSamples(in: rebuiltReader)
        #expect(try Data(contentsOf: imported.originalURL) == originalBytes)
        #expect(try originalFileNames(in: layout) == ["original.wav"])
    }

    @Test
    func portableImporterCopiesOnceAndUsesSessionLayout() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, named: "importer-session")
        let layout = SessionLayout(sessionURL: session)
        let source = root.appendingPathComponent("input.wav")
        let sourceSamples: [Int16] = [0, 16_384, -16_384, -32_768, 8_192]
        try writePCM16Wave(to: source, sampleRate: 16_000, channelCount: 1, samples: sourceSamples)
        let originalBytes = try Data(contentsOf: source)

        let reader = try await PortableAudioFileImporter.open(inputURL: source, sessionURL: session)

        try assertCanonicalSamples(in: reader)
        #expect(reader.directory == layout.processingDirectory)
        #expect(try Data(contentsOf: layout.audioDirectory.appendingPathComponent("original.wav")) == originalBytes)
        #expect(try originalFileNames(in: layout) == ["original.wav"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.audioDirectory.path).sorted() == ["original.wav", "processing"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: session.path) == ["audio"])
        #expect(try AudioCheckpoint.loadRecovered(from: layout.processingDirectory, relativeTo: session) == reader.checkpoint)
        #expect(FileManager.default.fileExists(atPath: layout.processingDirectory.appendingPathComponent(DurableAudioWriter.checkpointFilename).path))
        #expect(!FileManager.default.fileExists(atPath: session.appendingPathComponent("processing").path))
    }

    #if os(Linux)
    @Test(arguments: [(UInt32(48_000), UInt16(1)), (UInt32(16_000), UInt16(2))])
    func linuxBuilderRejectsNoncanonicalRateOrChannels(sampleRate: UInt32, channelCount: UInt16) async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, named: "noncanonical-session")
        let layout = SessionLayout(sessionURL: session)
        let source = root.appendingPathComponent("input.wav")
        let sourceSamples: [Int16] = channelCount == 1
            ? [1_024, -1_024, 2_048]
            : [1_024, -1_024, 2_048, -2_048]
        try writePCM16Wave(to: source, sampleRate: sampleRate, channelCount: channelCount, samples: sourceSamples)
        let originalBytes = try Data(contentsOf: source)
        let imported = try AudioImporter().importFile(source, into: session)
        let builder: any ImportedAudioTimelineBuilding = PortableImportedAudioTimelineBuilder()

        do {
            _ = try await builder.build(
                from: imported.originalURL,
                into: layout.processingDirectory,
                sessionURL: session
            )
            Issue.record("Expected noncanonical Linux audio to be rejected")
        } catch let error as PortableAudioImportError {
            #expect(error == .linuxRequiresCanonicalAudio(sampleRate: sampleRate, channels: UInt32(channelCount)))
            #expect(error.localizedDescription.contains("16 kHz・モノラル"))
        } catch {
            Issue.record("Expected linuxRequiresCanonicalAudio, received: \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: layout.processingDirectory.path))
        #expect(try Data(contentsOf: imported.originalURL) == originalBytes)
        #expect(try originalFileNames(in: layout) == ["original.wav"])
    }

    @Test
    func linuxBuilderRejectsUnsupportedExtensionBeforeCreatingTimeline() async throws {
        let root = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try makeSession(in: root, named: "unsupported-session")
        let layout = SessionLayout(sessionURL: session)
        let source = root.appendingPathComponent("input.ogg")
        try writePCM16Wave(to: source, sampleRate: 16_000, channelCount: 1, samples: [0, 8_192, -8_192])
        let originalBytes = try Data(contentsOf: source)
        let imported = try AudioImporter().importFile(source, into: session)
        let builder: any ImportedAudioTimelineBuilding = PortableImportedAudioTimelineBuilder()

        do {
            _ = try await builder.build(
                from: imported.originalURL,
                into: layout.processingDirectory,
                sessionURL: session
            )
            Issue.record("Expected unsupported Linux extension to be rejected")
        } catch let error as PortableAudioImportError {
            #expect(error == .unsupportedLinuxExtension("ogg"))
        } catch {
            Issue.record("Expected unsupportedLinuxExtension, received: \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: layout.processingDirectory.path))
        #expect(try Data(contentsOf: imported.originalURL) == originalBytes)
        #expect(try originalFileNames(in: layout) == ["original.ogg"])
    }
    #endif

    private func assertCanonicalSamples(in reader: ProcessingTimelineReader) throws {
        #expect(reader.info.committedFrames == 5)
        #expect(reader.info.sampleRate == 16_000)
        #expect(reader.info.channelCount == 1)
        #expect(try reader.readSamples(frameRange: 0..<5) == [0, 0.5, -0.5, -1, 0.25])
    }

    private func originalFileNames(in layout: SessionLayout) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: layout.audioDirectory.path)
            .filter { $0 == "original" || $0.hasPrefix("original.") }
            .sorted()
    }

    private func makeScratchRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacAmbientJevPortableAudioImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func makeSession(in root: URL, named name: String) throws -> URL {
        let session = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
        return session
    }

    private func writePCM16Wave(
        to url: URL,
        sampleRate: UInt32,
        channelCount: UInt16,
        samples: [Int16]
    ) throws {
        guard channelCount > 0, !samples.isEmpty, samples.count % Int(channelCount) == 0 else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let payloadBytes = UInt32(samples.count * MemoryLayout<Int16>.size)
        let blockAlign = channelCount * UInt16(MemoryLayout<Int16>.size)
        let byteRate = sampleRate * UInt32(blockAlign)
        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(36 + payloadBytes, to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(channelCount, to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(byteRate, to: &data)
        appendLittleEndian(blockAlign, to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(payloadBytes, to: &data)
        for sample in samples {
            appendLittleEndian(UInt16(bitPattern: sample), to: &data)
        }
        try data.write(to: url)
    }

    private func appendLittleEndian(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
