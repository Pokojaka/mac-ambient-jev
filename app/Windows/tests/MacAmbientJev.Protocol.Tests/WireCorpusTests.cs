using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Xunit;

namespace MacAmbientJev.Protocol.Tests;

public sealed class WireCorpusTests
{
    [Fact]
    public async Task linkedWireCorpusIsReadAsValidatedFramesWithDocumentedRecordCount()
    {
        var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "wire-v1.ndjson");
        using var stream = File.OpenRead(path);
        using var roundTrip = new MemoryStream();
        var reader = new NdjsonFrameReader(stream);
        var recordCount = 0;
        long roundTripByteCount = 0;

        while (true)
        {
            var record = await reader.ReadAsync(CancellationToken.None);
            if (record is null)
            {
                break;
            }

            StrictJsonValidator.Validate(record);
            var encoded = NdjsonFrameWriter.Encode(record);
            Assert.Equal(record.Length + 1, encoded.Length);
            Assert.Equal(record, encoded[..^1]);
            Assert.Equal((byte)'\n', encoded[^1]);
            await NdjsonFrameWriter.WriteAsync(roundTrip, record, CancellationToken.None);
            roundTripByteCount += encoded.Length;
            recordCount++;
        }

        Assert.Equal(102, recordCount);
        Assert.Equal(roundTripByteCount, roundTrip.Length);
        Assert.True(stream.CanRead);
        Assert.True(roundTrip.CanWrite);
    }
}
