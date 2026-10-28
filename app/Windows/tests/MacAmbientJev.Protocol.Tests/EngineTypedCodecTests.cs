using System;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using Xunit;

namespace MacAmbientJev.Protocol.Tests;

public sealed class EngineTypedCodecTests
{
    [Fact]
    public void constructedCommandsMatchSwiftGoldenAndPreservePathUnicodeAndNewline()
    {
        var hello = new EngineRequest(1, ID(1), new EngineCommand.Hello(new EngineEmptyPayload()));
        Assert.Equal("{\"command\":\"hello\",\"payload\":{},\"request_id\":\"1\",\"version\":1}\n",
            Encoding.UTF8.GetString(EngineCodec.EncodeRequest(hello)));

        var settings = new EngineSettings(1, EngineSource.SystemAudio, new EngineDevice.Id("wasapi-loopback-42"),
            EngineASRSize.Large, EngineExecutionProvider.Cpu, 3, true, true, true, "D:/Ambient Exports");
        var settingsRequest = new EngineRequest(1, ID(303),
            new EngineCommand.SettingsReplace(new EngineSettingsReplacePayload(ID(9), settings)));
        const string settingsGolden = "{\"command\":\"settings.replace\",\"payload\":{\"expected_revision\":\"9\",\"settings\":{\"asr_size\":\"1.7b\",\"automatic_export\":true,\"decisions_enabled\":true,\"device\":{\"id\":\"wasapi-loopback-42\",\"kind\":\"id\"},\"execution_provider\":\"cpu\",\"export_destination_path\":\"D:/Ambient Exports\",\"low_heat\":true,\"schema_version\":1,\"source\":\"system_audio\",\"threads\":3}},\"request_id\":\"303\",\"version\":1}\n";
        Assert.Equal(settingsGolden, Encoding.UTF8.GetString(EngineCodec.EncodeRequest(settingsRequest)));

        const string path = "D:/資料/😀/line\nbreak.wav";
        var import = new EngineRequest(1, ID(4), new EngineCommand.SessionImport(new EngineImportPayload(path)));
        var encoded = EngineCodec.EncodeRequest(import);
        var body = Encoding.UTF8.GetString(encoded[..^1]);
        Assert.Contains("D:/資料/😀/line\\nbreak.wav", body);
        Assert.DoesNotContain("\\/", body);
        Assert.Equal(import, EngineCodec.DecodeRequest(encoded.AsSpan(0, encoded.Length - 1)));

        var invalidSource = new EngineRequest(1, ID(1),
            new EngineCommand.DevicesList(new EngineDevicesListPayload((EngineSource)999)));
        AssertWireError(() => EngineCodec.EncodeRequest(invalidSource), WireError.UnknownValue, "$.payload.source");
        var malformedImport = new EngineRequest(1, ID(1),
            new EngineCommand.SessionImport(new EngineImportPayload("bad\uD800")));
        AssertWireError(() => EngineCodec.EncodeRequest(malformedImport), WireError.WrongType, "$.payload.input_path");
    }

    [Fact]
    public void eventCorrelationRulesAreDistinctFromHostAdmission()
    {
        var corpus = WireCorpusTests.ReadCorpus();
        JsonNode Output(int line) => JsonNode.Parse(corpus[line - 1])!;
        var invalid = new[]
        {
            Output(19), Output(21), Output(25), Output(24),
        };
        Set(invalid[0], JsonValue.Create("99"), "request_id");
        Set(invalid[1], null, "request_id");
        Set(invalid[2], null, "request_id");
        Set(invalid[3], JsonValue.Create("8"), "request_id");
        foreach (var record in invalid)
            AssertWireError(() => EngineCodec.DecodeOutput(Encoding.UTF8.GetBytes(record.ToJsonString())),
                WireError.Constraint, "$.request_id");

        foreach (var line in new[] { 21, 25, 99, 22, 97, 24 })
            _ = EngineCodec.DecodeOutput(corpus[line - 1]);

        var hello = EngineCodec.DecodeRequest(Encoding.UTF8.GetBytes(
            "{\"version\":1,\"request_id\":\"77\",\"command\":\"hello\",\"payload\":{}}"));
        Assert.Equal(ID(77), hello.RequestID);
    }

