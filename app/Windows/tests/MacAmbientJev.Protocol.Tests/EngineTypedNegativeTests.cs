using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Protocol.Tests;

public sealed class EngineTypedNegativeTests
{
    private const string Hello = """{"version":1,"request_id":"1","command":"hello","payload":{}}""";
    private const string DeviceStart = """{"version":1,"request_id":"1","command":"recording.start","payload":{"source":"microphone","device":{"kind":"default"}}}""";
    private const string Accepted = """{"version":1,"sequence":"1","request_id":"1","event":"accepted","payload":{"command":"hello"}}""";
    private const string CompletedEmpty = """{"version":1,"sequence":"1","request_id":"1","event":"completed","payload":{"command":"models.prepare","result":{}}}""";
    private const string CompletedRead = """{"version":1,"sequence":"1","request_id":"1","event":"completed","payload":{"command":"transcript.read","result":{"session_id":"s","revision":"1","rows":[],"next_cursor":null,"previous_cursor":null}}}""";
    private const string ProgressOutput = """{"version":1,"sequence":"1","request_id":null,"event":"progress","payload":{"stage":"asr","completed_units":1,"total_units":null,"session_id":null}}""";
    private const string Row = """{"row_id":"r","start_ms":0,"end_ms":1,"text":"text","headings":[],"clause_state":null}""";
    private const string TranscriptPage = """{"session_id":"s","revision":"1","rows":[{"row_id":"r","start_ms":0,"end_ms":1,"text":"text","headings":[],"clause_state":null}],"next_cursor":null,"previous_cursor":null}""";
    private const string State = """{"revision":"1","screen":"idle","setup":"ready","profile_setup":{"evaluation":null},"resource_protection":{"hold_reasons":[]},"recovery":"completed","recording":null,"queue":[],"failures":[],"presentation":{"recording_status_text":"Idle","recording_tone":"neutral","preparation_phase":"ready","preparation_status_text":null,"recovery_status_text":null,"processing_status_text":null,"live_failure_notices":[],"silence_warning_active":false,"silence_warning_text":null,"audio_gap_count":0,"audio_gap_text":null,"processing_indicator":"idle"}}""";
    private const string ReadableMetadata = """{"kind":"readable","created_at":0,"source":{"kind":"microphone"},"audio":{"kind":"available"},"has_transcript":false}""";

    [Fact]
    public void UnknownMembersAreRejectedAtRepresentativeWireObjects()
    {
        (Type Type, string Json, WireError Error, string Parent, string Member, string Path)[] cases =
        [
            (typeof(EngineRequest), Hello, WireError.UnknownMember, "$", "extra", "$.extra"),
            (typeof(EngineRequest), Hello, WireError.UnknownMember, "$.payload", "extra", "$.payload.extra"),
            (typeof(EngineRequest), DeviceStart, WireError.UnknownMember, "$.payload.device", "id", "$.payload.device.id"),
            (typeof(EngineTranscriptPage), TranscriptPage, WireError.UnknownMember, "$.rows[0]", "extra", "$.rows[0].extra"),
            (typeof(EngineOutput), CompletedRead, WireError.UnknownMember, "$.payload.result", "extra", "$.payload.result.extra"),
            (typeof(EngineOutput), CompletedEmpty, WireError.UnknownMember, "$.payload.result", "extra", "$.payload.result.extra"),
            (typeof(EngineOutput), Accepted, WireError.UnknownMember, "$.payload", "extra", "$.payload.extra"),
        ];

        foreach (var item in cases)
        {
            var root = JsonNode.Parse(item.Json)!;
            AddMember(root, item.Parent, item.Member, JsonValue.Create("reject"));
            AssertError(item.Type, root.ToJsonString(), item.Error, item.Path);
        }
    }

    [Fact]
    public void MissingMembersAreRejectedAcrossObjectsAndDiscriminatedPayloads()
    {
        (Type Type, string Json, WireError Error, string Path)[] cases =
        [
            (typeof(EngineDeviceInfo), """{"name":"Microphone","is_default":true}""", WireError.MissingMember, "$.id"),
            (typeof(EngineRequest), """{"version":1,"request_id":"1","payload":{}}""", WireError.MissingMember, "$.command"),
            (typeof(EngineRequest), """{"version":1,"request_id":"1","command":"hello"}""", WireError.MissingMember, "$.payload"),
            (typeof(EngineOutput), """{"version":1,"sequence":"1","request_id":"1","payload":{"command":"hello"}}""", WireError.MissingMember, "$.event"),
            (typeof(EngineOutput), """{"version":1,"sequence":"1","request_id":"1","event":"completed","payload":{"command":"hello"}}""", WireError.MissingMember, "$.payload.result"),
            (typeof(EngineOutput), """{"version":1,"sequence":"1","request_id":"1","event":"completed","payload":{"result":{}}}""", WireError.MissingMember, "$.payload.command"),
            (typeof(EngineRequest), """{"version":1,"request_id":"1","command":"recording.start","payload":{"source":"microphone","device":{"kind":"id"}}}""", WireError.MissingMember, "$.payload.device.id"),
            (typeof(EngineTranscriptPage), """{"session_id":"s","revision":"1","rows":[{"row_id":"r","start_ms":0,"end_ms":1,"headings":[],"clause_state":null}],"next_cursor":null,"previous_cursor":null}""", WireError.MissingMember, "$.rows[0].text"),
        ];

        foreach (var item in cases)
        {
            AssertError(item.Type, item.Json, item.Error, item.Path);
        }
    }

