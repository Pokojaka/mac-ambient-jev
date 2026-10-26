namespace MacAmbientJev.Protocol;

/// <summary>Reads validated records from a byte-oriented NDJSON stream.</summary>
/// <remarks>This reader is single-consumer and not thread-safe. It does not own or dispose the stream.</remarks>
public sealed class NdjsonFrameReader
{
    private const int ReadChunkSize = 16_384;
    private const int InitialRecordBufferSize = 4_096;

    private readonly Stream _stream;
    private byte[] _readBuffer = new byte[ReadChunkSize];
    private byte[] _recordBuffer = Array.Empty<byte>();
    private int _readPosition;
    private int _readEnd;
    private int _recordCount;
    private bool _pendingCarriageReturn;
    private bool _closed;

    public NdjsonFrameReader(Stream stream)
    {
        ArgumentNullException.ThrowIfNull(stream);
        if (!stream.CanRead)
        {
            throw new ArgumentException("Stream must be readable.", nameof(stream));
        }

        _stream = stream;
    }

    public int BufferedByteCount => _recordCount + (_pendingCarriageReturn ? 1 : 0);

    public async ValueTask<byte[]?> ReadAsync(CancellationToken cancellationToken)
    {
        if (_closed)
        {
            throw new ProtocolException(ProtocolError.ClosedReader);
        }

        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (_readPosition < _readEnd)
                {
                    var value = _readBuffer[_readPosition++];
                    if (_pendingCarriageReturn)
                    {
                        if (value != (byte)'\n')
                        {
                            throw new ProtocolException(ProtocolError.BareCarriageReturn);
                        }

                        _pendingCarriageReturn = false;
                        return CompleteRecord();
                    }

                    if (value == (byte)'\n')
                    {
                        return CompleteRecord();
                    }

                    if (value == (byte)'\r')
                    {
                        _pendingCarriageReturn = true;
                        continue;
                    }

                    AppendRecordByte(value);
                    continue;
                }

                var maxLineBytes = StrictJsonValidator.MaxLineBytes;
                var requestedCount = Math.Min(_readBuffer.Length, maxLineBytes - _recordCount + 1);
                _readPosition = 0;
                _readEnd = await _stream.ReadAsync(_readBuffer.AsMemory(0, requestedCount), cancellationToken).ConfigureAwait(false);
                if (_readEnd == 0)
                {
                    if (_recordCount == 0 && !_pendingCarriageReturn)
                    {
                        _closed = true;
                        return null;
                    }

                    throw new ProtocolException(ProtocolError.PartialFinalLine);
                }
            }
        }
        catch
        {
            Poison();
            throw;
        }
    }

    private void AppendRecordByte(byte value)
    {
        var maxLineBytes = StrictJsonValidator.MaxLineBytes;
        if (_recordCount == maxLineBytes)
        {
            throw new ProtocolException(ProtocolError.LineTooLong);
        }

        if (_recordCount == _recordBuffer.Length)
        {
            var newSize = _recordBuffer.Length == 0
                ? InitialRecordBufferSize
                : Math.Min(_recordBuffer.Length * 2, maxLineBytes);
            Array.Resize(ref _recordBuffer, newSize);
        }

        _recordBuffer[_recordCount++] = value;
    }

    private byte[] CompleteRecord()
    {
        StrictJsonValidator.Validate(_recordBuffer.AsSpan(0, _recordCount));

        var record = new byte[_recordCount];
        _recordBuffer.AsSpan(0, _recordCount).CopyTo(record);
        _recordCount = 0;
        _pendingCarriageReturn = false;
        return record;
    }

    private void Poison()
    {
        _recordBuffer = Array.Empty<byte>();
        _readBuffer = Array.Empty<byte>();
        _readPosition = 0;
        _readEnd = 0;
        _recordCount = 0;
        _pendingCarriageReturn = false;
        _closed = true;
    }
}
