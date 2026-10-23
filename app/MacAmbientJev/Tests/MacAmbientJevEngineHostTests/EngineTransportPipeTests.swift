#if !os(Windows)
import Foundation
import Testing
import MacAmbientJevEngineHost
import MacAmbientJevEngineProtocol
import MacAmbientJevCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func makePipe() -> (read: Int32, write: Int32) {
    var fds: [Int32] = [0, 0]
    precondition(pipe(&fds) == 0, "pipe() failed")
    return (fds[0], fds[1])
}

private final class PipeReader: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var storage = Data()
    private var finished = false
    private let pauseMicroseconds: UInt32

    init(descriptor: Int32, pauseMicroseconds: UInt32) {
        self.descriptor = descriptor
        self.pauseMicroseconds = pauseMicroseconds
        Thread.detachNewThread { [self] in run() }
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            if pauseMicroseconds > 0 { usleep(pauseMicroseconds) }
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            lock.lock()
            storage.append(contentsOf: buffer[..<count])
            lock.unlock()
        }
        lock.lock()
        finished = true
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// Isolate blocking pipe work so it cannot stall producers/observers or skew deadline timing.
@Suite struct EngineTransportPipeTests {
    @Test func aSlowPipeReaderReceivesEveryRecordIntact() async throws {
        try await withTaskExecutorPreference(BlockingIOExecutor.shared) {
            let fds = makePipe()
            let reader = PipeReader(descriptor: fds.read, pauseMicroseconds: 200)
            let transport = EngineTransport(source: ScriptedSource(), sink: PosixByteSink(fileDescriptor: fds.write), limits: testLimits())
            transport.start()
            defer { transport.close(); closeDescriptor(fds.read) }

            let text = String(repeating: "あ", count: 3000)
            for id in 1...40 {
                try await transport.send(.completed(.shutdown), requestID: EngineID(UInt64(id)))
                try transport.sendReplaceable(try rowsEvent(session: "s", revision: UInt64(id), rowIDs: ["r\(id)"], text: text), requestID: nil)
            }
            await transport.drain()
            try await waitUntil(timeout: 20, "pipe reader to receive all bytes") {
                reader.data.last == 0x0A && ((try? ScriptedSink.decodeOutputs(reader.data).count) ?? 0) >= 41
            }
            let outputs = try ScriptedSink.decodeOutputs(reader.data)
            #expect(outputs.filter { if case .completed = $0.event { true } else { false } }.count == 40)
            #expect(outputs.map(\.sequence.value) == outputs.map(\.sequence.value).sorted())
        }
    }

    @Test func aPipeThatIsNeverReadFailsAtTheDeadline() async throws {
        await withTaskExecutorPreference(BlockingIOExecutor.shared) {
            let fds = makePipe()
            let transport = EngineTransport(source: ScriptedSource(), sink: PosixByteSink(fileDescriptor: fds.write), limits: testLimits(deadline: 0.3))
            transport.start()
            defer { transport.close(); closeDescriptor(fds.read) }

            let text = String(repeating: "あ", count: 3000)
            let started = Date()
            for id in 1...20 {
                try? await transport.send(.completed(.shutdown), requestID: EngineID(UInt64(id)))
                try? transport.sendReplaceable(try rowsEvent(session: "s", revision: UInt64(id), rowIDs: ["r\(id)"], text: text), requestID: nil)
            }
            var failure: EngineWriteFailure?
            for await event in transport.events {
                if case let .writeFailed(reason) = event { failure = reason; break }
            }
            #expect(failure == .deadlineExceeded)
            #expect(Date().timeIntervalSince(started) < 4)
        }
    }

    @Test func aClosedReaderIsABrokenPipe() async throws {
        try await withTaskExecutorPreference(BlockingIOExecutor.shared) {
            let fds = makePipe()
            closeDescriptor(fds.read)
            let transport = EngineTransport(source: ScriptedSource(), sink: PosixByteSink(fileDescriptor: fds.write), limits: testLimits())
            transport.start()
            defer { transport.close() }
            try await transport.send(.completed(.shutdown), requestID: EngineID(1))
            var failure: EngineWriteFailure?
            for await event in transport.events {
                if case let .writeFailed(reason) = event { failure = reason; break }
            }
            #expect(failure == .brokenPipe)
        }
    }

    @Test func fileHandleSourceReadsFragmentedBinaryInput() async throws {
        try await withTaskExecutorPreference(BlockingIOExecutor.shared) {
            let fds = makePipe()
            let source = FileHandleByteSource(handle: FileHandle(fileDescriptor: fds.read, closeOnDealloc: true))
            let transport = EngineTransport(source: source, sink: ScriptedSink(), limits: testLimits())
            transport.start()
            defer { transport.close() }

            let record = requestLine(1, "session.import", payload: "{\"input_path\":\"/tmp/会議.wav\"}")
            let bytes = Array(record.utf8)
            for chunk in stride(from: 0, to: bytes.count, by: 7) {
                let piece = Array(bytes[chunk..<min(chunk + 7, bytes.count)])
                #expect(write(fds.write, piece, piece.count) == piece.count)
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            var iterator = transport.events.makeAsyncIterator()
            guard case let .line(line) = await iterator.next() else { Issue.record("no line"); return }
            #expect(String(decoding: line, as: UTF8.self) == String(record.dropLast()))
            closeDescriptor(fds.write)
            #expect(await iterator.next() == .endOfInput)
        }
    }
}

private func closeDescriptor(_ descriptor: Int32) {
    _ = close(descriptor)
}
#endif
