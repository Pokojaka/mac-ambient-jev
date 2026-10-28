namespace MacAmbientJev.Protocol;

/// <summary>Encodes and writes validated records as LF-delimited NDJSON bytes.</summary>
/// <remarks>Writes do not own or dispose the stream. Callers must serialize concurrent writes.</remarks>
public static class NdjsonFrameWriter
{
    public static byte[] Encode(ReadOnlySpan<byte> record)
    {
        StrictJsonValidator.Validate(record);

        var encoded = new byte[record.Length + 1];
        record.CopyTo(encoded);
        encoded[^1] = (byte)'\n';
        return encoded;
    }

    public static async ValueTask WriteAsync(Stream stream, ReadOnlyMemory<byte> record, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(stream);
        if (!stream.CanWrite)
        {
            throw new ArgumentException("Stream must be writable.", nameof(stream));
        }

        cancellationToken.ThrowIfCancellationRequested();
        var encoded = Encode(record.Span);
        await stream.WriteAsync(encoded.AsMemory(), cancellationToken).ConfigureAwait(false);
    }
}
