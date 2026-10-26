using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace MacAmbientJev.Protocol.Tests;

public sealed class EngineProtocolCodecTests
{
    [Fact]
    public async Task framerHandlesEveryByteAndEverySplitIncludingUTF8AndCRLF()
    {
        var unicodeRecord = Encoding.UTF8.GetBytes("{\"text\":\"😀日本語\\nend\"}");
        var secondRecord = Encoding.UTF8.GetBytes("{\"n\":2}");
        var bytewiseInput = Concat(unicodeRecord, new byte[] { 0x0D, 0x0A }, WithLineFeed(secondRecord));
        var bytewiseStream = CreateReadable(bytewiseInput, 1);
        var bytewiseReader = new NdjsonFrameReader(bytewiseStream);
        var bytewiseRecords = await ReadAllAsync(bytewiseReader);

        Assert.Equal(2, bytewiseRecords.Length);
        Assert.Equal(unicodeRecord, bytewiseRecords[0]);
        Assert.Equal(secondRecord, bytewiseRecords[1]);
        Assert.Equal(bytewiseInput.Length, bytewiseStream.ConsumedByteCount);
        Assert.False(bytewiseStream.IsDisposed);
        Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(bytewiseReader)).Error);

        var manyRecordsStream = new MemoryStream();
        for (var index = 0; index < 64; index++)
        {
            var record = Encoding.UTF8.GetBytes("{\"n\":" + index.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}");
            manyRecordsStream.Write(WithLineFeed(record));
        }

        var coalescedBytes = manyRecordsStream.ToArray();
        var coalescedStream = CreateReadable(coalescedBytes, coalescedBytes.Length);
        var coalescedReader = new NdjsonFrameReader(coalescedStream);
        for (var index = 0; index < 64; index++)
        {
            var expected = Encoding.UTF8.GetBytes("{\"n\":" + index.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}");
            Assert.Equal(expected, await coalescedReader.ReadAsync(CancellationToken.None));
        }

        Assert.Equal(1, coalescedStream.ReadCallCount);
        Assert.Null(await coalescedReader.ReadAsync(CancellationToken.None));
        Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(coalescedReader)).Error);

        var utf8AndCrlf = Concat(unicodeRecord, new byte[] { 0x0D, 0x0A });
        for (var split = 0; split <= utf8AndCrlf.Length; split++)
        {
            var splitStream = CreateSplitReadable(utf8AndCrlf, split, utf8AndCrlf.Length - split);
            var splitReader = new NdjsonFrameReader(splitStream);
            var emitted = await splitReader.ReadAsync(CancellationToken.None);
            Assert.Equal(unicodeRecord, emitted);
            Assert.Null(await splitReader.ReadAsync(CancellationToken.None));
            Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(splitReader)).Error);
            Assert.Equal(0, splitReader.BufferedByteCount);
        }

        var emptyStream = CreateReadable(Array.Empty<byte>(), 16_384);
        var emptyReader = new NdjsonFrameReader(emptyStream);
        Assert.Null(await emptyReader.ReadAsync(CancellationToken.None));
        Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(emptyReader)).Error);
        Assert.False(emptyStream.IsDisposed);
    }

    [Fact]
    public async Task framerAwaitsAnActuallySuspendingReadWithoutLosingPartialState()
    {
        var stream = new GateStream(Encoding.UTF8.GetBytes("{}\r"), [0x0A]);
        var reader = new NdjsonFrameReader(stream);
        var pendingRecord = reader.ReadAsync(CancellationToken.None).AsTask();

        await stream.SecondReadStarted;
        Assert.False(pendingRecord.IsCompleted);
        Assert.Equal(3, reader.BufferedByteCount);
        stream.ReleaseSecondRead();

        Assert.Equal(Encoding.UTF8.GetBytes("{}"), await pendingRecord);
        Assert.Null(await reader.ReadAsync(CancellationToken.None));
        Assert.Equal(3, stream.ReadCallCount);
    }

    [Fact]
    public async Task framerRejectsBlankBareCRAndPartialRecordsAndPoisonsAfterFailure()
    {
        byte[][] blankFrames =
        [
            [0x0A],
            [0x0D, 0x0A],
            [0x20, 0x09, 0x0A],
        ];
        foreach (var frame in blankFrames)
        {
            var reader = new NdjsonFrameReader(CreateReadable(frame, 16_384));
            Assert.Equal(ProtocolError.BlankLine, (await ReadProtocolFailureAsync(reader)).Error);
            Assert.Equal(0, reader.BufferedByteCount);
            Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(reader)).Error);
        }

        var bareCarriageReturnReader = new NdjsonFrameReader(CreateReadable(Encoding.UTF8.GetBytes("{}\rx"), 16_384));
        Assert.Equal(ProtocolError.BareCarriageReturn, (await ReadProtocolFailureAsync(bareCarriageReturnReader)).Error);
        Assert.Equal(0, bareCarriageReturnReader.BufferedByteCount);
        Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(bareCarriageReturnReader)).Error);

        var repeatedCarriageReturnReader = new NdjsonFrameReader(CreateReadable(Encoding.UTF8.GetBytes("{}\r\r\n"), 16_384));
        Assert.Equal(ProtocolError.BareCarriageReturn, (await ReadProtocolFailureAsync(repeatedCarriageReturnReader)).Error);
        Assert.Equal(0, repeatedCarriageReturnReader.BufferedByteCount);
        Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(repeatedCarriageReturnReader)).Error);

        byte[][] partialRecords =
        [
            Encoding.UTF8.GetBytes("{\"ok\":true}"),
            Encoding.UTF8.GetBytes("{\"ok\":true}\r"),
            [0x7B, 0x22, 0x78, 0x22, 0x3A, 0x22, 0xF0, 0x9F],
        ];
        foreach (var partial in partialRecords)
        {
            var reader = new NdjsonFrameReader(CreateReadable(partial, 16_384));
            Assert.Equal(ProtocolError.PartialFinalLine, (await ReadProtocolFailureAsync(reader)).Error);
            Assert.Equal(0, reader.BufferedByteCount);
            Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(reader)).Error);
        }

        var validThenBom = Concat(WithLineFeed(Encoding.UTF8.GetBytes("{}")), [0xEF, 0xBB, 0xBF, 0x7B, 0x7D, 0x0A]);
        var coalescedReader = new NdjsonFrameReader(CreateReadable(validThenBom, validThenBom.Length));
        var ownedRecord = await coalescedReader.ReadAsync(CancellationToken.None);
        Assert.Equal(Encoding.UTF8.GetBytes("{}"), ownedRecord);
        var bomError = await ReadProtocolFailureAsync(coalescedReader);
        Assert.Equal(ProtocolError.ByteOrderMark, bomError.Error);
        Assert.Equal(Encoding.UTF8.GetBytes("{}"), ownedRecord);
        Assert.Equal(0, coalescedReader.BufferedByteCount);
        Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(coalescedReader)).Error);
    }

    [Fact]
    public async Task framerAcceptsExactByteLimitAndRejectsOverlongInputBoundedly()
    {
        const string prefix = "{\"x\":\"";
        const string suffix = "\"}";
        var fill = new string('a', StrictJsonValidator.MaxLineBytes - Encoding.UTF8.GetByteCount(prefix) - Encoding.UTF8.GetByteCount(suffix));
        var exactRecord = Encoding.UTF8.GetBytes(prefix + fill + suffix);
        Assert.Equal(StrictJsonValidator.MaxLineBytes, exactRecord.Length);

        foreach (var delimiter in new[] { new byte[] { 0x0A }, new byte[] { 0x0D, 0x0A } })
        {
            var input = Concat(exactRecord, delimiter);
            var stream = CreateReadable(input, 16_384);
            var reader = new NdjsonFrameReader(stream);
            Assert.Equal(exactRecord, await reader.ReadAsync(CancellationToken.None));
            Assert.True(stream.MaximumReadRequestLength <= 16_384);
            Assert.Equal(input.Length, stream.ConsumedByteCount);
            Assert.Null(await reader.ReadAsync(CancellationToken.None));
        }

        var overlongInput = new byte[StrictJsonValidator.MaxLineBytes + 1];
        Array.Fill(overlongInput, (byte)'a');
        var overlongStream = CreateReadable(overlongInput, 16_384);
        var overlongReader = new NdjsonFrameReader(overlongStream);
        Assert.Equal(ProtocolError.LineTooLong, (await ReadProtocolFailureAsync(overlongReader)).Error);
        Assert.Equal(StrictJsonValidator.MaxLineBytes + 1, overlongStream.ConsumedByteCount);
        Assert.True(overlongStream.MaximumReadRequestLength <= 16_384);
        Assert.Equal(0, overlongReader.BufferedByteCount);
        var callsAfterFailure = overlongStream.ReadCallCount;
        Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(overlongReader)).Error);
        Assert.Equal(callsAfterFailure, overlongStream.ReadCallCount);
        Assert.Equal(StrictJsonValidator.MaxLineBytes + 1, overlongStream.ConsumedByteCount);

        var exactEncoded = NdjsonFrameWriter.Encode(exactRecord);
        Assert.Equal(StrictJsonValidator.MaxLineBytes + 1, exactEncoded.Length);
        Assert.Equal(ProtocolError.LineTooLong, Assert.Throws<ProtocolException>(() => NdjsonFrameWriter.Encode(new byte[StrictJsonValidator.MaxLineBytes + 1])).Error);
    }

    [Fact]
    public async Task codecAppliesLexicalValidationBeforeTypedDecoding()
    {
        (byte[] Record, ProtocolError Error)[] invalidRecords =
        [
            ([0xEF, 0xBB, 0xBF, 0x7B, 0x7D], ProtocolError.ByteOrderMark),
            ([0x7B, 0x22, 0x78, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D], ProtocolError.InvalidUtf8),
            (Encoding.UTF8.GetBytes("{\"x\":1,\"x\":2}"), ProtocolError.DuplicateKey),
            (Encoding.UTF8.GetBytes("[]"), ProtocolError.InvalidJson),
            (Encoding.UTF8.GetBytes("{\"n\":01}"), ProtocolError.InvalidNumber),
            (Encoding.UTF8.GetBytes("{\"n\":-}"), ProtocolError.InvalidNumber),
            (Encoding.UTF8.GetBytes("{\"n\":.1}"), ProtocolError.InvalidNumber),
            (Encoding.UTF8.GetBytes("{\"n\":+1}"), ProtocolError.InvalidNumber),
            (Encoding.UTF8.GetBytes("{\"n\":1.}"), ProtocolError.InvalidNumber),
            (Encoding.UTF8.GetBytes("{\"n\":1e}"), ProtocolError.InvalidNumber),
            (Encoding.UTF8.GetBytes("{\"n\":1e+}"), ProtocolError.InvalidNumber),
            (Encoding.UTF8.GetBytes("{\"n\":0x1}"), ProtocolError.InvalidNumber),
            (Encoding.UTF8.GetBytes("{\"n\":NaN}"), ProtocolError.InvalidNumber),
            (Encoding.UTF8.GetBytes("{\"n\":Infinity}"), ProtocolError.InvalidNumber),
            (Encoding.UTF8.GetBytes("{\"n\":-Infinity}"), ProtocolError.InvalidNumber),
            (Encoding.UTF8.GetBytes("{\"n\":1e9999}"), ProtocolError.InvalidNumber),
            (Encoding.UTF8.GetBytes("{\"s\":\"bad\\q\"}"), ProtocolError.InvalidJson),
            (Encoding.UTF8.GetBytes("{\"s\":\"\\uD800\"}"), ProtocolError.InvalidJson),
            (Encoding.UTF8.GetBytes("{\"s\":\"\\uDC00\"}"), ProtocolError.InvalidJson),
            (Encoding.UTF8.GetBytes("{\"s\":\"\\uD800\\u0041\"}"), ProtocolError.InvalidJson),
            (Encoding.UTF8.GetBytes("{\"s\":\"unterminated}"), ProtocolError.InvalidJson),
        ];

        foreach (var (record, expectedError) in invalidRecords)
        {
            var reader = new NdjsonFrameReader(CreateReadable(WithLineFeed(record), 16_384));
            Assert.Equal(expectedError, (await ReadProtocolFailureAsync(reader)).Error);
            Assert.Equal(0, reader.BufferedByteCount);
            Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(reader)).Error);
        }

        const string validPrefix = """{"version":1,"request_id":"1","command":"hello","payload":{}}""";
        var nestedDuplicate = """{"version":1,"request_id":"1","command":"hello","payload":{"x":1,"x":2}}""";
        var escapedDuplicate = """{"version":1,"request_id":"1","command":"hello","payload":{"x":1,"\u0078":2}}""";
        var badNumbers = new[]
        {
            """{"version":1,"request_id":"1","command":"hello","payload":{},"x":01}""",
            """{"version":1,"request_id":"1","command":"hello","payload":{},"x":NaN}""",
            """{"version":1,"request_id":"1","command":"hello","payload":{},"x":1e9999}""",
        };
        var tooDeep = "{\"x\":" + new string('[', 33) + "0" + new string(']', 33) + "}";
        var overlong = new byte[StrictJsonValidator.MaxLineBytes + 1];
        Array.Fill(overlong, (byte)0x20);
        var validPrefixBytes = Encoding.UTF8.GetBytes(validPrefix);
        var invalidUtf8 = new byte[validPrefixBytes.Length + 1];
        Array.Copy(validPrefixBytes, invalidUtf8, validPrefixBytes.Length - 1);
        invalidUtf8[^2] = 0xFF;
        invalidUtf8[^1] = validPrefixBytes[^1];
        var swiftNegativeCases = new System.Collections.Generic.List<(byte[] Record, ProtocolError Error)>
        {
            (Encoding.UTF8.GetBytes(nestedDuplicate), ProtocolError.DuplicateKey),
            (Encoding.UTF8.GetBytes(escapedDuplicate), ProtocolError.DuplicateKey),
            (invalidUtf8, ProtocolError.InvalidUtf8),
            (Concat([0xEF, 0xBB, 0xBF], validPrefixBytes), ProtocolError.ByteOrderMark),
            (Encoding.UTF8.GetBytes("""{"version":1,"request_id":"1","command":"hello","payload":{},}"""), ProtocolError.InvalidJson),
            (Encoding.UTF8.GetBytes("""{"version":1,"request_id":"1","command":"hello","payload":{}} {}"""), ProtocolError.InvalidJson),
            (Encoding.UTF8.GetBytes("[]"), ProtocolError.InvalidJson),
            (Encoding.UTF8.GetBytes(tooDeep), ProtocolError.NestingTooDeep),
            (overlong, ProtocolError.LineTooLong),
        };
        foreach (var badNumber in badNumbers)
        {
            swiftNegativeCases.Add((Encoding.UTF8.GetBytes(badNumber), ProtocolError.InvalidNumber));
        }

        foreach (var (record, expectedError) in swiftNegativeCases)
        {
            var stream = CreateReadable(WithLineFeed(record), 16_384);
            var reader = new NdjsonFrameReader(stream);
            Assert.Equal(expectedError, (await ReadProtocolFailureAsync(reader)).Error);
            Assert.Equal(0, reader.BufferedByteCount);
            var readCallsAfterFailure = stream.ReadCallCount;
            Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(reader)).Error);
            Assert.Equal(readCallsAfterFailure, stream.ReadCallCount);
            if (expectedError == ProtocolError.LineTooLong)
            {
                Assert.Equal(StrictJsonValidator.MaxLineBytes + 1, stream.ConsumedByteCount);
                Assert.True(stream.MaximumReadRequestLength <= 16_384);
            }
        }

        byte[][] validRecords =
        [
            Encoding.UTF8.GetBytes("{\"kind\":\"unmapped-kind\",\"payload\":{\"x\":1}} "),
            Encoding.UTF8.GetBytes("{\"n\":-1.25e+100,\"underflow\":1e-9999}"),
        ];
        foreach (var validRecord in validRecords)
        {
            var validReader = new NdjsonFrameReader(CreateReadable(WithLineFeed(validRecord), 16_384));
            Assert.Equal(validRecord, await validReader.ReadAsync(CancellationToken.None));
            Assert.Null(await validReader.ReadAsync(CancellationToken.None));
        }
    }

    [Fact]
    public async Task writerEncodesValidatedRecordWithOneLFWithoutBOMAndPreservesBytes()
    {
        var record = Encoding.UTF8.GetBytes("{\"text\":\"😀日本語\\nend\"}");
        var encoded = NdjsonFrameWriter.Encode(record);
        using var destination = new MemoryStream();
        await NdjsonFrameWriter.WriteAsync(destination, record, CancellationToken.None);

        Assert.Equal(0x0A, encoded[^1]);
        Assert.Equal(record.Length + 1, encoded.Length);
        Assert.Equal(record, encoded[..^1]);
        Assert.Equal(encoded, destination.ToArray());
        Assert.False(encoded.Length >= 3 && encoded[0] == 0xEF && encoded[1] == 0xBB && encoded[2] == 0xBF);
        Assert.True(destination.CanWrite);
    }

    [Fact]
    public async Task writerRejectsInvalidRecordsBeforeWritingAndRoundTripsMultipleRecords()
    {
        byte[][] invalidRecords =
        [
            Array.Empty<byte>(),
            [0xEF, 0xBB, 0xBF, 0x7B, 0x7D],
            [0x7B, 0x22, 0x78, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D],
            Encoding.UTF8.GetBytes("{\"x\":1,\"x\":2}"),
        ];
        foreach (var invalid in invalidRecords)
        {
            var destination = CreateWritable();
            await Assert.ThrowsAsync<ProtocolException>(async () => await NdjsonFrameWriter.WriteAsync(destination, invalid, CancellationToken.None));
            Assert.Equal(0, destination.WriteCallCount);
            Assert.Empty(destination.WrittenBytes);
            Assert.False(destination.IsDisposed);
        }

        var records = new[]
        {
            Encoding.UTF8.GetBytes("{\"n\":1}"),
            Encoding.UTF8.GetBytes("{\"text\":\"😀\"}"),
            Encoding.UTF8.GetBytes("{\"escaped\":\"a\\nb\"}"),
        };
        var output = CreateReadWrite();
        foreach (var record in records)
        {
            await NdjsonFrameWriter.WriteAsync(output, record, CancellationToken.None);
        }

        Assert.Equal(records.Length, output.WriteCallCount);
        Assert.False(output.IsDisposed);
        var encodedRecords = output.WrittenBytes;
        var readerStream = CreateReadable(encodedRecords, 16_384);
        var reader = new NdjsonFrameReader(readerStream);
        foreach (var record in records)
        {
            Assert.Equal(record, await reader.ReadAsync(CancellationToken.None));
        }

        Assert.Null(await reader.ReadAsync(CancellationToken.None));
        Assert.False(readerStream.IsDisposed);
        Assert.False(output.IsDisposed);
    }

    [Fact]
    public async Task writerRejectsPreDelimitedRecordsBeforeWriting()
    {
        byte[][] records =
        [
            Encoding.UTF8.GetBytes("{\"x\":1}\n"),
            Encoding.UTF8.GetBytes("{\"x\":1}\r\n"),
        ];
        foreach (var record in records)
        {
            var encodeError = Assert.Throws<ProtocolException>(() => NdjsonFrameWriter.Encode(record));
            Assert.Equal(ProtocolError.InvalidJson, encodeError.Error);

            var destination = CreateWritable();
            var writeError = await Assert.ThrowsAsync<ProtocolException>(async () => await NdjsonFrameWriter.WriteAsync(destination, record, CancellationToken.None));
            Assert.Equal(ProtocolError.InvalidJson, writeError.Error);
            Assert.Equal(0, destination.WriteCallCount);
            Assert.Empty(destination.WrittenBytes);
        }
    }

    [Fact]
    public async Task writerAcceptsExactByteLimitAndRejectsOverlongInputBeforeWriting()
    {
        const string prefix = "{\"x\":\"";
        const string suffix = "\"}";
        var fill = new string('a', StrictJsonValidator.MaxLineBytes - Encoding.UTF8.GetByteCount(prefix) - Encoding.UTF8.GetByteCount(suffix));
        var exactRecord = Encoding.UTF8.GetBytes(prefix + fill + suffix);
        var destination = CreateWritable();

        await NdjsonFrameWriter.WriteAsync(destination, exactRecord, CancellationToken.None);
        Assert.Equal(1, destination.WriteCallCount);
        Assert.Equal(StrictJsonValidator.MaxLineBytes + 1, destination.WrittenBytes.Length);
        Assert.Equal(0x0A, destination.WrittenBytes[^1]);
        Assert.Equal(exactRecord, destination.WrittenBytes[..^1]);

        var overlongDestination = CreateWritable();
        var overlong = new byte[StrictJsonValidator.MaxLineBytes + 1];
        Array.Fill(overlong, (byte)'a');
        var exception = await Assert.ThrowsAsync<ProtocolException>(async () => await NdjsonFrameWriter.WriteAsync(overlongDestination, overlong, CancellationToken.None));
        Assert.Equal(ProtocolError.LineTooLong, exception.Error);
        Assert.Equal(0, overlongDestination.WriteCallCount);
        Assert.Empty(overlongDestination.WrittenBytes);
    }

    [Fact]
    public async Task codecPreservesCancellationAndIoErrorsAndDoesNotOwnStreams()
    {
        var readCancellation = new OperationCanceledException("reader cancellation");
        var canceledStream = CreateReadFailure(readCancellation);
        var canceledReader = new NdjsonFrameReader(canceledStream);
        Assert.Same(readCancellation, await Assert.ThrowsAsync<OperationCanceledException>(async () => await canceledReader.ReadAsync(CancellationToken.None)));
        Assert.Equal(0, canceledReader.BufferedByteCount);
        Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(canceledReader)).Error);
        Assert.False(canceledStream.IsDisposed);

        var readIoError = new IOException("reader io failure");
        var ioStream = CreateReadFailure(readIoError);
        var ioReader = new NdjsonFrameReader(ioStream);
        Assert.Same(readIoError, await Assert.ThrowsAsync<IOException>(async () => await ioReader.ReadAsync(CancellationToken.None)));
        Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(ioReader)).Error);
        Assert.False(ioStream.IsDisposed);

        var preCanceledStream = CreateReadable(Array.Empty<byte>(), 16_384);
        var preCanceledReader = new NdjsonFrameReader(preCanceledStream);
        using (var cancellation = new CancellationTokenSource())
        {
            cancellation.Cancel();
            await Assert.ThrowsAsync<OperationCanceledException>(async () => await preCanceledReader.ReadAsync(cancellation.Token));
        }

        Assert.Equal(0, preCanceledStream.ReadCallCount);
        Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(preCanceledReader)).Error);

        var coalescedCancellationBytes = Concat(WithLineFeed(Encoding.UTF8.GetBytes("{}")), WithLineFeed(Encoding.UTF8.GetBytes("{}")));
        var coalescedCancellationStream = CreateReadable(coalescedCancellationBytes, 16_384);
        var coalescedCancellationReader = new NdjsonFrameReader(coalescedCancellationStream);
        Assert.Equal(Encoding.UTF8.GetBytes("{}"), await coalescedCancellationReader.ReadAsync(CancellationToken.None));
        Assert.Equal(coalescedCancellationBytes.Length, coalescedCancellationStream.ConsumedByteCount);
        var readsBeforeBufferedCancellation = coalescedCancellationStream.ReadCallCount;
        using (var cancellation = new CancellationTokenSource())
        {
            cancellation.Cancel();
            await Assert.ThrowsAsync<OperationCanceledException>(async () => await coalescedCancellationReader.ReadAsync(cancellation.Token));
        }

        Assert.Equal(ProtocolError.ClosedReader, (await ReadProtocolFailureAsync(coalescedCancellationReader)).Error);
        Assert.Equal(readsBeforeBufferedCancellation, coalescedCancellationStream.ReadCallCount);
        Assert.Equal(coalescedCancellationBytes.Length, coalescedCancellationStream.ConsumedByteCount);

        var writeCancellation = new OperationCanceledException("writer cancellation");
        var canceledDestination = CreateWriteFailure(writeCancellation);
        Assert.Same(writeCancellation, await Assert.ThrowsAsync<OperationCanceledException>(async () => await NdjsonFrameWriter.WriteAsync(canceledDestination, Encoding.UTF8.GetBytes("{}"), CancellationToken.None)));
        Assert.Equal(1, canceledDestination.WriteCallCount);
        Assert.False(canceledDestination.IsDisposed);

        var writeIoError = new IOException("writer io failure");
        var ioDestination = CreateWriteFailure(writeIoError);
        Assert.Same(writeIoError, await Assert.ThrowsAsync<IOException>(async () => await NdjsonFrameWriter.WriteAsync(ioDestination, Encoding.UTF8.GetBytes("{}"), CancellationToken.None)));
        Assert.Equal(1, ioDestination.WriteCallCount);
        Assert.False(ioDestination.IsDisposed);

        var preCanceledDestination = CreateWritable();
        using (var cancellation = new CancellationTokenSource())
        {
            cancellation.Cancel();
            await Assert.ThrowsAsync<OperationCanceledException>(async () => await NdjsonFrameWriter.WriteAsync(preCanceledDestination, Encoding.UTF8.GetBytes("{}"), cancellation.Token));
        }

        Assert.Equal(0, preCanceledDestination.WriteCallCount);
        Assert.Empty(preCanceledDestination.WrittenBytes);
        Assert.False(preCanceledDestination.IsDisposed);
    }

    [Fact]
    public async Task codecRejectsNullAndWrongDirectionStreams()
    {
        Assert.Throws<ArgumentNullException>(() => new NdjsonFrameReader(null!));
        Assert.Throws<ArgumentException>(() => new NdjsonFrameReader(CreateWritable()));
        await Assert.ThrowsAsync<ArgumentNullException>(async () => await NdjsonFrameWriter.WriteAsync(null!, Encoding.UTF8.GetBytes("{}"), CancellationToken.None));
        await Assert.ThrowsAsync<ArgumentException>(async () => await NdjsonFrameWriter.WriteAsync(CreateReadable(WithLineFeed(Encoding.UTF8.GetBytes("{}")), 16_384), Encoding.UTF8.GetBytes("{}"), CancellationToken.None));
    }

    private static async Task<byte[][]> ReadAllAsync(NdjsonFrameReader reader)
    {
        var records = new System.Collections.Generic.List<byte[]>();
        while (true)
        {
            var record = await reader.ReadAsync(CancellationToken.None);
            if (record is null)
            {
                return records.ToArray();
            }

            records.Add(record);
        }
    }

    private static async Task<ProtocolException> ReadProtocolFailureAsync(NdjsonFrameReader reader) =>
        await Assert.ThrowsAsync<ProtocolException>(async () => await reader.ReadAsync(CancellationToken.None));

    private static byte[] WithLineFeed(byte[] record) => Concat(record, [0x0A]);

    private static byte[] Concat(params byte[][] parts)
    {
        var length = 0;
        foreach (var part in parts)
        {
            length += part.Length;
        }

        var combined = new byte[length];
        var offset = 0;
        foreach (var part in parts)
        {
            Buffer.BlockCopy(part, 0, combined, offset, part.Length);
            offset += part.Length;
        }

        return combined;
    }

    private static ScriptableStream CreateReadable(byte[] input, int maximumReadSize) =>
        new(input, canRead: true, canWrite: false, maximumReadSize, Array.Empty<int>(), readFailure: null, writeFailure: null);

    private static ScriptableStream CreateSplitReadable(byte[] input, params int[] chunkSizes) =>
        new(input, canRead: true, canWrite: false, int.MaxValue, chunkSizes, readFailure: null, writeFailure: null);

    private static ScriptableStream CreateReadFailure(Exception failure) =>
        new(Array.Empty<byte>(), canRead: true, canWrite: false, 16_384, Array.Empty<int>(), failure, writeFailure: null);

    private static ScriptableStream CreateWritable() =>
        new(Array.Empty<byte>(), canRead: false, canWrite: true, 16_384, Array.Empty<int>(), readFailure: null, writeFailure: null);

    private static ScriptableStream CreateWriteFailure(Exception failure) =>
        new(Array.Empty<byte>(), canRead: false, canWrite: true, 16_384, Array.Empty<int>(), readFailure: null, failure);

    private static ScriptableStream CreateReadWrite() =>
        new(Array.Empty<byte>(), canRead: true, canWrite: true, 16_384, Array.Empty<int>(), readFailure: null, writeFailure: null);

    private sealed class GateStream : Stream
    {
        private readonly byte[] _firstReadBytes;
        private readonly byte[] _releasedReadBytes;
        private readonly TaskCompletionSource<bool> _secondReadStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource<bool> _releaseSecondRead = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public GateStream(byte[] firstReadBytes, byte[] releasedReadBytes)
        {
            _firstReadBytes = firstReadBytes;
            _releasedReadBytes = releasedReadBytes;
        }

        public Task SecondReadStarted => _secondReadStarted.Task;

        public int ReadCallCount { get; private set; }

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override int Read(byte[] buffer, int offset, int count) =>
            throw new InvalidOperationException("Synchronous reads are forbidden.");

        public override int Read(Span<byte> buffer) =>
            throw new InvalidOperationException("Synchronous reads are forbidden.");

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            switch (++ReadCallCount)
            {
                case 1:
                    _firstReadBytes.AsMemory().CopyTo(buffer);
                    return _firstReadBytes.Length;
                case 2:
                    _secondReadStarted.TrySetResult(true);
                    await _releaseSecondRead.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
                    cancellationToken.ThrowIfCancellationRequested();
                    _releasedReadBytes.AsMemory().CopyTo(buffer);
                    return _releasedReadBytes.Length;
                case 3:
                    return 0;
                default:
                    throw new InvalidOperationException("Unexpected read after EOF.");
            }
        }

        public void ReleaseSecondRead() => _releaseSecondRead.TrySetResult(true);

        public override void Write(byte[] buffer, int offset, int count) =>
            throw new InvalidOperationException("Synchronous writes are forbidden.");

        public override void Write(ReadOnlySpan<byte> buffer) =>
            throw new InvalidOperationException("Synchronous writes are forbidden.");

        public override void Flush() => throw new NotSupportedException();

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();
    }

    private sealed class ScriptableStream : Stream
    {
        private readonly byte[] _input;
        private readonly bool _canRead;
        private readonly bool _canWrite;
        private readonly int _maximumReadSize;
        private readonly int[] _chunkSizes;
        private readonly Exception? _readFailure;
        private readonly Exception? _writeFailure;
        private readonly MemoryStream _written = new();
        private int _inputPosition;
        private int _chunkIndex;
        private int _activeChunkRemaining;
        private bool _hasActiveChunk;
        private bool _disposed;

        public ScriptableStream(
            byte[] input,
            bool canRead,
            bool canWrite,
            int maximumReadSize,
            int[] chunkSizes,
            Exception? readFailure,
            Exception? writeFailure)
        {
            if (maximumReadSize <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(maximumReadSize));
            }

            _input = input;
            _canRead = canRead;
            _canWrite = canWrite;
            _maximumReadSize = maximumReadSize;
            _chunkSizes = chunkSizes;
            _readFailure = readFailure;
            _writeFailure = writeFailure;
        }

        public int ReadCallCount { get; private set; }

        public int MaximumReadRequestLength { get; private set; }

        public int ConsumedByteCount => _inputPosition;

        public int WriteCallCount { get; private set; }

        public byte[] WrittenBytes => _written.ToArray();

        public bool IsDisposed => _disposed;

        public override bool CanRead => !_disposed && _canRead;

        public override bool CanSeek => false;

        public override bool CanWrite => !_disposed && _canWrite;

        public override long Length => throw new NotSupportedException();

        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override int Read(byte[] buffer, int offset, int count) =>
            throw new InvalidOperationException("Synchronous reads are forbidden.");

        public override int Read(Span<byte> buffer) =>
            throw new InvalidOperationException("Synchronous reads are forbidden.");

        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!CanRead)
            {
                throw new NotSupportedException("Stream is not readable.");
            }

            ReadCallCount++;
            MaximumReadRequestLength = Math.Max(MaximumReadRequestLength, buffer.Length);
            if (_readFailure is not null)
            {
                throw _readFailure;
            }

            if (buffer.IsEmpty)
            {
                return ValueTask.FromResult(0);
            }

            while (_chunkIndex < _chunkSizes.Length)
            {
                if (!_hasActiveChunk)
                {
                    _activeChunkRemaining = _chunkSizes[_chunkIndex];
                    _hasActiveChunk = true;
                }

                if (_activeChunkRemaining != 0)
                {
                    break;
                }

                _chunkIndex++;
                _hasActiveChunk = false;
            }

            var limit = Math.Min(buffer.Length, _maximumReadSize);
            if (_hasActiveChunk)
            {
                limit = Math.Min(limit, _activeChunkRemaining);
            }

            var count = Math.Min(limit, _input.Length - _inputPosition);
            if (count == 0)
            {
                return ValueTask.FromResult(0);
            }

            _input.AsMemory(_inputPosition, count).CopyTo(buffer);
            _inputPosition += count;
            if (_hasActiveChunk)
            {
                _activeChunkRemaining -= count;
                if (_activeChunkRemaining == 0)
                {
                    _chunkIndex++;
                    _hasActiveChunk = false;
                }
            }

            return ValueTask.FromResult(count);
        }

        public override void Write(byte[] buffer, int offset, int count) =>
            throw new InvalidOperationException("Synchronous writes are forbidden.");

        public override void Write(ReadOnlySpan<byte> buffer) =>
            throw new InvalidOperationException("Synchronous writes are forbidden.");

        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!CanWrite)
            {
                throw new NotSupportedException("Stream is not writable.");
            }

            WriteCallCount++;
            if (_writeFailure is not null)
            {
                throw _writeFailure;
            }

            _written.Write(buffer.Span);
            return ValueTask.CompletedTask;
        }

        public override void Flush() => throw new NotSupportedException();

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            _disposed = true;
            base.Dispose(disposing);
        }
    }
}
