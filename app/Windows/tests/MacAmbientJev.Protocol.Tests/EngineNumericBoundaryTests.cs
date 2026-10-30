using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Protocol.Tests;

public sealed class EngineNumericBoundaryTests
{
    private const string Row = """{"row_id":"row","start_ms":0,"end_ms":1,"text":"text","headings":[],"clause_state":null}""";
    private const string Queued = """{"session_id":"queued","stage":"asr"}""";
    private const string Speaker = """{"speaker_id":"speaker","display_label":"Speaker 1","start_ms":0,"end_ms":1}""";
    private const string Session = """{"folder_id":"folder","session_id":"s","status":"finalized","error":null,"display_name":"Session","status_text":"Finalized","folder_path":"/sessions/folder","export_path":null,"can_reprocess":true,"can_retry_decisions":true,"can_export":true,"metadata":{"kind":"readable","created_at":0,"source":{"kind":"microphone"},"audio":{"kind":"available"},"has_transcript":false}}""";
    private const string State = """{"revision":"1","screen":"idle","setup":"ready","recovery":"completed","recording":null,"queue":[],"failures":[],"profile_setup":{"operation":null,"evaluation":null},"resource_protection":{"hold_reasons":[]},"presentation":{"recording_status_text":"Idle","recording_tone":"neutral","preparation_phase":"ready","preparation_status_text":null,"recovery_status_text":null,"processing_status_text":null,"live_failure_notices":[],"silence_warning_active":false,"silence_warning_text":null,"audio_gap_count":0,"audio_gap_text":null,"processing_indicator":"idle"}}""";

