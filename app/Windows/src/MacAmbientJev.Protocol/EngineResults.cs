namespace MacAmbientJev.Protocol;

[WireUnion("command", typeof(EngineCommandName))]
public abstract record EngineResult
{
    private EngineResult() { }

    public EngineCommandName Command => StrictWireCodec.CaseValue<EngineCommandName>(this);

    [WireCase("hello")]
    public sealed record Hello([property: WireMember("result")] EngineReadyPayload Result) : EngineResult;

    [WireCase("state.get")]
    public sealed record StateGet([property: WireMember("result")] EngineState Result) : EngineResult;

    [WireCase("diagnostics.get")]
    public sealed record DiagnosticsGet([property: WireMember("result")] EngineDiagnosticsResult Result) : EngineResult;

    [WireCase("devices.list")]
    public sealed record DevicesList([property: WireMember("result")] EngineDevicesResult Result) : EngineResult;

    [WireCase("recording.start")]
    public sealed record RecordingStart([property: WireMember("result")] EngineSessionPayload Result) : EngineResult;

    [WireCase("recording.stop")]
    public sealed record RecordingStop([property: WireMember("result")] EngineSessionPayload Result) : EngineResult;

    [WireCase("session.import")]
    public sealed record SessionImport([property: WireMember("result")] EngineSessionPayload Result) : EngineResult;

    [WireCase("session.inspect")]
    public sealed record SessionInspect([property: WireMember("result")] EngineSessionSummary Result) : EngineResult;

    [WireCase("session.reprocess")]
    public sealed record SessionReprocess([property: WireMember("result")] EngineSessionPayload Result) : EngineResult;

    [WireCase("session.retry_decisions")]
    public sealed record SessionRetryDecisions([property: WireMember("result")] EngineSessionPayload Result) : EngineResult;

    [WireCase("session.list")]
    public sealed record SessionList([property: WireMember("result")] EngineSessionListResult Result) : EngineResult;

    [WireCase("transcript.read")]
    public sealed record TranscriptRead([property: WireMember("result")] EngineTranscriptPage Result) : EngineResult;

    [WireCase("transcript.row_details")]
    public sealed record TranscriptRowDetails([property: WireMember("result")] EngineTranscriptRowDetailsPage Result) : EngineResult;

    [WireCase("transcript.watch")]
    public sealed record TranscriptWatch([property: WireMember("result")] EngineTranscriptPage Result) : EngineResult;

    [WireCase("session.export")]
    public sealed record SessionExport([property: WireMember("result")] EngineExportResult Result) : EngineResult;

    [WireCase("settings.get")]
    public sealed record SettingsGet([property: WireMember("result")] EngineSettingsResult Result) : EngineResult;

    [WireCase("settings.replace")]
    public sealed record SettingsReplace([property: WireMember("result")] EngineSettingsResult Result) : EngineResult;

    [WireCase("models.prepare")]
    public sealed record ModelsPrepare([property: WireMember("result")] EngineEmptyPayload Result) : EngineResult;

    [WireCase("models.inspect")]
    public sealed record ModelsInspect([property: WireMember("result")] EngineModelsInspection Result) : EngineResult;

    [WireCase("accelerators.bind")]
    public sealed record AcceleratorsBind([property: WireMember("result")] EngineAcceleratorsBindResult Result) : EngineResult;

    [WireCase("accelerators.verify")]
    public sealed record AcceleratorsVerify([property: WireMember("result")] EngineAcceleratorsVerifyResult Result) : EngineResult;

    [WireCase("profiles.decide")]
    public sealed record ProfilesDecide([property: WireMember("result")] EngineProfileEvaluation Result) : EngineResult;

    [WireCase("profiles.evaluate")]
    public sealed record ProfilesEvaluate([property: WireMember("result")] EngineProfileEvaluation Result) : EngineResult;

    [WireCase("shutdown")]
    public sealed record Shutdown([property: WireMember("result")] EngineEmptyPayload Result) : EngineResult;
}