    [Fact]
    public void transcriptRowLimitsMeasureCanonicalUtf8NotHostPagingBudget()
    {
        var exact = RowWithEncodedLength(EngineCodec.MaxRowBytes);
        Assert.Equal(EngineCodec.MaxRowBytes, StrictWireCodec.Encode(exact).Length);
        foreach (var (output, _) in Placements(exact))
        {
            var body = Body(EngineCodec.EncodeOutput(output));
            _ = EngineCodec.DecodeOutput(body);
        }

        var oversized = RowWithEncodedLength(EngineCodec.MaxRowBytes + 1);
        Assert.All(Placements(oversized), placement =>
        {
            AssertOversized(() => EngineCodec.EncodeOutput(placement.Output), placement.Path);
            var raw = StrictWireCodec.Encode(placement.Output);
            AssertOversized(() => EngineCodec.DecodeOutput(raw), placement.Path);
        });

        var unicode = new EngineTranscriptRow("unicode", 0, 1, new string('界', 87_400), [], null);
        Assert.True(unicode.Text.Length < EngineCodec.MaxRowBytes);
        Assert.True(StrictWireCodec.Encode(unicode).Length > EngineCodec.MaxRowBytes);
        AssertOversized(() => EngineCodec.EncodeOutput(RowsOutput([unicode])), "$.payload.rows[0]");
        var escaped = new EngineTranscriptRow("escaped", 0, 1, new string('\n', 131_099) + "x", [], null);
        Assert.True(escaped.Text.Length < EngineCodec.MaxRowBytes);
        Assert.True(StrictWireCodec.Encode(escaped).Length > EngineCodec.MaxRowBytes);
        AssertOversized(() => EngineCodec.EncodeOutput(RowsOutput([escaped])), "$.payload.rows[0]");

        var aggregate = Enumerable.Range(0, 4)
            .Select(index => new EngineTranscriptRow("row-" + index, 0, 1, new string('x', 200_000), [], null)).ToArray();
        var aggregateRecord = EngineCodec.EncodeOutput(RowsOutput(aggregate));
        Assert.InRange(aggregateRecord.Length - 1, 700_000, StrictJsonValidator.MaxLineBytes - 1);
        _ = EngineCodec.DecodeOutput(Body(aggregateRecord));

        var overAggregate = Enumerable.Range(0, 5)
            .Select(index => new EngineTranscriptRow("row-" + index, 0, 1, new string('x', 220_000), [], null)).ToArray();
        Assert.All(overAggregate, row => Assert.True(StrictWireCodec.Encode(row).Length <= EngineCodec.MaxRowBytes));
        var lineError = Assert.Throws<ProtocolException>(() => EngineCodec.EncodeOutput(RowsOutput(overAggregate)));
        Assert.Equal(ProtocolError.LineTooLong, lineError.Error);

        var detail = new EngineErrorDetail("native", "E", new string('d', EngineCodec.MaxRowBytes + 32), null, null);
        var detailRecord = EngineCodec.EncodeOutput(ErrorOutput([detail]));
        Assert.True(detailRecord.Length < StrictJsonValidator.MaxLineBytes);
        _ = EngineCodec.DecodeOutput(Body(detailRecord));
        var speaker = new EngineTranscriptSpeakerSpan("speaker", new string('s', EngineCodec.MaxRowBytes + 32), 0, 1);
        var page = new EngineTranscriptRowDetailsPage("s", ID(1), "row", EngineClauseState.Classified,
            "classified", [speaker], null, null);
        var speakerRecord = EngineCodec.EncodeOutput(new EngineOutput(1, ID(1), ID(2),
            new EngineEvent.Completed(new EngineResult.TranscriptRowDetails(page))));
        Assert.True(speakerRecord.Length < StrictJsonValidator.MaxLineBytes);
        _ = EngineCodec.DecodeOutput(Body(speakerRecord));
    }

