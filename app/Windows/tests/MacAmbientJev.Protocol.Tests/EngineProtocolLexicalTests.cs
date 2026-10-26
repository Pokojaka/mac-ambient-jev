using System;
using System.Text;
using Xunit;

namespace MacAmbientJev.Protocol.Tests;

public sealed class EngineProtocolLexicalTests
{
    [Fact]
    public void duplicateKeysAreRejectedAtEveryObjectDepth()
    {
        Assert.Equal(ProtocolError.DuplicateKey, Error("{\"x\":1,\"x\":2}"));
        Assert.Equal(ProtocolError.DuplicateKey, Error("{\"outer\":{\"x\":1,\"x\":2}}"));
        Assert.Equal(ProtocolError.DuplicateKey, Error("{\"items\":[{\"x\":1,\"x\":2}]}"));
        Assert.Equal(ProtocolError.DuplicateKey, Error("{\"a\":1,\"\\u0061\":2}"));
        Assert.Equal(ProtocolError.DuplicateKey, Error("{\"é\":1,\"e\\u0301\":2}"));

        StrictJsonValidator.Validate(Encoding.UTF8.GetBytes("{\"A\":1,\"a\":2}"));
    }

    [Fact]
    public void duplicateKeysCompareCanonicallyAcrossNoncharacterBoundaries()
    {
        var fffe = char.ConvertFromUtf32(0xFFFE);
        var ffff = char.ConvertFromUtf32(0xFFFF);

        Assert.Equal(ProtocolError.DuplicateKey, Error("{\"" + fffe + "\":1,\"\\uFFFE\":2}"));

        var precomposed = "é" + fffe + "é";
        var decomposed = "e\u0301" + fffe + "e\u0301";
        Assert.Equal(ProtocolError.DuplicateKey, Error("{\"" + precomposed + "\":1,\"" + decomposed + "\":2}"));

        var distinctKeys = "{\"" + fffe + "\":1,\"tail" + fffe + "\":2,\"" + fffe + "head\":3,\"" + fffe + fffe + "\":4,\"" + ffff + "\":5,\"e" + fffe + "\u0301\":6,\"é" + fffe + "\":7}";
        StrictJsonValidator.Validate(Encoding.UTF8.GetBytes(distinctKeys));

        var originalRecord = Encoding.UTF8.GetBytes("{\"" + fffe + "\":\"" + fffe + "\"}");
        var record = (byte[])originalRecord.Clone();
        StrictJsonValidator.Validate(record);
        Assert.Equal(originalRecord, record);
    }

    [Theory]
    [InlineData(0xFFFE)]
    [InlineData(0xFFFF)]
    [InlineData(0x1FFFE)]
    public void acceptsSwiftValidNoncharacterKeys(int scalar)
    {
        var key = char.ConvertFromUtf32(scalar);
        StrictJsonValidator.Validate(Encoding.UTF8.GetBytes("{\"" + key + "\":1}"));
    }

    [Fact]
    public void acceptsSwiftValidNullWhitespaceAndEscapedValues()
    {
        StrictJsonValidator.Validate(Encoding.UTF8.GetBytes("""{"\u0000":1}"""));
        StrictJsonValidator.Validate(Encoding.UTF8.GetBytes("\t { \t \"array\" \t: \t [ \t 1 \t, \t { \t \"ok\" \t: \t true \t} \t] \t } \t"));
        StrictJsonValidator.Validate(Encoding.UTF8.GetBytes("""{"s":"\"\\\/"}"""));
        StrictJsonValidator.Validate(Encoding.UTF8.GetBytes("{\"left\":{\"x\":1},\"right\":{\"x\":2}}"));
    }

    [Fact]
    public void comparesEscapedKeysAndRejectsNonJsonExtensions()
    {
        Assert.Equal(ProtocolError.DuplicateKey, Error("""{"\/":1,"/":2}"""));
        Assert.Equal(ProtocolError.DuplicateKey, Error("""{"\uD83D\uDE00":1,"😀":2}"""));
        Assert.Equal(ProtocolError.InvalidJson, Error(new byte[] { 0x20, 0xEF, 0xBB, 0xBF, 0x7B, 0x7D }));
        Assert.Equal(ProtocolError.InvalidJson, Error("{/* comment */\"x\":1}"));
        Assert.Equal(ProtocolError.InvalidJson, Error("{\"x\":1,}"));
        Assert.Equal(ProtocolError.InvalidJson, Error("{\"x\":[1,]}"));
    }

    [Fact]
    public void depthLimitIsInclusive()
    {
        StrictJsonValidator.Validate(Encoding.UTF8.GetBytes(NestedArrays(StrictJsonValidator.MaxDepth - 1)));
        Assert.Equal(ProtocolError.NestingTooDeep, Error(NestedArrays(StrictJsonValidator.MaxDepth)));

        StrictJsonValidator.Validate(Encoding.UTF8.GetBytes(NestedObjects(StrictJsonValidator.MaxDepth)));
        Assert.Equal(ProtocolError.NestingTooDeep, Error(NestedObjects(StrictJsonValidator.MaxDepth + 1)));
    }

