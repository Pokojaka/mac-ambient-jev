using System;

namespace MacAmbientJev.Protocol;

[WireUnion("kind", typeof(EngineDeviceKind))]
public abstract record EngineDevice
{
    private EngineDevice() { }

    public EngineDeviceKind Kind => this switch
    {
        Default _ => EngineDeviceKind.Default,
        Id _ => EngineDeviceKind.Id,
        _ => throw new InvalidOperationException("Unrecognized engine device case."),
    };

    [WireCase("default")]
    public sealed record Default() : EngineDevice;

    [WireCase("id")]
    public sealed record Id([property: WireMember("id")] string ID) : EngineDevice, IWireValidatable
    {
        public void Validate(string path) => WireCheck.Nonempty(ID, path + ".id");
    }
}

[WireObject]
public sealed record EngineSettings(
    [property: WireMember("schema_version")] long SchemaVersion,
    [property: WireMember("source")] EngineSource Source,
    [property: WireMember("device")] EngineDevice Device,
    [property: WireMember("asr_size")] EngineASRSize AsrSize,
    [property: WireMember("execution_provider")] EngineExecutionProvider ExecutionProvider,
    [property: WireMember("threads")] long Threads,
    [property: WireMember("low_heat")] bool LowHeat,
    [property: WireMember("decisions_enabled")] bool DecisionsEnabled,
    [property: WireMember("automatic_export")] bool AutomaticExport,
    [property: WireMember("export_destination_path", IsNullable = true)] string? ExportDestinationPath) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Require(SchemaVersion == 1, path + ".schema_version", "schema_version must be 1.");
        WireCheck.Range(Threads, 1, 4, path + ".threads");
        WireCheck.OptionalNonempty(ExportDestinationPath, path + ".export_destination_path");
    }

    public void ValidateLogicalCPUCount(long logicalCPUCount)
    {
        WireCheck.Require(logicalCPUCount > 0, "$.logicalCPUCount", "logicalCPUCount must be positive.");
        WireCheck.Require(Threads <= Math.Min(4, logicalCPUCount), "$.threads", "threads exceed logical CPU limit.");
    }
}

[WireObject]
public sealed record EngineEmptyPayload();

[WireObject]
public sealed record EngineDevicesListPayload(
    [property: WireMember("source")] EngineSource Source);

[WireObject]
public sealed record EngineRecordingStartPayload(
    [property: WireMember("source")] EngineSource Source,
    [property: WireMember("device")] EngineDevice Device);

[WireObject]
public sealed record EngineSessionPayload(
    [property: WireMember("session_id")] string SessionID) : IWireValidatable
{
    public void Validate(string path) => WireCheck.Nonempty(SessionID, path + ".session_id");
}

[WireObject]
public sealed record EngineSessionInspectPayload(
    [property: WireMember("folder_id")] string FolderID) : IWireValidatable
{
    public void Validate(string path) => WireCheck.Nonempty(FolderID, path + ".folder_id");
}

[WireObject]
public sealed record EngineImportPayload(
    [property: WireMember("input_path")] string InputPath) : IWireValidatable
{
    public void Validate(string path) => WireCheck.Nonempty(InputPath, path + ".input_path");
}

[WireObject]
public sealed record EngineSessionListPayload(
    [property: WireMember("cursor", IsNullable = true)] string? Cursor,
    [property: WireMember("limit")] long Limit) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.OptionalNonempty(Cursor, path + ".cursor");
        WireCheck.Range(Limit, 1, 100, path + ".limit");
    }
}

[WireObject]
public sealed record EngineTranscriptReadPayload(
    [property: WireMember("session_id")] string SessionID,
    [property: WireMember("revision", IsNullable = true)] EngineID? Revision,
    [property: WireMember("cursor", IsNullable = true)] string? Cursor,
    [property: WireMember("limit")] long Limit) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(SessionID, path + ".session_id");
        WireCheck.OptionalNonempty(Cursor, path + ".cursor");
        WireCheck.Range(Limit, 1, 200, path + ".limit");
    }
}

[WireObject]
public sealed record EngineTranscriptRowDetailsPayload(
    [property: WireMember("session_id")] string SessionID,
    [property: WireMember("revision")] EngineID Revision,
    [property: WireMember("row_id")] string RowID,
    [property: WireMember("cursor", IsNullable = true)] string? Cursor,
    [property: WireMember("limit")] long Limit) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(SessionID, path + ".session_id");
        WireCheck.Nonempty(RowID, path + ".row_id");
        WireCheck.OptionalNonempty(Cursor, path + ".cursor");
        WireCheck.Range(Limit, 1, 200, path + ".limit");
    }
}

[WireObject]
public sealed record EngineExportPayload(
    [property: WireMember("session_id")] string SessionID,
    [property: WireMember("destination_path")] string DestinationPath) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(SessionID, path + ".session_id");
        WireCheck.Nonempty(DestinationPath, path + ".destination_path");
    }
}

[WireObject]
public sealed record EngineSettingsReplacePayload(
    [property: WireMember("expected_revision", IsNullable = true)] EngineID? ExpectedRevision,
    [property: WireMember("settings")] EngineSettings Settings);