    [Fact]
    public void NumericBoundariesAndOverflowSafeInvariantsAreDecodedFromWireSamples()
    {
        var cases = new List<NumericCase>();
        void Add(Type type, string json, WireError? error, string path, object? expected = null, Func<object, object?>? read = null) =>
            cases.Add(new NumericCase(type, json, error, path, expected, read));

        string Usage(string send, string input, string success, string failure) =>
            "{\"send_count\":" + send + ",\"input_tokens\":" + input + ",\"success_count\":" + success + ",\"failure_count\":" + failure + "}";
        string Progress(string count) =>
            "{\"stage\":\"asr\",\"completed_units\":" + count + ",\"total_units\":null,\"session_id\":null}";
        string Request(string command, string payload) =>
            "{\"version\":1,\"request_id\":\"1\",\"command\":" + System.Text.Json.JsonSerializer.Serialize(command) + ",\"payload\":" + payload + "}";
        string Settings(long threads, long schema) =>
            "{\"expected_revision\":null,\"settings\":{\"schema_version\":" + threadsOrSchema(schema) +
            ",\"source\":\"microphone\",\"device\":{\"kind\":\"default\"},\"asr_size\":\"0.6b\",\"execution_provider\":{\"kind\":\"cpu\"},\"threads\":" + threadsOrSchema(threads) +
            ",\"low_heat\":true,\"decisions_enabled\":false,\"automatic_export\":false,\"export_destination_path\":null}}";
        string threadsOrSchema(long value) => value.ToString(CultureInfo.InvariantCulture);
        string Snapshot(string totalInput, string boundaryInput, string priorityInput) =>
            "{\"send_count\":2,\"input_tokens\":" + totalInput + ",\"success_count\":0,\"failure_count\":0," +
            "\"pending_boundary_segment_count\":0,\"pending_priority_clause_count\":0,\"boundary_requests\":" + Usage("1", boundaryInput, "0", "0") +
            ",\"priority_requests\":" + Usage("1", priorityInput, "0", "0") + "}";

        object? UsageInput(object value) => Assert.IsType<EngineDecisionRequestUsage>(value).InputTokens;
        object? ProgressCount(object value) => Assert.IsType<EngineProgressPayload>(value).CompletedUnits;
        object? RequestLimit(object value, string command) => Assert.IsType<EngineRequest>(value).Command switch
        {
            EngineCommand.SessionList item when command == "session.list" => item.Payload.Limit,
            EngineCommand.TranscriptRead item when command == "transcript.read" => item.Payload.Limit,
            EngineCommand.TranscriptRowDetails item when command == "transcript.row_details" => item.Payload.Limit,
            _ => throw new InvalidOperationException("Decoded request did not match its command."),
        };
        object? RequestThreads(object value) => Assert.IsType<EngineCommand.SettingsReplace>(Assert.IsType<EngineRequest>(value).Command).Payload.Settings.Threads;
        object? RequestSchema(object value) => Assert.IsType<EngineCommand.SettingsReplace>(Assert.IsType<EngineRequest>(value).Command).Payload.Settings.SchemaVersion;

        void AddUsage(string raw, WireError? error, object? expected = null) =>
            Add(typeof(EngineDecisionRequestUsage), Usage("0", raw, "0", "0"), error, "$.input_tokens", expected, UsageInput);
        AddUsage("0", null, 0L);
        AddUsage("9223372036854775807", null, long.MaxValue);
        AddUsage("9223372036854775808", WireError.OutOfRange);
        AddUsage("-9223372036854775809", WireError.OutOfRange);
        AddUsage("-1", WireError.Constraint);

        void AddProgress(string raw, WireError? error, ulong? expected = null) =>
            Add(typeof(EngineProgressPayload), Progress(raw), error, "$.completed_units", expected, expected.HasValue ? ProgressCount : null);
        AddProgress("0", null, 0UL);
        AddProgress("18446744073709551615", null, ulong.MaxValue);
        AddProgress("18446744073709551616", WireError.OutOfRange);
        AddProgress("-1", WireError.OutOfRange);
        AddProgress("1.0", null, 1UL);
        AddProgress("1e0", null, 1UL);
        AddProgress("1.0000000000000001", null, 1UL);
        AddProgress("1.5", WireError.WrongType);

        string Pagination(string command, int limit) => command switch
        {
            "session.list" => Request(command, "{\"cursor\":null,\"limit\":" + limit.ToString(CultureInfo.InvariantCulture) + "}"),
            "transcript.read" => Request(command, "{\"session_id\":\"s\",\"revision\":null,\"cursor\":null,\"limit\":" + limit.ToString(CultureInfo.InvariantCulture) + "}"),
            "transcript.row_details" => Request(command, "{\"session_id\":\"s\",\"revision\":\"1\",\"row_id\":\"r\",\"cursor\":null,\"limit\":" + limit.ToString(CultureInfo.InvariantCulture) + "}"),
            _ => throw new ArgumentOutOfRangeException(nameof(command)),
        };
        foreach (var (command, values, maximum) in new[]
                 {
                     ("session.list", new[] { 0, 1, 100, 101 }, 100),
                     ("transcript.read", new[] { 0, 1, 200, 201 }, 200),
                     ("transcript.row_details", new[] { 0, 1, 200, 201 }, 200),
                 })
        {
            foreach (var limit in values)
            {
                var error = limit == 0 || limit > maximum ? WireError.OutOfRange : (WireError?)null;
                Add(typeof(EngineRequest), Pagination(command, limit), error, "$.payload.limit",
                    error is null ? (long)limit : null,
                    error is null ? value => RequestLimit(value, command) : null);
            }
        }

        foreach (var threads in new[] { 0, 1, 4, 5 })
        {
            var error = threads is 0 or 5 ? WireError.OutOfRange : (WireError?)null;
            Add(typeof(EngineRequest), Request("settings.replace", Settings(threads, 2)), error, "$.payload.settings.threads",
                error is null ? (long)threads : null, error is null ? RequestThreads : null);
        }
        foreach (var schema in new[] { 0, 1, 2, 3 })
        {
            var error = schema == 2 ? (WireError?)null : WireError.Constraint;
            Add(typeof(EngineRequest), Request("settings.replace", Settings(2, schema)), error, "$.payload.settings.schema_version",
                error is null ? (long)schema : null, error is null ? RequestSchema : null);
        }

        Add(typeof(EngineState), StateWithQueue(16), null, "$.queue");
        Add(typeof(EngineState), StateWithQueue(17), WireError.Constraint, "$.queue");
        Add(typeof(EngineSessionListResult), SessionList(100), null, "$.sessions");
        Add(typeof(EngineSessionListResult), SessionList(101), WireError.Constraint, "$.sessions");
        Add(typeof(EngineTranscriptPage), TranscriptPage(200), null, "$.rows");
        Add(typeof(EngineTranscriptPage), TranscriptPage(201), WireError.Constraint, "$.rows");
        Add(typeof(EngineTranscriptRowDetailsPage), RowDetailsPage(200), null, "$.speakers");
        Add(typeof(EngineTranscriptRowDetailsPage), RowDetailsPage(201), WireError.Constraint, "$.speakers");
        Add(typeof(EngineRowsPayload), RowsChanges(100, 100), null, "$.rows");
        Add(typeof(EngineRowsPayload), RowsChanges(101, 100), WireError.Constraint, "$.rows");

        Add(typeof(EngineDecisionRequestUsage), Usage("2", "0", "2", "1"), WireError.Constraint, "$.send_count");
        Add(typeof(EngineDecisionUsageSnapshot), Snapshot("3", "1", "1"), WireError.Constraint, "$.input_tokens");
        Add(typeof(EngineDecisionUsageSnapshot), Snapshot("9223372036854775807", "9223372036854775807", "1"), WireError.Constraint, "$.input_tokens");
        Add(typeof(EngineTranscriptRow), RowWithTimes(-1, 0), WireError.Constraint, "$.start_ms");
        Add(typeof(EngineTranscriptRow), RowWithTimes(1, 0), WireError.Constraint, "$.end_ms");

        foreach (var item in cases)
        {
            if (item.Error is { } error)
            {
                AssertError(item.Type, item.Json, error, item.Path);
            }
            else
            {
                var decoded = Decode(item.Type, item.Json);
                if (item.Expected is not null) Assert.Equal(item.Expected, item.Read!(decoded));
            }
        }
    }

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