    [Fact]
    public void lineByteLimitIsInclusive()
    {
        const string prefix = "{\"x\":\"";
        const string suffix = "\"}";
        var fill = new string('a', StrictJsonValidator.MaxLineBytes - Encoding.UTF8.GetByteCount(prefix) - Encoding.UTF8.GetByteCount(suffix));
        var atLimit = prefix + fill + suffix;
        Assert.Equal(StrictJsonValidator.MaxLineBytes, Encoding.UTF8.GetByteCount(atLimit));
        StrictJsonValidator.Validate(Encoding.UTF8.GetBytes(atLimit));

        Assert.Equal(ProtocolError.LineTooLong, Error(atLimit + " "));
        var oversizedInvalidUtf8 = new byte[StrictJsonValidator.MaxLineBytes + 1];
        oversizedInvalidUtf8[0] = 0xFF;
        Assert.Equal(ProtocolError.LineTooLong, Error(oversizedInvalidUtf8));
    }

    [Fact]
    public void rejectsInvalidUTF8AndInitialBOM()
    {
        Assert.Equal(ProtocolError.InvalidUtf8, Error(new byte[] { 0x7B, 0x22, 0x78, 0x22, 0x3A, 0x22, 0xC0, 0xAF, 0x22, 0x7D }));
        Assert.Equal(ProtocolError.ByteOrderMark, Error(new byte[] { 0xEF, 0xBB, 0xBF, (byte)'{', (byte)'}' }));

        byte[][] malformedUtf8 =
        [
            [0x80],
            [0xE2, 0x82],
            [0xED, 0xA0, 0x80],
            [0xF4, 0x90, 0x80, 0x80],
            [0xF5, 0x80, 0x80, 0x80],
        ];
        foreach (var invalidSequence in malformedUtf8)
        {
            var record = new byte[] { (byte)'{', (byte)'"', (byte)'x', (byte)'"', (byte)':', (byte)'"' }
                .Concat(invalidSequence)
                .Concat(new byte[] { (byte)'"', (byte)'}' })
                .ToArray();
            Assert.Equal(ProtocolError.InvalidUtf8, Error(record));
        }
    }

    [Fact]
    public void rejectsBlankLinesAndLiteralLineBreaks()
    {
        Assert.Equal(ProtocolError.BlankLine, Error(Array.Empty<byte>()));
        Assert.Equal(ProtocolError.BlankLine, Error(new byte[] { 0x20, 0x09, 0x20 }));
        Assert.Equal(ProtocolError.InvalidJson, Error(new byte[] { 0x7B, 0x22, 0x78, 0x22, 0x3A, 0x31, 0x7D, 0x0A }));
        Assert.Equal(ProtocolError.InvalidJson, Error(new byte[] { 0x7B, 0x22, 0x78, 0x22, 0x3A, 0x31, 0x7D, 0x0D }));
        Assert.Equal(ProtocolError.InvalidJson, Error(new byte[] { 0x7B, 0x22, 0x78, 0x22, 0x3A, 0x22, 0x61, 0x0A, 0x62, 0x22, 0x7D }));
        Assert.Equal(ProtocolError.ByteOrderMark, Error(new byte[] { 0xEF, 0xBB, 0xBF, 0x0A }));
    }

    [Fact]
    public void enforcesJSONNumberGrammarAndFiniteValues()
    {
        string[] malformedNumbers =
        [
            "{\"n\":01}",
            "{\"n\":-}",
            "{\"n\":.1}",
            "{\"n\":+1}",
            "{\"n\":1.}",
            "{\"n\":1e}",
            "{\"n\":1e+}",
            "{\"n\":0x1}",
            "{\"n\":--1}",
            "{\"n\":1.0.0}",
            "{\"n\":1abc}",
            "{\"n\":1/2}",
        ];
        foreach (var record in malformedNumbers)
        {
            Assert.Equal(ProtocolError.InvalidNumber, Error(record));
        }

        foreach (var record in new[] { "{\"n\":NaN}", "{\"n\":Infinity}", "{\"n\":-Infinity}", "{\"n\":1e9999}" })
        {
            Assert.Equal(ProtocolError.InvalidNumber, Error(record));
        }

        string[] finiteNumbers =
        [
            "-0",
            "-0.0",
            "1e-9999",
            "-1e-9999",
            "9223372036854775807",
            "9223372036854775808",
            "18446744073709551615",
            "18446744073709551616",
            "-9223372036854775808",
            "-9223372036854775809",
            "1" + new string('0', 100),
            "1.7976931348623157e308",
        ];
        foreach (var number in finiteNumbers)
        {
            StrictJsonValidator.Validate(Encoding.UTF8.GetBytes("{\"n\":" + number + "}"));
        }

        Assert.Equal(ProtocolError.InvalidNumber, Error("{\"n\":" + new string('9', 309) + "}"));
        Assert.Equal(ProtocolError.InvalidNumber, Error("{\"n\":1.7976931348623159e308}"));
    }