    [Fact]
    public void decodedModelInvariantsRejectInvalidMeaning()
    {
        var corpus = WireCorpusTests.ReadCorpus();
        JsonNode Part(int line, params string[] path) => CorpusPart(corpus, line, path);
        var page = Part(35, "payload", "result");
        var emptySession = page.DeepClone();
        Set(emptySession, JsonValue.Create(""), "session_id");
        var emptyCursor = page.DeepClone();
        Set(emptyCursor, JsonValue.Create(""), "next_cursor");
        var blankRow = At(page, "rows", "#0").DeepClone();
        Set(blankRow, JsonValue.Create(" \n\t\u200B"), "text");

        var devices = Part(27, "payload", "result");
        var duplicateDevices = devices.DeepClone();
        Set(duplicateDevices, JsonValue.Create("id\uFFFEe\u0301"), "devices", "#0", "id");
        Set(duplicateDevices, JsonValue.Create("id\uFFFEé"), "devices", "#1", "id");
        var wrongDefault = devices.DeepClone();
        Set(wrongDefault, JsonValue.Create("other"), "default_device_id");

        var sessions = Part(77, "payload", "result");
        var duplicateFolders = sessions.DeepClone();
        Set(duplicateFolders, At(duplicateFolders, "sessions", "#0", "folder_id").DeepClone(), "sessions", "#1", "folder_id");
        var rowsSnapshot = Part(42, "payload");
        var removesFromSnapshot = rowsSnapshot.DeepClone();
        Set(removesFromSnapshot, JsonNode.Parse("[\"removed\"]"), "removed_row_ids");
        var rowsChanges = Part(43, "payload");
        var changesCursor = rowsChanges.DeepClone();
        Set(changesCursor, JsonValue.Create("cursor"), "next_cursor");
        var rowsReload = Part(44, "payload");
        var reloadWithRows = rowsReload.DeepClone();
        var reloadRows = new JsonArray();
        reloadRows.Add(At(page, "rows", "#0").DeepClone());
        Set(reloadWithRows, reloadRows, "rows");
        var overlappingRows = rowsChanges.DeepClone();
        Set(overlappingRows, JsonValue.Create("e\u0301"), "rows", "#0", "row_id");
        Set(overlappingRows, JsonNode.Parse("[\"é\"]"), "removed_row_ids");

        var presentation = Part(19, "payload", "state", "presentation");
        var prepMismatch = presentation.DeepClone();
        Set(prepMismatch, JsonValue.Create("preparing"), "preparation_phase");
        var silenceMismatch = presentation.DeepClone();
        Set(silenceMismatch, JsonValue.Create(true), "silence_warning_active");
        var audioGapWithoutCount = presentation.DeepClone();
        Set(audioGapWithoutCount, JsonValue.Create("gap"), "audio_gap_text");

        var unreadable = At(Part(34, "payload", "result"), "sessions", "#0").DeepClone();
        Set(unreadable, null, "error");
        var readable = At(sessions, "sessions", "#1").DeepClone();
        Set(readable, null, "session_id");
        var identity = Part(54, "payload", "result", "clause_tagger", "identity");
        var uppercaseHash = identity.DeepClone();
        Set(uppercaseHash, JsonValue.Create(At(identity, "revision").GetValue<string>().ToUpperInvariant()), "revision");
        var capabilities = Part(19, "payload", "capabilities");
        var emptySources = capabilities.DeepClone();
        Set(emptySources, new JsonArray(), "sources");
        var duplicateSources = capabilities.DeepClone();
        Set(duplicateSources, At(duplicateSources, "sources", "#0").DeepClone(), "sources", "#1");

        var invalid = new[]
        {
            Case(typeof(EngineTranscriptPage), emptySession, WireError.Constraint, "$.session_id"),
            Case(typeof(EngineTranscriptPage), emptyCursor, WireError.Constraint, "$.next_cursor"),
            Case(typeof(EngineTranscriptRow), blankRow, WireError.Constraint, "$.text"),
            Case(typeof(EngineDevicesResult), duplicateDevices, WireError.Constraint, "$.devices"),
            Case(typeof(EngineDevicesResult), wrongDefault, WireError.Constraint, "$.default_device_id"),
            Case(typeof(EngineSessionListResult), duplicateFolders, WireError.Constraint, "$.sessions"),
            Case(typeof(EngineRowsPayload), removesFromSnapshot, WireError.Constraint, "$.removed_row_ids"),
            Case(typeof(EngineRowsPayload), changesCursor, WireError.Constraint, "$.next_cursor"),
            Case(typeof(EngineRowsPayload), reloadWithRows, WireError.Constraint, "$.rows"),
            Case(typeof(EngineRowsPayload), overlappingRows, WireError.Constraint, "$.rows"),
            Case(typeof(EnginePresentationState), prepMismatch, WireError.Constraint, "$.preparation_status_text"),
            Case(typeof(EnginePresentationState), silenceMismatch, WireError.Constraint, "$.silence_warning_active"),
            Case(typeof(EnginePresentationState), audioGapWithoutCount, WireError.Constraint, "$.audio_gap_count"),
            Case(typeof(EngineSessionSummary), unreadable, WireError.Constraint, "$.error"),
            Case(typeof(EngineSessionSummary), readable, WireError.Constraint, "$.session_id"),
            Case(typeof(EngineClauseTaggerIdentity), uppercaseHash, WireError.Constraint, "$.revision"),
            Case(typeof(EngineCapabilities), emptySources, WireError.Constraint, "$.sources"),
            Case(typeof(EngineCapabilities), duplicateSources, WireError.Constraint, "$.sources"),
        };
        foreach (var item in invalid)
            AssertWireError(() => StrictWireCodec.Decode(item.Type, Encoding.UTF8.GetBytes(item.Json)), item.Error, item.Path);

        var zeroWidthModelName = identity.DeepClone();
        Set(zeroWidthModelName, JsonValue.Create("\u200B"), "backend");
        var acceptedIdentity = (EngineClauseTaggerIdentity)StrictWireCodec.Decode(typeof(EngineClauseTaggerIdentity),
            Encoding.UTF8.GetBytes(zeroWidthModelName.ToJsonString()));
        Assert.Equal("\u200B", acceptedIdentity.Backend);

        var opaqueDevices = devices.DeepClone();
        Set(opaqueDevices, JsonValue.Create("id\uFFFEa"), "devices", "#0", "id");
        Set(opaqueDevices, JsonValue.Create("id\uFFFEb"), "devices", "#1", "id");
        Set(opaqueDevices, JsonValue.Create("id\uFFFEa"), "default_device_id");
        var acceptedDevices = (EngineDevicesResult)StrictWireCodec.Decode(typeof(EngineDevicesResult),
            Encoding.UTF8.GetBytes(opaqueDevices.ToJsonString()));
        Assert.Equal(new[] { "id\uFFFEa", "id\uFFFEb" }, acceptedDevices.Devices.Select(device => device.ID));
    }

