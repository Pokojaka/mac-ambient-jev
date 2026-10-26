using System.Globalization;
using System.Text;

namespace MacAmbientJev.Protocol;

public static class StrictJsonValidator
{
    public const int MaxLineBytes = 1_048_576;
    public const int MaxDepth = 32;

    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

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

        if (record.Length >= 3 && record[0] == 0xEF && record[1] == 0xBB && record[2] == 0xBF)
        {
            throw new ProtocolException(ProtocolError.ByteOrderMark);
        }

        if (record.Contains((byte)'\n') || record.Contains((byte)'\r'))
        {
            throw new ProtocolException(ProtocolError.InvalidJson);
        }

        var blank = true;
        foreach (var value in record)
        {
            if (value is not (0x20 or 0x09))
            {
                blank = false;
                break;
            }
        }

        if (blank)
        {
            throw new ProtocolException(ProtocolError.BlankLine);
        }

        new Parser(record).ValidateObject();
    }

    private static string NormalizeKey(string key)
    {
        var separatorIndex = key.IndexOf('\uFFFE');
        if (separatorIndex < 0)
        {
            return key.Normalize(NormalizationForm.FormC);
        }

        // U+FFFE is inert for normalization, but .NET Normalize rejects it.
        var builder = new StringBuilder(key.Length);
        var segmentStart = 0;
        while (separatorIndex >= 0)
        {
            builder.Append(key[segmentStart..separatorIndex].Normalize(NormalizationForm.FormC));
            builder.Append('\uFFFE');
            segmentStart = separatorIndex + 1;
            separatorIndex = key.IndexOf('\uFFFE', segmentStart);
        }

        builder.Append(key[segmentStart..].Normalize(NormalizationForm.FormC));
        return builder.ToString();
    }

    private ref struct Parser
    {
        private readonly ReadOnlySpan<byte> _bytes;
        private int _index;

        public Parser(ReadOnlySpan<byte> bytes)
        {
            _bytes = bytes;
            _index = 0;
        }

        private byte? CurrentByte => _index < _bytes.Length ? _bytes[_index] : null;

        public void ValidateObject()
        {
            SkipWhitespace();
            if (CurrentByte != (byte)'{')
            {
                throw new ProtocolException(ProtocolError.InvalidJson);
            }

            ParseObject(1);
            SkipWhitespace();
            if (_index != _bytes.Length)
            {
                throw new ProtocolException(ProtocolError.InvalidJson);
            }
        }

        private void SkipWhitespace()
        {
            while (CurrentByte is 0x20 or 0x09)
            {
                _index++;
            }
        }

        private void ParseObject(int depth)
        {
            if (depth > MaxDepth)
            {
                throw new ProtocolException(ProtocolError.NestingTooDeep);
            }

            if (CurrentByte != (byte)'{')
            {
                throw new ProtocolException(ProtocolError.InvalidJson);
            }

            _index++;
            SkipWhitespace();
            if (CurrentByte == (byte)'}')
            {
                _index++;
                return;
            }

            var keys = new HashSet<string>(StringComparer.Ordinal);
            while (true)
            {
                if (CurrentByte != (byte)'"')
                {
                    throw new ProtocolException(ProtocolError.InvalidJson);
                }

                var key = NormalizeKey(ParseString());
                if (!keys.Add(key))
                {
                    throw new ProtocolException(ProtocolError.DuplicateKey);
                }

                SkipWhitespace();
                if (CurrentByte != (byte)':')
                {
                    throw new ProtocolException(ProtocolError.InvalidJson);
                }

                _index++;
                SkipWhitespace();
                ParseValue(depth);
                SkipWhitespace();
                if (CurrentByte == (byte)'}')
                {
                    _index++;
                    return;
                }

                if (CurrentByte != (byte)',')
                {
                    throw new ProtocolException(ProtocolError.InvalidJson);
                }

                _index++;
                SkipWhitespace();
            }
        }

        private void ParseArray(int depth)
        {
            if (depth > MaxDepth)
            {
                throw new ProtocolException(ProtocolError.NestingTooDeep);
            }

            if (CurrentByte != (byte)'[')
            {
                throw new ProtocolException(ProtocolError.InvalidJson);
            }

            _index++;
            SkipWhitespace();
            if (CurrentByte == (byte)']')
            {
                _index++;
                return;
            }

            while (true)
            {
                ParseValue(depth);
                SkipWhitespace();
                if (CurrentByte == (byte)']')
                {
                    _index++;
                    return;
                }

                if (CurrentByte != (byte)',')
                {
                    throw new ProtocolException(ProtocolError.InvalidJson);
                }

                _index++;
                SkipWhitespace();
            }
        }

        private void ParseValue(int containerDepth)
        {
            SkipWhitespace();
            switch (CurrentByte)
            {
                case (byte)'{':
                case (byte)'[':
                {
                    var depth = containerDepth + 1;
                    if (depth > MaxDepth)
                    {
                        throw new ProtocolException(ProtocolError.NestingTooDeep);
                    }

                    if (CurrentByte == (byte)'{')
                    {
                        ParseObject(depth);
                    }
                    else
                    {
                        ParseArray(depth);
                    }

                    break;
                }
                case (byte)'"':
                    _ = ParseString();
                    break;
                case (byte)'t':
                    ParseLiteral("true"u8);
                    break;
                case (byte)'f':
                    ParseLiteral("false"u8);
                    break;
                case (byte)'n':
                    ParseLiteral("null"u8);
                    break;
                case (byte)'N':
                case (byte)'I':
                case (byte)'+':
                case (byte)'.':
                    throw new ProtocolException(ProtocolError.InvalidNumber);
                case (byte)'-':
                case >= (byte)'0' and <= (byte)'9':
                    ParseNumber();
                    break;
                case null:
                default:
                    throw new ProtocolException(ProtocolError.InvalidJson);
            }
        }

        private void ParseLiteral(ReadOnlySpan<byte> literal)
        {
            if (_index + literal.Length > _bytes.Length || !_bytes.Slice(_index, literal.Length).SequenceEqual(literal))
            {
                throw new ProtocolException(ProtocolError.InvalidJson);
            }

            _index += literal.Length;
        }

        private void ParseNumber()
        {
            var start = _index;
            if (CurrentByte == (byte)'-')
            {
                _index++;
            }

            if (CurrentByte is not byte first)
            {
                throw new ProtocolException(ProtocolError.InvalidNumber);
            }

            if (first == (byte)'0')
            {
                _index++;
                if (CurrentByte is byte next && IsDigit(next))
                {
                    throw new ProtocolException(ProtocolError.InvalidNumber);
                }
            }
            else if (first is >= (byte)'1' and <= (byte)'9')
            {
                _index++;
                while (CurrentByte is byte digit && IsDigit(digit))
                {
                    _index++;
                }
            }
            else
            {
                throw new ProtocolException(ProtocolError.InvalidNumber);
            }

            if (CurrentByte == (byte)'.')
            {
                _index++;
                if (CurrentByte is not byte digit || !IsDigit(digit))
                {
                    throw new ProtocolException(ProtocolError.InvalidNumber);
                }

                do
                {
                    _index++;
                }
                while (CurrentByte is byte fractionDigit && IsDigit(fractionDigit));
            }

            if (CurrentByte is (byte)'e' or (byte)'E')
            {
                _index++;
                if (CurrentByte is (byte)'+' or (byte)'-')
                {
                    _index++;
                }

                if (CurrentByte is not byte exponentDigit || !IsDigit(exponentDigit))
                {
                    throw new ProtocolException(ProtocolError.InvalidNumber);
                }

                do
                {
                    _index++;
                }
                while (CurrentByte is byte exponentTail && IsDigit(exponentTail));
            }

            if (CurrentByte is byte delimiter && delimiter is not (0x20 or 0x09 or 0x2C or 0x5D or 0x7D))
            {
                throw new ProtocolException(ProtocolError.InvalidNumber);
            }

            if (!double.TryParse(_bytes[start.._index], NumberStyles.Float, CultureInfo.InvariantCulture, out var value) || !double.IsFinite(value))
            {
                throw new ProtocolException(ProtocolError.InvalidNumber);
            }
        }

        private static bool IsDigit(byte value) => value is >= (byte)'0' and <= (byte)'9';

        private string ParseString()
        {
            if (CurrentByte != (byte)'"')
            {
                throw new ProtocolException(ProtocolError.InvalidJson);
            }

            _index++;
            var builder = new StringBuilder();
            var chunkStart = _index;
            while (CurrentByte is byte value)
            {
                if (value == (byte)'"')
                {
                    AppendUtf8Chunk(builder, chunkStart, _index);
                    _index++;
                    return builder.ToString();
                }

                if (value < 0x20)
                {
                    throw new ProtocolException(ProtocolError.InvalidJson);
                }

                if (value != (byte)'\\')
                {
                    _index++;
                    continue;
                }

                AppendUtf8Chunk(builder, chunkStart, _index);
                _index++;
                if (CurrentByte is not byte escape)
                {
                    throw new ProtocolException(ProtocolError.InvalidJson);
                }

                switch (escape)
                {
                    case (byte)'"':
                        builder.Append('"');
                        _index++;
                        break;
                    case (byte)'\\':
                        builder.Append('\\');
                        _index++;
                        break;
                    case (byte)'/':
                        builder.Append('/');
                        _index++;
                        break;
                    case (byte)'b':
                        builder.Append('\b');
                        _index++;
                        break;
                    case (byte)'f':
                        builder.Append('\f');
                        _index++;
                        break;
                    case (byte)'n':
                        builder.Append('\n');
                        _index++;
                        break;
                    case (byte)'r':
                        builder.Append('\r');
                        _index++;
                        break;
                    case (byte)'t':
                        builder.Append('\t');
                        _index++;
                        break;
                    case (byte)'u':
                    {
                        var highOrScalar = ParseHexCodeUnit();
                        if (highOrScalar is >= 0xD800 and <= 0xDBFF)
                        {
                            if (CurrentByte != (byte)'\\' || _index + 1 >= _bytes.Length || _bytes[_index + 1] != (byte)'u')
                            {
                                throw new ProtocolException(ProtocolError.InvalidJson);
                            }

                            _index++;
                            var low = ParseHexCodeUnit();
                            if (low is < 0xDC00 or > 0xDFFF)
                            {
                                throw new ProtocolException(ProtocolError.InvalidJson);
                            }

                            builder.Append(char.ConvertFromUtf32(0x10000 + ((highOrScalar - 0xD800) << 10) + (low - 0xDC00)));
                        }
                        else if (highOrScalar is >= 0xDC00 and <= 0xDFFF)
                        {
                            throw new ProtocolException(ProtocolError.InvalidJson);
                        }
                        else
                        {
                            builder.Append((char)highOrScalar);
                        }

                        break;
                    }
                    default:
                        throw new ProtocolException(ProtocolError.InvalidJson);
                }

                chunkStart = _index;
            }

            throw new ProtocolException(ProtocolError.InvalidJson);
        }

        private void AppendUtf8Chunk(StringBuilder builder, int start, int end)
        {
            if (end > start)
            {
                builder.Append(StrictUtf8.GetString(_bytes[start..end]));
            }
        }

        private ushort ParseHexCodeUnit()
        {
            if (CurrentByte != (byte)'u')
            {
                throw new ProtocolException(ProtocolError.InvalidJson);
            }

            _index++;
            if (_index + 4 > _bytes.Length)
            {
                throw new ProtocolException(ProtocolError.InvalidJson);
            }

            ushort value = 0;
            for (var count = 0; count < 4; count++)
            {
                if (!TryHexValue(_bytes[_index], out var digit))
                {
                    throw new ProtocolException(ProtocolError.InvalidJson);
                }

                value = (ushort)((value << 4) | digit);
                _index++;
            }

            return value;
        }

        private static bool TryHexValue(byte value, out byte digit)
        {
            switch (value)
            {
                case >= (byte)'0' and <= (byte)'9':
                    digit = (byte)(value - (byte)'0');
                    return true;
                case >= (byte)'A' and <= (byte)'F':
                    digit = (byte)(value - (byte)'A' + 10);
                    return true;
                case >= (byte)'a' and <= (byte)'f':
                    digit = (byte)(value - (byte)'a' + 10);
                    return true;
                default:
                    digit = 0;
                    return false;
            }
        }
    }
}
