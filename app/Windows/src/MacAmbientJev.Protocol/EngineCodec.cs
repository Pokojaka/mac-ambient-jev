using System.Globalization;

namespace MacAmbientJev.Protocol;

/// <summary>Encodes and decodes typed engine protocol records.</summary>
public static class EngineCodec
{
    public const int MaxRowBytes = 262_144;

    public static EngineRequest DecodeRequest(ReadOnlySpan<byte> record) =>
        StrictWireCodec.Decode<EngineRequest>(record);

    public static EngineOutput DecodeOutput(ReadOnlySpan<byte> record)
    {
        var output = StrictWireCodec.Decode<EngineOutput>(record);
        ValidateRows(output);
        return output;
    }

    public static byte[] EncodeRequest(EngineRequest request) =>
        NdjsonFrameWriter.Encode(StrictWireCodec.Encode(request));

    public static byte[] EncodeOutput(EngineOutput output)
    {
        if (output is null)
        {
            throw WrongType("$", "Output must not be null.");
        }

        if (output.Event is null)
        {
            throw WrongType("$.event", "Flattened event must not be null.");
        }

        ValidateRows(output);
        return NdjsonFrameWriter.Encode(StrictWireCodec.Encode(output));
    }

    private static void ValidateRows(EngineOutput output)
    {
        switch (output.Event)
        {
            case EngineEvent.Rows rows:
                if (rows.Payload is null)
                {
                    throw WrongType("$.payload", "Event payload must not be null.");
                }

                ValidateRows(rows.Payload.Rows, "$.payload.rows");
                break;
            case EngineEvent.Completed completed:
                if (completed.Payload is null)
                {
                    throw WrongType("$.payload", "Event payload must not be null.");
                }

                switch (completed.Payload)
                {
                    case EngineResult.TranscriptRead read:
                        if (read.Result is null)
                        {
                            throw WrongType("$.payload.result", "Transcript result must not be null.");
                        }

                        ValidateRows(read.Result.Rows, "$.payload.result.rows");
                        break;
                    case EngineResult.TranscriptWatch watch:
                        if (watch.Result is null)
                        {
                            throw WrongType("$.payload.result", "Transcript result must not be null.");
                        }

                        ValidateRows(watch.Result.Rows, "$.payload.result.rows");
                        break;
                }

                break;
        }
    }

    private static void ValidateRows(EngineTranscriptRow[]? rows, string path)
    {
        if (rows is null)
        {
            throw WrongType(path, "Transcript rows must not be null.");
        }

        for (var index = 0; index < rows.Length; index++)
        {
            var row = rows[index];
            var rowPath = path + "[" + index.ToString(CultureInfo.InvariantCulture) + "]";
            if (row is null)
            {
                throw WrongType(rowPath, "Transcript row must not be null.");
            }

            byte[] encodedRow;
            try
            {
                encodedRow = StrictWireCodec.Encode(row);
            }
            catch (ProtocolException exception) when (exception.Error == ProtocolError.LineTooLong)
            {
                throw OversizedRow(rowPath, row.RowID);
            }
            catch (WireDecodeException exception)
            {
                if (exception.Path.Length == 0 || exception.Path[0] != '$')
                {
                    throw new InvalidOperationException("Transcript row validation produced a non-rooted wire path.", exception);
                }

                throw new WireDecodeException(exception.Error, rowPath + exception.Path[1..], exception.Message);
            }

            if (encodedRow.Length > MaxRowBytes)
            {
                throw OversizedRow(rowPath, row.RowID);
            }
        }
    }

    private static WireDecodeException OversizedRow(string path, string rowID) =>
        new(WireError.OversizedRow, path, $"Transcript row '{rowID}' exceeds the {MaxRowBytes}-byte row limit.");

    private static WireDecodeException WrongType(string path, string message) =>
        new(WireError.WrongType, path, message);
}
