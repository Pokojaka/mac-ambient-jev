using System;
using System.Text;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Protocol.Tests;

public sealed class StrictWireCodecTests
{
    [Fact]
    public void DecodesExactIntegerBoundsAndIntegralDecimalRepresentations()
    {
        Assert.Equal(0, Decode<LongBox>("{\"value\":0}").Value);
        Assert.Equal(long.MaxValue, Decode<LongBox>("{\"value\":9223372036854775807}").Value);
        Assert.Equal(long.MinValue, Decode<LongBox>("{\"value\":-9223372036854775808}").Value);
        Assert.Equal(1, Decode<LongBox>("{\"value\":1.0}").Value);
        Assert.Equal(1, Decode<LongBox>("{\"value\":1e0}").Value);
        Assert.Equal(1, Decode<LongBox>("{\"value\":1.0000000000000001}").Value);
        Assert.Equal(12, Decode<LongBox>("{\"value\":1.20e1}").Value);
        Assert.Equal(ulong.MaxValue, Decode<ULongBox>("{\"value\":18446744073709551615}").Value);
        Assert.Equal(0UL, Decode<ULongBox>("{\"value\":0}").Value);

        var signedOverflow = Assert.Throws<WireDecodeException>(() => Decode<LongBox>("{\"value\":9223372036854775808}"));
        Assert.Equal(WireError.OutOfRange, signedOverflow.Error);
        Assert.Equal("$.value", signedOverflow.Path);

        var unsignedOverflow = Assert.Throws<WireDecodeException>(() => Decode<ULongBox>("{\"value\":18446744073709551616}"));
        Assert.Equal(WireError.OutOfRange, unsignedOverflow.Error);
        Assert.Equal("$.value", unsignedOverflow.Path);

        var negativeUnsigned = Assert.Throws<WireDecodeException>(() => Decode<ULongBox>("{\"value\":-1}"));
        Assert.Equal(WireError.OutOfRange, negativeUnsigned.Error);
        Assert.Equal("$.value", negativeUnsigned.Path);

        var fraction = Assert.Throws<WireDecodeException>(() => Decode<LongBox>("{\"value\":1.25}"));
        Assert.Equal(WireError.WrongType, fraction.Error);
        Assert.Equal("$.value", fraction.Path);
    }

    [Fact]
    public void EngineIDsRequireCanonicalPositiveUInt64Strings()
    {
        Assert.Equal(1UL, Decode<IdBox>("{\"id\":\"1\"}").Id.Value);
        Assert.Equal(ulong.MaxValue, Decode<IdBox>("{\"id\":\"18446744073709551615\"}").Id.Value);
        Assert.Equal("{\"id\":\"18446744073709551615\"}", Text(StrictWireCodec.Encode(new IdBox(new EngineID(ulong.MaxValue)))));

        foreach (var id in new[] { "0", "00", "01", "-1", "+1", "18446744073709551616" })
        {
            var exception = Assert.Throws<WireDecodeException>(() => Decode<IdBox>("{\"id\":\"" + id + "\"}"));
            Assert.Equal(WireError.OutOfRange, exception.Error);
            Assert.Equal("$.id", exception.Path);
        }
    }

    [Fact]
    public void MapsWireEnumsAndRejectsUnknownAndUndefinedValues()
    {
        Assert.Equal(EngineSource.SystemAudio, Decode<SourceBox>("{\"source\":\"system_audio\"}").Source);

        var unknown = Assert.Throws<WireDecodeException>(() => Decode<SourceBox>("{\"source\":\"unknown\"}"));
        Assert.Equal(WireError.UnknownValue, unknown.Error);
        Assert.Equal("$.source", unknown.Path);

        var undefined = Assert.Throws<WireDecodeException>(() => StrictWireCodec.Encode(new SourceBox((EngineSource)999)));
        Assert.Equal(WireError.UnknownValue, undefined.Error);
        Assert.Equal("$.source", undefined.Path);
    }

    [Fact]
    public void RequiredNullableMemberDistinguishesAbsenceFromNull()
    {
        var absent = Assert.Throws<WireDecodeException>(() => Decode<NullableBox>("{}"));
        Assert.Equal(WireError.MissingMember, absent.Error);
        Assert.Equal("$.value", absent.Path);

        Assert.Null(Decode<NullableBox>("{\"value\":null}").Value);
        Assert.Equal("present", Decode<NullableBox>("{\"value\":\"present\"}").Value);
        Assert.Null(Decode<NullableIdBox>("{\"id\":null}").Id);
        Assert.Equal(1UL, Decode<NullableIdBox>("{\"id\":\"1\"}").Id!.Value);
        Assert.Equal("{\"id\":null}", Text(StrictWireCodec.Encode(new NullableIdBox(null))));

        var nonNullable = Assert.Throws<WireDecodeException>(() => Decode<RequiredStringBox>("{\"value\":null}"));
        Assert.Equal(WireError.WrongType, nonNullable.Error);
        Assert.Equal("$.value", nonNullable.Path);
    }