    private static string StateWithQueue(int count)
    {
        var root = JsonNode.Parse(State)!.AsObject();
        var queue = new JsonArray();
        var item = JsonNode.Parse(Queued)!;
        for (var index = 0; index < count; index++) queue.Add(item.DeepClone());
        root["queue"] = queue;
        return root.ToJsonString();
    }

    private static string SessionList(int count)
    {
        var sessions = new JsonArray();
        var sample = JsonNode.Parse(Session)!;
        for (var index = 0; index < count; index++)
        {
            var session = sample.DeepClone();
            session["folder_id"] = "folder-" + index.ToString(CultureInfo.InvariantCulture);
            sessions.Add(session);
        }

        return new JsonObject { ["sessions"] = sessions, ["next_cursor"] = null, ["previous_cursor"] = null }.ToJsonString();
    }

    private static string TranscriptPage(int count)
    {
        var rows = new JsonArray();
        var sample = JsonNode.Parse(Row)!;
        for (var index = 0; index < count; index++)
        {
            var row = sample.DeepClone();
            row["row_id"] = "row-" + index.ToString(CultureInfo.InvariantCulture);
            rows.Add(row);
        }

        return new JsonObject { ["session_id"] = "s", ["revision"] = "1", ["rows"] = rows, ["next_cursor"] = null, ["previous_cursor"] = null }.ToJsonString();
    }

    private static string RowDetailsPage(int count)
    {
        var speakers = new JsonArray();
        var sample = JsonNode.Parse(Speaker)!;
        for (var index = 0; index < count; index++) speakers.Add(sample.DeepClone());
        return new JsonObject
        {
            ["session_id"] = "s", ["revision"] = "1", ["row_id"] = "r", ["clause_state"] = "classified",
            ["clause_state_text"] = "Classified", ["speakers"] = speakers, ["next_cursor"] = null, ["previous_cursor"] = null,
        }.ToJsonString();
    }

    private static string RowsChanges(int rowCount, int removedCount)
    {
        var rows = new JsonArray();
        var rowSample = JsonNode.Parse(Row)!;
        for (var index = 0; index < rowCount; index++)
        {
            var row = rowSample.DeepClone();
            row["row_id"] = "row-" + index.ToString(CultureInfo.InvariantCulture);
            rows.Add(row);
        }

        var removed = new JsonArray();
        for (var index = 0; index < removedCount; index++) removed.Add("removed-" + index.ToString(CultureInfo.InvariantCulture));
        return new JsonObject
        {
            ["session_id"] = "s", ["revision"] = "1", ["kind"] = "changes", ["rows"] = rows,
            ["removed_row_ids"] = removed, ["next_cursor"] = null,
        }.ToJsonString();
    }

    private static string RowWithTimes(long start, long end) =>
        new JsonObject { ["row_id"] = "row", ["start_ms"] = start, ["end_ms"] = end, ["text"] = "text", ["headings"] = new JsonArray(), ["clause_state"] = null }.ToJsonString();

    private sealed record NumericCase(Type Type, string Json, WireError? Error, string Path, object? Expected, Func<object, object?>? Read);
}
