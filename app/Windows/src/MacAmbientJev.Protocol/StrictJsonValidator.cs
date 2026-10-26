using System.Globalization;
using System.Text;
using System.Text.Json;

namespace MacAmbientJev.Protocol;

/// <summary>Lexical gate for one NDJSON record, matching the Swift engine validator.</summary>
public static class StrictJsonValidator
{
    public const int MaxLineBytes = 1_048_576;
    public const int MaxDepth = 32;

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    // The walk below enforces MaxDepth itself so the error is NestingTooDeep, not a reader failure.
    private static readonly JsonReaderOptions ReaderOptions = new() { MaxDepth = MaxDepth + 1 };

    public static void Validate(ReadOnlySpan<byte> record)
    {
        if (record.Length > MaxLineBytes)
        {
            throw new ProtocolException(ProtocolError.LineTooLong);
        }

        try
        {
            _ = StrictUtf8.GetCharCount(record);
        }
        catch (DecoderFallbackException)
        {
            throw new ProtocolException(ProtocolError.InvalidUtf8);
        }

        if (record.StartsWith("﻿"u8))
        {
            throw new ProtocolException(ProtocolError.ByteOrderMark);
        }

        if (record.IndexOfAny((byte)'\n', (byte)'\r') >= 0)
        {
            throw new ProtocolException(ProtocolError.InvalidJson);
        }

        if (record.IndexOfAnyExcept((byte)' ', (byte)'\t') < 0)
        {
            throw new ProtocolException(ProtocolError.BlankLine);
        }

        Walk(record);
    }

    private static void Walk(ReadOnlySpan<byte> record)
    {
        var reader = new Utf8JsonReader(record, ReaderOptions);

        // One entry per open container: the object's canonical keys, or null for an array.
        var containers = new Stack<HashSet<string>?>();
        var previous = JsonTokenType.None;
        var previousEnd = 0;
        try
        {
            while (reader.Read())
            {
                if (previous == JsonTokenType.None && reader.TokenType != JsonTokenType.StartObject)
                {
                    throw new ProtocolException(ProtocolError.InvalidJson);
                }

                switch (reader.TokenType)
                {
                    case JsonTokenType.StartObject:
                    case JsonTokenType.StartArray:
                        if (containers.Count == MaxDepth)
                        {
                            throw new ProtocolException(ProtocolError.NestingTooDeep);
                        }

                        containers.Push(reader.TokenType == JsonTokenType.StartObject ? new HashSet<string>(StringComparer.Ordinal) : null);
                        break;
                    case JsonTokenType.EndObject:
                    case JsonTokenType.EndArray:
                        containers.Pop();
                        break;
                    case JsonTokenType.PropertyName:
                        // Keys compare after unescaping and NFC normalization, like Swift string equality.
                        if (!containers.Peek()!.Add(WireCheck.CanonicalString(reader.GetString()!)))
                        {
                            throw new ProtocolException(ProtocolError.DuplicateKey);
                        }

                        break;
                    case JsonTokenType.String when reader.ValueIsEscaped:
                        // Unescaping rejects unpaired surrogate escapes.
                        _ = reader.GetString();
                        break;
                    case JsonTokenType.Number:
                        if (!IsFinite(reader.ValueSpan))
                        {
                            throw new ProtocolException(ProtocolError.InvalidNumber);
                        }

                        break;
                }

                previous = reader.TokenType;
                previousEnd = checked((int)reader.BytesConsumed);
            }
        }
        catch (JsonException)
        {
            throw new ProtocolException(ClassifyReaderFailure(record, previous, previousEnd, containers));
        }
        catch (InvalidOperationException)
        {
            throw new ProtocolException(ProtocolError.InvalidJson);
        }
    }

    /// <summary>
    /// Maps a reader failure to the error the Swift validator reports first. A malformed token in value
    /// position that starts like a number, or a number followed by a non-delimiter, is InvalidNumber.
    /// The reader rejects a key that lacks its colon before returning it, so a repeated key there is
    /// still DuplicateKey. Everything else is InvalidJson.
    /// </summary>
    private static ProtocolError ClassifyReaderFailure(ReadOnlySpan<byte> record, JsonTokenType previous, int previousEnd, Stack<HashSet<string>?> containers)
    {
        if (previous == JsonTokenType.Number && previousEnd < record.Length &&
            record[previousEnd] is not ((byte)' ' or (byte)'\t' or (byte)',' or (byte)']' or (byte)'}'))
        {
            return ProtocolError.InvalidNumber;
        }

        var objectKeys = containers.TryPeek(out var top) ? top : null;
        var index = SkipBlank(record, previousEnd);
        bool valuePosition;
        bool keyPosition;
        switch (previous)
        {
            case JsonTokenType.None:
                return ProtocolError.InvalidJson;
            case JsonTokenType.PropertyName:
            case JsonTokenType.StartArray:
                (valuePosition, keyPosition) = (true, false);
                break;
            case JsonTokenType.StartObject:
                (valuePosition, keyPosition) = (false, true);
                break;
            default:
                if (containers.Count == 0 || index == record.Length || record[index] != (byte)',')
                {
                    return ProtocolError.InvalidJson;
                }

                index = SkipBlank(record, index + 1);
                (valuePosition, keyPosition) = (objectKeys is null, objectKeys is not null);
                break;
        }

        if (index == record.Length)
        {
            return ProtocolError.InvalidJson;
        }

        if (valuePosition && record[index] is (byte)'-' or (byte)'+' or (byte)'.' or (byte)'N' or (byte)'I' or >= (byte)'0' and <= (byte)'9')
        {
            return OpensWithFiniteNumber(record[index..]) ? ProtocolError.InvalidJson : ProtocolError.InvalidNumber;
        }

        return keyPosition && OpensWithKeyIn(record[index..], objectKeys!) ? ProtocolError.DuplicateKey : ProtocolError.InvalidJson;
    }

    /// <summary>True when the bytes open with a complete, delimited, finite number, so the failure lies after it.</summary>
    private static bool OpensWithFiniteNumber(ReadOnlySpan<byte> bytes)
    {
        var reader = new Utf8JsonReader(bytes);
        try
        {
            return reader.Read() && reader.TokenType == JsonTokenType.Number && IsFinite(reader.ValueSpan);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool OpensWithKeyIn(ReadOnlySpan<byte> bytes, HashSet<string> keys)
    {
        var reader = new Utf8JsonReader(bytes);
        try
        {
            return reader.Read() && reader.TokenType == JsonTokenType.String && keys.Contains(WireCheck.CanonicalString(reader.GetString()!));
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException)
        {
            return false;
        }
    }

    private static bool IsFinite(ReadOnlySpan<byte> number) =>
        double.TryParse(number, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) && double.IsFinite(value);

    private static int SkipBlank(ReadOnlySpan<byte> record, int index)
    {
        while (index < record.Length && record[index] is (byte)' ' or (byte)'\t')
        {
            index++;
        }

        return index;
    }
}
