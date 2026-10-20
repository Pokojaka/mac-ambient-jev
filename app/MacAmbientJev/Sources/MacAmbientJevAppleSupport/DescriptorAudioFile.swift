import AudioToolbox
import AVFoundation
import Darwin
import Foundation
import MacAmbientJevCore

/// CoreAudio callbacks keep encoding on the O_NOFOLLOW-opened file, rather than
/// validating a URL and then letting the encoder reopen a potentially replaced path.
final class DescriptorAudioFile {
    let handle: FileHandle
    let audioFile: AudioFileID
    private var closed = false

    init(url: URL, sessionURL: URL, format: inout AudioStreamBasicDescription) throws {
        let handle = try SessionFileAccess.openHandle(url, relativeTo: sessionURL, writable: true, create: true, exclusive: true)
        var file: AudioFileID?
        let status = AudioFileInitializeWithCallbacks(
            Unmanaged.passUnretained(handle).toOpaque(), descriptorRead, descriptorWrite,
            descriptorSize, descriptorSetSize, kAudioFileCAFType, &format, [], &file
        )
        guard status == noErr, let file else {
            try? handle.close()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSFilePathErrorKey: url.path])
        }
        self.handle = handle
        self.audioFile = file
    }

    init(reading url: URL, sessionURL: URL) throws {
        let handle = try SessionFileAccess.openHandle(url, relativeTo: sessionURL)
        var file: AudioFileID?
        let status = AudioFileOpenWithCallbacks(
            Unmanaged.passUnretained(handle).toOpaque(), descriptorRead, nil,
            descriptorSize, nil, 0, &file
        )
        guard status == noErr, let file else {
            try? handle.close()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSFilePathErrorKey: url.path])
        }
        self.handle = handle
        self.audioFile = file
    }

    func close() throws {
        guard !closed else { return }
        closed = true
        let status = AudioFileClose(audioFile)
        defer { try? handle.close() }
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        try handle.synchronize()
    }

    deinit {
        if !closed { AudioFileClose(audioFile) }
        try? handle.close()
    }
}

/// Decoding stays on the opened descriptor for the reader's entire lifetime.
public final class DescriptorAudioReader {
    private let source: DescriptorAudioFile
    private let file: ExtAudioFileRef
    public let fileFormat: AVAudioFormat
    public let processingFormat: AVAudioFormat
    public let length: Int64
    public private(set) var framePosition: Int64 = 0

    public init(url: URL, sessionURL: URL) throws {
        let source = try DescriptorAudioFile(reading: url, sessionURL: sessionURL)
        var wrapped: ExtAudioFileRef?
        try Self.check(ExtAudioFileWrapAudioFileID(source.audioFile, false, &wrapped))
        guard let wrapped else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFileUnspecifiedError)) }
        do {
            var stored = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout.size(ofValue: stored))
            try Self.check(ExtAudioFileGetProperty(wrapped, kExtAudioFileProperty_FileDataFormat, &size, &stored))
            // AVAudioFormat requires an explicit layout above two channels.
            // Preserve their stored order; imported audio averages every channel.
            let layout = stored.mChannelsPerFrame > 2
                ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | stored.mChannelsPerFrame)
                : nil
            let clientFormat: AVAudioFormat?
            if let layout {
                clientFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: stored.mSampleRate,
                    interleaved: false, channelLayout: layout
                )
            } else {
                clientFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: stored.mSampleRate,
                    channels: stored.mChannelsPerFrame, interleaved: false
                )
            }
            guard let fileFormat = AVAudioFormat(streamDescription: &stored, channelLayout: layout),
                  let processingFormat = clientFormat else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioFileUnsupportedDataFormatError))
            }
            var client = processingFormat.streamDescription.pointee
            try Self.check(ExtAudioFileSetProperty(
                wrapped, kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout.size(ofValue: client)), &client
            ))
            var length: Int64 = 0
            size = UInt32(MemoryLayout.size(ofValue: length))
            try Self.check(ExtAudioFileGetProperty(wrapped, kExtAudioFileProperty_FileLengthFrames, &size, &length))
            self.source = source
            self.file = wrapped
            self.fileFormat = fileFormat
            self.processingFormat = processingFormat
            self.length = length
        } catch {
            ExtAudioFileDispose(wrapped)
            throw error
        }
    }

    public func seek(to frame: Int64) throws {
        try Self.check(ExtAudioFileSeek(file, frame))
        framePosition = frame
    }

    public func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws {
        guard frameCount <= buffer.frameCapacity, buffer.format == processingFormat else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudio_ParamError))
        }
        // ExtAudioFileRead consumes mDataByteSize; unlike AVAudioFile it does not
        // expand a zero-length AVAudioPCMBuffer to its capacity.
        buffer.frameLength = frameCount
        var count = frameCount
        try Self.check(ExtAudioFileRead(file, &count, buffer.mutableAudioBufferList))
        buffer.frameLength = count
        framePosition += Int64(count)
    }

    deinit { ExtAudioFileDispose(file) }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

private let descriptorRead: AudioFile_ReadProc = { context, position, count, buffer, actual in
    let descriptor = Unmanaged<FileHandle>.fromOpaque(context).takeUnretainedValue().fileDescriptor
    var result: Int
    repeat { result = pread(descriptor, buffer, Int(count), off_t(position)) } while result < 0 && errno == EINTR
    guard result >= 0 else { actual.pointee = 0; return OSStatus(errno) }
    actual.pointee = UInt32(result)
    return noErr
}

private let descriptorWrite: AudioFile_WriteProc = { context, position, count, buffer, actual in
    let descriptor = Unmanaged<FileHandle>.fromOpaque(context).takeUnretainedValue().fileDescriptor
    var written = 0
    while written < Int(count) {
        let result = pwrite(descriptor, buffer.advanced(by: written), Int(count) - written, off_t(position) + off_t(written))
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else { actual.pointee = UInt32(written); return OSStatus(result == 0 ? EIO : errno) }
        written += result
    }
    actual.pointee = UInt32(written)
    return noErr
}

private let descriptorSize: AudioFile_GetSizeProc = { context in
    let descriptor = Unmanaged<FileHandle>.fromOpaque(context).takeUnretainedValue().fileDescriptor
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { return -1 }
    return Int64(info.st_size)
}

private let descriptorSetSize: AudioFile_SetSizeProc = { context, size in
    let descriptor = Unmanaged<FileHandle>.fromOpaque(context).takeUnretainedValue().fileDescriptor
    return ftruncate(descriptor, off_t(size)) == 0 ? noErr : OSStatus(errno)
}