    private static JsonNode CorpusPart(byte[][] corpus, int line, string[] path) =>
        At(JsonNode.Parse(corpus[line - 1])!, path).DeepClone();

    private static JsonNode At(JsonNode node, params string[] path)
    {
        foreach (var part in path)
            node = part[0] == '#' ? node.AsArray()[int.Parse(part[1..])]! : node.AsObject()[part]!;
        return node;
    }

    private static void Set(JsonNode node, JsonNode? value, params string[] path)
    {
        var parent = At(node, path[..^1]);
        var member = path[^1];
        if (member[0] == '#') parent.AsArray()[int.Parse(member[1..])] = value?.DeepClone();
        else parent.AsObject()[member] = value?.DeepClone();
    }

    private static (Type Type, string Json, WireError Error, string Path) Case(
        Type type, JsonNode node, WireError error, string path) => (type, node.ToJsonString(), error, path);

    private static EngineTranscriptRow RowWithEncodedLength(int byteCount)
    {
        var overhead = StrictWireCodec.Encode(new EngineTranscriptRow("limit", 0, 1, "x", [], null)).Length - 1;
        return new EngineTranscriptRow("limit", 0, 1, new string('x', byteCount - overhead), [], null);
    }

    private static (EngineOutput Output, string Path)[] Placements(EngineTranscriptRow row)
    {
        var page = new EngineTranscriptPage("s", ID(1), [row], null, null);
        return
        [
            (RowsOutput([row]), "$.payload.rows[0]"),
            (new EngineOutput(1, ID(1), ID(2), new EngineEvent.Completed(new EngineResult.TranscriptRead(page))), "$.payload.result.rows[0]"),
            (new EngineOutput(1, ID(1), ID(2), new EngineEvent.Completed(new EngineResult.TranscriptWatch(page))), "$.payload.result.rows[0]"),
        ];
    }

    private static EngineOutput RowsOutput(EngineTranscriptRow[] rows) =>
        new(1, ID(1), null, new EngineEvent.Rows(new EngineRowsPayload("s", ID(1), EngineRowsKind.Snapshot, rows, [], null)));

    private static EngineOutput ErrorOutput(EngineErrorDetail[] details) =>
        new(1, ID(1), ID(2), new EngineEvent.Error(new EngineFailure(EngineErrorCode.DeviceFailure, "failure",
            EngineStage.Capture, ID(2), null, EngineSeverity.Error, EngineRecoveryAction.Retry, details, [])));

    private static EngineID ID(ulong value) => new(value);
    private static byte[] Body(byte[] record) => record[..^1];

    private static void AssertOversized(Action action, string path)
    {
        var error = Assert.Throws<WireDecodeException>(action);
        Assert.Equal(WireError.OversizedRow, error.Error);
        Assert.Equal(path, error.Path);
    }

    private static void AssertWireError(Action action, WireError expected, string path)
    {
        var error = Assert.Throws<WireDecodeException>(action);
        Assert.Equal(expected, error.Error);
        Assert.Equal(path, error.Path);
    }
}