    [Fact]
    public void ReportsNestedUnknownMissingWrongAndNullMembersAtTheirPaths()
    {
        var unknown = Assert.Throws<WireDecodeException>(() => Decode<ParentBox>("{\"payload\":{\"text\":\"x\",\"extra\":1},\"rows\":[]}"));
        Assert.Equal(WireError.UnknownMember, unknown.Error);
        Assert.Equal("$.payload.extra", unknown.Path);

        var missing = Assert.Throws<WireDecodeException>(() => Decode<ParentBox>("{\"payload\":{},\"rows\":[]}"));
        Assert.Equal(WireError.MissingMember, missing.Error);
        Assert.Equal("$.payload.text", missing.Path);

        var wrong = Assert.Throws<WireDecodeException>(() => Decode<ParentBox>("{\"payload\":{\"text\":false},\"rows\":[]}"));
        Assert.Equal(WireError.WrongType, wrong.Error);
        Assert.Equal("$.payload.text", wrong.Path);

        var nullObject = Assert.Throws<WireDecodeException>(() => Decode<ParentBox>("{\"payload\":null,\"rows\":[]}"));
        Assert.Equal(WireError.WrongType, nullObject.Error);
        Assert.Equal("$.payload", nullObject.Path);

        var nullElement = Assert.Throws<WireDecodeException>(() => Decode<ParentBox>("{\"payload\":{\"text\":\"x\"},\"rows\":[null]}"));
        Assert.Equal(WireError.WrongType, nullElement.Error);
        Assert.Equal("$.rows[0]", nullElement.Path);
    }

    [Fact]
    public void DecodesAndEncodesFlattenedClosedUnionWithExactSelectedArmKeys()
    {
        const string record = "{\"kind\":\"text\",\"text\":\"hello\",\"version\":1}";
        var decoded = Decode<FlatEnvelope>(record);
        var text = Assert.IsType<TestUnion.TextCase>(decoded.Event);
        Assert.Equal("hello", text.TextValue);
        Assert.Equal(record, Text(StrictWireCodec.Encode(decoded)));

        const string emptyRecord = "{\"kind\":\"empty\",\"version\":2}";
        var empty = Decode<FlatEnvelope>(emptyRecord);
        Assert.IsType<TestUnion.EmptyCase>(empty.Event);
        Assert.Equal(emptyRecord, Text(StrictWireCodec.Encode(empty)));

        var oppositeArm = Assert.Throws<WireDecodeException>(() => Decode<FlatEnvelope>("{\"empty\":null,\"kind\":\"text\",\"text\":\"hello\",\"version\":1}"));
        Assert.Equal(WireError.UnknownMember, oppositeArm.Error);
        Assert.Equal("$.empty", oppositeArm.Path);

        var unknownTag = Assert.Throws<WireDecodeException>(() => Decode<FlatEnvelope>("{\"kind\":\"other\",\"version\":1}"));
        Assert.Equal(WireError.UnknownValue, unknownTag.Error);
        Assert.Equal("$.kind", unknownTag.Path);

        var missingArmField = Assert.Throws<WireDecodeException>(() => Decode<FlatEnvelope>("{\"kind\":\"text\",\"version\":1}"));
        Assert.Equal(WireError.MissingMember, missingArmField.Error);
        Assert.Equal("$.text", missingArmField.Path);
    }

    [Fact]
    public void CanonicalStringsPreserveUnicodeAndEscapeOnlyFoundationRequiredCharacters()
    {
        var text = "日本😀\u007F\u2028\u2029\uFDD0/\b\f\n\r\t\u0000\"\\";
        var encoded = StrictWireCodec.Encode(new TestUnion.TextCase(text));
        Assert.Equal("{\"kind\":\"text\",\"text\":\"日本😀\u007F\u2028\u2029\uFDD0/\\b\\f\\n\\r\\t\\u0000\\\"\\\\\"}", Text(encoded));
        Assert.Equal(text, Assert.IsType<TestUnion.TextCase>(StrictWireCodec.Decode<TestUnion>(encoded)).TextValue);

        var invalidSurrogate = Assert.Throws<WireDecodeException>(() => StrictWireCodec.Encode(new TestUnion.TextCase("bad\uD800")));
        Assert.Equal(WireError.WrongType, invalidSurrogate.Error);
        Assert.Equal("$.text", invalidSurrogate.Path);
    }

