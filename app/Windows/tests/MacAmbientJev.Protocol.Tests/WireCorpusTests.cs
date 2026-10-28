using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using Xunit;

namespace MacAmbientJev.Protocol.Tests;

public sealed class WireCorpusTests
{
    [Theory]
    [MemberData(nameof(CorpusRecords))]
    public void typedCorpusRecordsRoundTrip(int recordNumber, byte[] record)
    {
        bool isOutput;
        using (var document = JsonDocument.Parse(record))
        {
            isOutput = document.RootElement.TryGetProperty("event", out _);
        }

        var encoded = isOutput
            ? EngineCodec.EncodeOutput(EngineCodec.DecodeOutput(record))
            : EngineCodec.EncodeRequest(EngineCodec.DecodeRequest(record));
        var expected = new byte[record.Length + 1];
        Buffer.BlockCopy(record, 0, expected, 0, record.Length);
        expected[^1] = (byte)'\n';
        Assert.True(expected.AsSpan().SequenceEqual(encoded), $"Record {recordNumber} changed during typed round-trip.");
    }

    [Theory]
    [MemberData(nameof(NegativeCorpusRecords))]
    public void negativeCorpusRecordsAreRejected(byte[] record)
    {
        bool isOutput;
        using (var document = JsonDocument.Parse(record))
        {
            isOutput = document.RootElement.TryGetProperty("event", out _);
        }

        Assert.ThrowsAny<Exception>(() =>
        {
            if (isOutput)
            {
                _ = EngineCodec.DecodeOutput(record);
            }
            else
            {
                _ = EngineCodec.DecodeRequest(record);
            }
        });
    }

    public static IEnumerable<object[]> CorpusRecords()
    {
        var records = ReadCorpus();
        for (var index = 0; index < records.Length; index++)
        {
            yield return new object[] { index + 1, records[index] };
        }
    }

    public static IEnumerable<object[]> NegativeCorpusRecords()
    {
        var records = ReadNegativeCorpus();
        foreach (var record in records)
        {
            yield return new object[] { record };
        }
    }

    internal static byte[][] ReadCorpus() => ReadCorpus("wire-v1.ndjson");

    internal static byte[][] ReadNegativeCorpus() => ReadCorpus("wire-v1-negative.ndjson");

    private static byte[][] ReadCorpus(string fileName)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", fileName);
        var bytes = File.ReadAllBytes(path);
        if (bytes.Length == 0 || bytes[^1] != (byte)'\n')
        {
            throw new InvalidDataException("Wire corpus must be nonempty and end with LF.");
        }

        var records = new List<byte[]>();
        var start = 0;
        for (var index = 0; index < bytes.Length; index++)
        {
            if (bytes[index] != (byte)'\n')
            {
                continue;
            }

            if (index == start)
            {
                throw new InvalidDataException("Wire corpus contains a blank record.");
            }

            records.Add(bytes[start..index]);
            start = index + 1;
        }

        if (start != bytes.Length)
        {
            throw new InvalidDataException("Wire corpus has an unterminated record.");
        }

        return records.ToArray();
    }
}