    [Fact]
    public void NullableMembersDistinguishAbsenceFromExplicitNull()
    {
        (Type Type, string Json, WireError Error, string Path)[] cases =
        [
            (typeof(EngineSessionListPayload), """{"cursor":null,"limit":20}""", WireError.MissingMember, "$.cursor"),
            (typeof(EngineTranscriptReadPayload), """{"session_id":"s","revision":null,"cursor":null,"limit":20}""", WireError.MissingMember, "$.revision"),
            (typeof(EngineProgressPayload), """{"stage":"asr","completed_units":1,"total_units":null,"session_id":null}""", WireError.MissingMember, "$.total_units"),
            (typeof(EngineTranscriptRow), Row, WireError.MissingMember, "$.clause_state"),
            (typeof(EngineState), State, WireError.MissingMember, "$.recording"),
            (typeof(EngineOutput), ProgressOutput, WireError.MissingMember, "$.request_id"),
        ];

        foreach (var item in cases)
        {
            var absent = JsonNode.Parse(item.Json)!;
            Assert.True(RemoveAtPath(absent, item.Path), $"Expected member at {item.Path}.");
            AssertError(item.Type, absent.ToJsonString(), item.Error, item.Path);

            var explicitNull = JsonNode.Parse(item.Json)!;
            SetAtPath(explicitNull, item.Path, null);
            _ = Decode(item.Type, explicitNull.ToJsonString());
        }
    }

    [Fact]
    public void WrongJsonCategoriesAreRejectedAtTheirWirePaths()
    {
        (Type Type, string Json, WireError Error, string Path)[] cases =
        [
            (typeof(EngineSessionPayload), """{"session_id":1}""", WireError.WrongType, "$.session_id"),
            (typeof(EngineDeviceInfo), """{"id":"d","name":"Mic","is_default":"true"}""", WireError.WrongType, "$.is_default"),
            (typeof(EngineTranscriptRow), """{"row_id":"r","start_ms":1.5,"end_ms":2,"text":"text","headings":[],"clause_state":null}""", WireError.WrongType, "$.start_ms"),
            (typeof(EngineTranscriptRow), """{"row_id":"r","start_ms":"1","end_ms":2,"text":"text","headings":[],"clause_state":null}""", WireError.WrongType, "$.start_ms"),
            (typeof(EngineTranscriptRow), """{"row_id":"r","start_ms":true,"end_ms":2,"text":"text","headings":[],"clause_state":null}""", WireError.WrongType, "$.start_ms"),
            (typeof(EngineSessionMetadata), """{"kind":"readable","created_at":"1","source":{"kind":"microphone"},"audio":{"kind":"available"},"has_transcript":false}""", WireError.WrongType, "$.created_at"),
            (typeof(EngineProgressPayload), """{"stage":"asr","completed_units":"1","total_units":null,"session_id":null}""", WireError.WrongType, "$.completed_units"),
            (typeof(EngineAcceptedPayload), """{"command":1}""", WireError.WrongType, "$.command"),
            (typeof(EngineTranscriptRow), """{"row_id":"r","start_ms":0,"end_ms":1,"text":"text","headings":{},"clause_state":null}""", WireError.WrongType, "$.headings"),
            (typeof(EngineRecordingStartPayload), """{"source":"microphone","device":[]}""", WireError.WrongType, "$.device"),
            (typeof(EngineRecordingStartPayload), """{"source":"microphone","device":"default"}""", WireError.WrongType, "$.device"),
            (typeof(EngineDevice), """{"kind":1}""", WireError.WrongType, "$.kind"),
            (typeof(EngineDevice), """{"kind":null}""", WireError.WrongType, "$.kind"),
            (typeof(EngineTranscriptPage), """{"session_id":"s","revision":"1","rows":[null],"next_cursor":null,"previous_cursor":null}""", WireError.WrongType, "$.rows[0]"),
            (typeof(EngineSessionPayload), """{"session_id":null}""", WireError.WrongType, "$.session_id"),
        ];

        foreach (var item in cases)
        {
            AssertError(item.Type, item.Json, item.Error, item.Path);
        }
    }