    [Fact]
    public void FormatsDoubleWithSwiftThresholdsShortestRoundTripAndNegativeZero()
    {
        AssertDouble(1e-5, "1e-05");
        AssertDouble(1e-4, "0.0001");
        AssertDouble(1e15, "1000000000000000");
        AssertDouble(1e16, "1e+16");
        AssertDouble(double.MaxValue, "1.7976931348623157e+308");
        AssertDouble(BitConverter.Int64BitsToDouble(long.MinValue), "-0");
    }

    [Fact]
    public void UnsupportedNullableMemberTypesFailAsProgrammingErrors()
    {
        Assert.Throws<InvalidOperationException>(() => Decode<UnsupportedNullableBox>("{}"));
        Assert.Throws<InvalidOperationException>(() => StrictWireCodec.Encode(new UnsupportedNullableBox(null)));
    }

    [Fact]
    public void LexicalValidationPrecedesSchemaValidation()
    {
        var duplicate = Assert.Throws<ProtocolException>(() => Decode<LongBox>("{\"value\":1,\"value\":2}"));
        Assert.Equal(ProtocolError.DuplicateKey, duplicate.Error);

        var malformed = Assert.Throws<ProtocolException>(() => Decode<LongBox>("{\"unknown\":"));
        Assert.Equal(ProtocolError.InvalidJson, malformed.Error);
    }

    [Fact]
    public void InvokesWireValidationAfterDecodeAndBeforeEncode()
    {
        var decode = Assert.Throws<WireDecodeException>(() => Decode<ValidatedBox>("{\"text\":\"\"}"));
        Assert.Equal(WireError.Constraint, decode.Error);
        Assert.Equal("$.text", decode.Path);

        var encode = Assert.Throws<WireDecodeException>(() => StrictWireCodec.Encode(new ValidatedBox("")));
        Assert.Equal(WireError.Constraint, encode.Error);
        Assert.Equal("$.text", encode.Path);
    }

    private static T Decode<T>(string record) => StrictWireCodec.Decode<T>(Encoding.UTF8.GetBytes(record));

    private static string Text(byte[] bytes) => Encoding.UTF8.GetString(bytes);

    private static void AssertDouble(double value, string expected) =>
        Assert.Equal("{\"value\":" + expected + "}", Text(StrictWireCodec.Encode(new DoubleBox(value))));

    [WireObject]
    public sealed record LongBox([property: WireMember("value")] long Value);

    [WireObject]
    public sealed record ULongBox([property: WireMember("value")] ulong Value);

    [WireObject]
    public sealed record IdBox([property: WireMember("id")] EngineID Id);

    [WireObject]
    public sealed record SourceBox([property: WireMember("source")] EngineSource Source);

    [WireObject]
    public sealed record NullableBox([property: WireMember("value", IsNullable = true)] string? Value);

    [WireObject]
    public sealed record NullableIdBox([property: WireMember("id", IsNullable = true)] EngineID? Id);

    [WireObject]
    public sealed record RequiredStringBox([property: WireMember("value")] string Value);

    [WireObject]
    public sealed record ChildBox([property: WireMember("text")] string Text);

    [WireObject]
    public sealed record RowBox([property: WireMember("text")] string Text);

    [WireObject]
    public sealed record ParentBox(
        [property: WireMember("payload")] ChildBox Payload,
        [property: WireMember("rows")] RowBox[] Rows);

    public enum TestKind
    {
        [WireValue("text")]
        Text,
        [WireValue("empty")]
        Empty,
    }

    [WireUnion("kind", typeof(TestKind))]
    public abstract record TestUnion
    {
        private TestUnion() { }

        [WireCase("text")]
        public sealed record TextCase([property: WireMember("text")] string TextValue) : TestUnion;

        [WireCase("empty")]
        public sealed record EmptyCase() : TestUnion;
    }

    [WireObject]
    public sealed record FlatEnvelope(
        [property: WireMember("version")] long Version,
        [property: WireFlatten] TestUnion Event);

    [WireObject]
    public sealed record DoubleBox([property: WireMember("value")] double Value);

    [WireObject]
    public sealed record UnsupportedNullableBox([property: WireMember("value", IsNullable = true)] DateTime? Value);

    [WireObject]
    public sealed record ValidatedBox([property: WireMember("text")] string Text) : IWireValidatable
    {
        public void Validate(string path) => WireCheck.Nonempty(Text, path + ".text");
    }
}