[WireUnion("command", typeof(EngineCommandName))]
public abstract record EngineCommand
{
    private EngineCommand() { }

    public EngineCommandName Name => this switch
    {
        Hello _ => EngineCommandName.Hello,
        StateGet _ => EngineCommandName.StateGet,
        DiagnosticsGet _ => EngineCommandName.DiagnosticsGet,
        DevicesList _ => EngineCommandName.DevicesList,
        RecordingStart _ => EngineCommandName.RecordingStart,
        RecordingStop _ => EngineCommandName.RecordingStop,
        SessionImport _ => EngineCommandName.SessionImport,
        SessionInspect _ => EngineCommandName.SessionInspect,
        SessionReprocess _ => EngineCommandName.SessionReprocess,
        SessionRetryDecisions _ => EngineCommandName.SessionRetryDecisions,
        SessionList _ => EngineCommandName.SessionList,
        TranscriptRead _ => EngineCommandName.TranscriptRead,
        TranscriptRowDetails _ => EngineCommandName.TranscriptRowDetails,
        TranscriptWatch _ => EngineCommandName.TranscriptWatch,
        SessionExport _ => EngineCommandName.SessionExport,
        SettingsGet _ => EngineCommandName.SettingsGet,
        SettingsReplace _ => EngineCommandName.SettingsReplace,
        ModelsPrepare _ => EngineCommandName.ModelsPrepare,
        ModelsInspect _ => EngineCommandName.ModelsInspect,
        Shutdown _ => EngineCommandName.Shutdown,
        _ => throw new InvalidOperationException("Unrecognized engine command case."),
    };

    [WireCase("hello")]
    public sealed record Hello([property: WireMember("payload")] EngineEmptyPayload Payload) : EngineCommand;

    [WireCase("state.get")]
    public sealed record StateGet([property: WireMember("payload")] EngineEmptyPayload Payload) : EngineCommand;

    [WireCase("diagnostics.get")]
    public sealed record DiagnosticsGet([property: WireMember("payload")] EngineEmptyPayload Payload) : EngineCommand;

    [WireCase("devices.list")]
    public sealed record DevicesList([property: WireMember("payload")] EngineDevicesListPayload Payload) : EngineCommand;

    [WireCase("recording.start")]
    public sealed record RecordingStart([property: WireMember("payload")] EngineRecordingStartPayload Payload) : EngineCommand;

    [WireCase("recording.stop")]
    public sealed record RecordingStop([property: WireMember("payload")] EngineSessionPayload Payload) : EngineCommand;

    [WireCase("session.import")]
    public sealed record SessionImport([property: WireMember("payload")] EngineImportPayload Payload) : EngineCommand;

    [WireCase("session.inspect")]
    public sealed record SessionInspect([property: WireMember("payload")] EngineSessionInspectPayload Payload) : EngineCommand;

    [WireCase("session.reprocess")]
    public sealed record SessionReprocess([property: WireMember("payload")] EngineSessionPayload Payload) : EngineCommand;

    [WireCase("session.retry_decisions")]
    public sealed record SessionRetryDecisions([property: WireMember("payload")] EngineSessionPayload Payload) : EngineCommand;

    [WireCase("session.list")]
    public sealed record SessionList([property: WireMember("payload")] EngineSessionListPayload Payload) : EngineCommand;

    [WireCase("transcript.read")]
    public sealed record TranscriptRead([property: WireMember("payload")] EngineTranscriptReadPayload Payload) : EngineCommand;

    [WireCase("transcript.row_details")]
    public sealed record TranscriptRowDetails([property: WireMember("payload")] EngineTranscriptRowDetailsPayload Payload) : EngineCommand;

    [WireCase("transcript.watch")]
    public sealed record TranscriptWatch([property: WireMember("payload")] EngineSessionPayload Payload) : EngineCommand;

    [WireCase("session.export")]
    public sealed record SessionExport([property: WireMember("payload")] EngineExportPayload Payload) : EngineCommand;

    [WireCase("settings.get")]
    public sealed record SettingsGet([property: WireMember("payload")] EngineEmptyPayload Payload) : EngineCommand;

    [WireCase("settings.replace")]
    public sealed record SettingsReplace([property: WireMember("payload")] EngineSettingsReplacePayload Payload) : EngineCommand;

    [WireCase("models.prepare")]
    public sealed record ModelsPrepare([property: WireMember("payload")] EngineEmptyPayload Payload) : EngineCommand;

    [WireCase("models.inspect")]
    public sealed record ModelsInspect([property: WireMember("payload")] EngineEmptyPayload Payload) : EngineCommand;

    [WireCase("shutdown")]
    public sealed record Shutdown([property: WireMember("payload")] EngineEmptyPayload Payload) : EngineCommand;
}

[WireObject]
public sealed record EngineRequest(
    [property: WireMember("version")] long Version,
    [property: WireMember("request_id")] EngineID RequestID,
    [property: WireFlatten] EngineCommand Command) : IWireValidatable
{
    public void Validate(string path)
    {
        if (Version != 1)
        {
            throw new WireDecodeException(WireError.UnsupportedVersion, path + ".version", "Only protocol version 1 is supported.");
        }
    }
}