    [Fact]
    public void UnknownEnumValuesAndUnionTagsAreRejectedAtTheirWirePaths()
    {
        (Type Type, string Json, WireError Error, string Path)[] cases =
        [
            (typeof(EngineRequest), """{"version":1,"request_id":"1","command":"future.command","payload":{}}""", WireError.UnknownValue, "$.command"),
            (typeof(EngineOutput), """{"version":1,"sequence":"1","request_id":"1","event":"completed","payload":{"command":"future.command","result":{}}}""", WireError.UnknownValue, "$.payload.command"),
            (typeof(EngineOutput), """{"version":1,"sequence":"1","request_id":null,"event":"future.event","payload":{}}""", WireError.UnknownValue, "$.event"),
            (typeof(EngineRequest), """{"version":1,"request_id":"1","command":"recording.start","payload":{"source":"microphone","device":{"kind":"future"}}}""", WireError.UnknownValue, "$.payload.device.kind"),
            (typeof(EngineDevicesListPayload), """{"source":"future"}""", WireError.UnknownValue, "$.source"),
            (typeof(EngineTranscriptRow), """{"row_id":"r","start_ms":0,"end_ms":1,"text":"text","headings":[],"clause_state":"future"}""", WireError.UnknownValue, "$.clause_state"),
            (typeof(EngineTranscriptRow), """{"row_id":"r","start_ms":0,"end_ms":1,"text":"text","headings":["Speaker 8"],"clause_state":null}""", WireError.UnknownValue, "$.headings[0]"),
        ];

        foreach (var item in cases)
        {
            AssertError(item.Type, item.Json, item.Error, item.Path);
        }
    }

    [Fact]
    public void RequestIDsRequireCanonicalPositiveUInt64DecimalStrings()
    {
        var cases = new[] { "", "0", "01", "+1", "-1", " 1", "1 ", "١", "18446744073709551616" }
            .Select(value => (Type: typeof(EngineRequest), Json: Request("hello", "{}", value), Error: WireError.OutOfRange, Path: "$.request_id"))
            .ToArray();
        foreach (var item in cases)
        {
            AssertError(item.Type, item.Json, item.Error, item.Path);
        }

        foreach (var id in new[] { "1", "18446744073709551615" })
        {
            var request = Assert.IsType<EngineRequest>(Decode(typeof(EngineRequest), Request("hello", "{}", id)));
            Assert.Equal(id, request.RequestID.RawValue);
        }

        var revision = Request("transcript.read", "{\"session_id\":\"s\",\"revision\":\"01\",\"cursor\":null,\"limit\":1}");
        AssertError(typeof(EngineRequest), revision, WireError.OutOfRange, "$.payload.revision");
    }

    private static string Request(string command, string payload, string id = "1") =>
        "{\"version\":1,\"request_id\":" + System.Text.Json.JsonSerializer.Serialize(id) + ",\"command\":" +
        System.Text.Json.JsonSerializer.Serialize(command) + ",\"payload\":" + payload + "}";

    private static object Decode(Type type, string json)
    {
        var bytes = Encoding.UTF8.GetBytes(json);
        if (type == typeof(EngineRequest)) return EngineCodec.DecodeRequest(bytes);
        if (type == typeof(EngineOutput)) return EngineCodec.DecodeOutput(bytes);
        return StrictWireCodec.Decode(type, bytes);
    }

    private static void AssertError(Type type, string json, WireError error, string path)
    {
        var exception = Assert.Throws<WireDecodeException>(() => Decode(type, json));
        Assert.Equal(error, exception.Error);
        Assert.Equal(path, exception.Path);
    }

    private static void AddMember(JsonNode root, string parentPath, string name, JsonNode? value) =>
        GetAtPath(root, parentPath).AsObject().Add(name, value?.DeepClone());

    private static bool RemoveAtPath(JsonNode root, string path)
    {
        var parts = PathParts(path);
        var parent = Resolve(root, parts, parts.Count - 1);
        var member = parts[^1];
        if (member[0] == '#') throw new InvalidOperationException("Removal targets a member, not an array element.");
        return parent.AsObject().Remove(member);
    }

    private static void SetAtPath(JsonNode root, string path, JsonNode? value)
    {
        var parts = PathParts(path);
        var parent = Resolve(root, parts, parts.Count - 1);
        var last = parts[^1];
        if (last[0] == '#') parent.AsArray()[int.Parse(last[1..], CultureInfo.InvariantCulture)] = value?.DeepClone();
        else parent.AsObject()[last] = value?.DeepClone();
    }

    private static JsonNode GetAtPath(JsonNode root, string path)
    {
        var parts = PathParts(path);
        return Resolve(root, parts, parts.Count);
    }

    private static JsonNode Resolve(JsonNode root, IReadOnlyList<string> parts, int count)
    {
        var current = root;
        for (var index = 0; index < count; index++)
        {
            var part = parts[index];
            current = part[0] == '#'
                ? current.AsArray()[int.Parse(part[1..], CultureInfo.InvariantCulture)]!
                : current.AsObject()[part]!;
        }

        return current;
    }

    private static List<string> PathParts(string path)
    {
        var parts = new List<string>();
        for (var index = 1; index < path.Length;)
        {
            if (path[index] == '.')
            {
                var start = ++index;
                while (index < path.Length && path[index] is not '.' and not '[') index++;
                parts.Add(path[start..index]);
            }
            else if (path[index] == '[')
            {
                var end = path.IndexOf(']', index);
                if (end < 0) throw new FormatException("Unclosed array index in JSON path.");
                parts.Add("#" + path[(index + 1)..end]);
                index = end + 1;
            }
            else
            {
                throw new FormatException("Invalid JSON path.");
            }
        }

        return parts;
    }
}