    [Fact]
    public void rejectsMalformedStringsAndAcceptsUnicodeEscapes()
    {
        string[] malformed =
        [
            "{\"s\":\"bad\\q\"}",
            "{\"s\":\"\\uD800\"}",
            "{\"s\":\"\\uDC00\"}",
            "{\"s\":\"\\uD800\\u0041\"}",
            "{\"s\":\"\\uD800x\"}",
            "{\"s\":\"\\u12G4\"}",
            "{\"s\":\"\\u123\"}",
            "{\"s\":\"\\u",
            "{\"s\":\"unterminated}",
            "{\"s\":\"incomplete\\",
            "{\"s\":\"slash at end\\\"}",
        ];
        foreach (var record in malformed)
        {
            Assert.Equal(ProtocolError.InvalidJson, Error(record));
        }

        for (var control = 0; control < 0x20; control++)
        {
            var record = new byte[] { (byte)'{', (byte)'"', (byte)'s', (byte)'"', (byte)':', (byte)'"', (byte)control, (byte)'"', (byte)'}' };
            Assert.Equal(ProtocolError.InvalidJson, Error(record));
        }

        StrictJsonValidator.Validate(Encoding.UTF8.GetBytes("""{"emoji":"😀","japanese":"日本語","newline":"first\nsecond","pair":"\uD83D\uDE00","controls":"\b\f\n\r\t\u0000\u001F"}"""));
        StrictJsonValidator.Validate(Encoding.UTF8.GetBytes("{\"bom\":\"\uFEFF\"}"));
        StrictJsonValidator.Validate(Encoding.UTF8.GetBytes("{\"noncharacters\":\"" + char.ConvertFromUtf32(0xFDD0) + char.ConvertFromUtf32(0x1FFFE) + "\"}"));
    }

    [Fact]
    public void requiresObjectRootAndCompleteInput()
    {
        Assert.Equal(ProtocolError.InvalidJson, Error("[]"));
        Assert.Equal(ProtocolError.InvalidJson, Error("null"));
        Assert.Equal(ProtocolError.InvalidJson, Error("{} {}"));
        Assert.Equal(ProtocolError.InvalidJson, Error("{}x"));
        Assert.NotNull(Error("{\"x\":true,}"));
        Assert.NotNull(Error("{\"x\":}"));

        string[] malformedGrammar =
        [
            "{",
            "{\"x\"",
            "{\"x\" 1}",
            "{\"x\":1",
            "{\"x\":1 \"y\":2}",
            "{\"x\":1,,\"y\":2}",
            "{\"x\":,}",
            "{\"x\":[,]}",
            "{\"x\":[1,,2]}",
            "{\"x\":[1 2]}",
            "{\"x\":{]}",
            "{\"x\":true \"y\":false}",
            "{\"x\":nul}",
            "{\"x\":True}",
            "{\"x\":undefined}",
            "{\"x\":1}garbage",
        ];
        foreach (var record in malformedGrammar)
        {
            Assert.Equal(ProtocolError.InvalidJson, Error(record));
        }

        StrictJsonValidator.Validate(Encoding.UTF8.GetBytes("{\"array\":[],\"object\":{},\"bool\":true,\"null\":null}"));
    }

    [Fact]
    public void engineIDUsesPositiveCanonicalDecimalStrings()
    {
        Assert.Equal(1UL, CanonicalUInt64.Parse("1"));
        Assert.Equal(ulong.MaxValue, CanonicalUInt64.Parse("18446744073709551615"));
        Assert.True(CanonicalUInt64.Parse("1") < CanonicalUInt64.Parse("18446744073709551615"));

        foreach (var value in new[] { "", "0", "00", "01", "+1", "-1", " 1", "١", "18446744073709551616", "1 ", "1x", new string('9', 1000) })
        {
            Assert.Equal(ProtocolError.InvalidId, CanonicalIdError(value));
        }
    }

    private static ProtocolError? Error(string record) => Error(Encoding.UTF8.GetBytes(record));

    private static ProtocolError? Error(byte[] record) => Error((ReadOnlySpan<byte>)record);

    private static ProtocolError? Error(ReadOnlySpan<byte> record)
    {
        try
        {
            StrictJsonValidator.Validate(record);
            return null;
        }
        catch (ProtocolException exception)
        {
            return exception.Error;
        }
    }

    private static ProtocolError? CanonicalIdError(string value)
    {
        try
        {
            _ = CanonicalUInt64.Parse(value);
            return null;
        }
        catch (ProtocolException exception)
        {
            return exception.Error;
        }
    }

    private static string NestedArrays(int arrayCount) => "{\"value\":" + new string('[', arrayCount) + "0" + new string(']', arrayCount) + "}";

    private static string NestedObjects(int depth)
    {
        var value = "0";
        for (var count = 0; count < depth; count++)
        {
            value = "{\"value\":" + value + "}";
        }

        return value;
    }
}
