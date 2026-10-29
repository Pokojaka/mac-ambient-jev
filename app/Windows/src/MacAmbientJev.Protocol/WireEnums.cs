namespace MacAmbientJev.Protocol;

public enum EngineSource
{
    [WireValue("microphone")] Microphone,
    [WireValue("system_audio")] SystemAudio,
}

public enum EngineASRSize
{
    [WireValue("0.6b")] Small,
    [WireValue("1.7b")] Large,
}

public enum EngineExecutionProviderKind
{
    [WireValue("cpu")] Cpu,
    [WireValue("windows_ml")] WindowsML,
}

public enum EngineDeviceKind
{
    [WireValue("default")] Default,
    [WireValue("id")] Id,
}

public enum EngineCommandName
{
    [WireValue("hello")] Hello,
    [WireValue("state.get")] StateGet,
    [WireValue("diagnostics.get")] DiagnosticsGet,
    [WireValue("devices.list")] DevicesList,
    [WireValue("recording.start")] RecordingStart,
    [WireValue("recording.stop")] RecordingStop,
    [WireValue("session.import")] SessionImport,
    [WireValue("session.inspect")] SessionInspect,
    [WireValue("session.reprocess")] SessionReprocess,
    [WireValue("session.retry_decisions")] SessionRetryDecisions,
    [WireValue("session.list")] SessionList,
    [WireValue("transcript.read")] TranscriptRead,
    [WireValue("transcript.row_details")] TranscriptRowDetails,
    [WireValue("transcript.watch")] TranscriptWatch,
    [WireValue("session.export")] SessionExport,
    [WireValue("settings.get")] SettingsGet,
    [WireValue("settings.replace")] SettingsReplace,
    [WireValue("models.prepare")] ModelsPrepare,
    [WireValue("models.inspect")] ModelsInspect,
    [WireValue("accelerators.bind")] AcceleratorsBind,
    [WireValue("accelerators.verify")] AcceleratorsVerify,
    [WireValue("profiles.evaluate")] ProfilesEvaluate,
    [WireValue("profiles.decide")] ProfilesDecide,
    [WireValue("shutdown")] Shutdown,
}

public enum EngineDiagnosticsScope
{
    [WireValue("engine_process")] EngineProcess,
}

public enum EngineDecisionUsageKind
{
    [WireValue("available")] Available,
    [WireValue("unavailable")] Unavailable,
}

public enum EngineClauseTaggerInspectionKind
{
    [WireValue("validated")] Validated,
    [WireValue("invalid")] Invalid,
}

public enum EngineEventName
{
    [WireValue("ready")] Ready,
    [WireValue("state")] State,
    [WireValue("accepted")] Accepted,
    [WireValue("completed")] Completed,
    [WireValue("progress")] Progress,
    [WireValue("rows")] Rows,
    [WireValue("error")] Error,
}

public enum EngineStage
{
    [WireValue("startup")] Startup,
    [WireValue("settings")] Settings,
    [WireValue("devices")] Devices,
    [WireValue("capture")] Capture,
    [WireValue("import")] Import,
    [WireValue("recovery")] Recovery,
    [WireValue("maintenance")] Maintenance,
    [WireValue("validating_models")] ValidatingModels,
    [WireValue("loading_models")] LoadingModels,
    [WireValue("vad")] Vad,
    [WireValue("diarization")] Diarization,
    [WireValue("asr")] Asr,
    [WireValue("decisions")] Decisions,
    [WireValue("finalization")] Finalization,
    [WireValue("export")] Export,
    [WireValue("shutdown")] Shutdown,
    [WireValue("protocol")] Protocol,
}

public enum EngineErrorCode
{
    [WireValue("invalid_request")] InvalidRequest,
    [WireValue("unsupported_version")] UnsupportedVersion,
    [WireValue("invalid_request_id")] InvalidRequestId,
    [WireValue("hello_required")] HelloRequired,
    [WireValue("busy")] Busy,
    [WireValue("settings_required")] SettingsRequired,
    [WireValue("invalid_settings")] InvalidSettings,
    [WireValue("stale_revision")] StaleRevision,
    [WireValue("invalid_cursor")] InvalidCursor,
    [WireValue("session_not_found")] SessionNotFound,
    [WireValue("row_not_found")] RowNotFound,
    [WireValue("device_not_found")] DeviceNotFound,
    [WireValue("device_failure")] DeviceFailure,
    [WireValue("device_lost")] DeviceLost,
    [WireValue("capture_failure")] CaptureFailure,
    [WireValue("disk_space")] DiskSpace,
    [WireValue("power_failure")] PowerFailure,
    [WireValue("filesystem")] Filesystem,
    [WireValue("model_missing")] ModelMissing,
    [WireValue("model_corrupt")] ModelCorrupt,
    [WireValue("model_failure")] ModelFailure,
    [WireValue("processing_failure")] ProcessingFailure,
    [WireValue("export_failure")] ExportFailure,
    [WireValue("row_too_large")] RowTooLarge,
    [WireValue("cancelled")] Cancelled,
    [WireValue("internal_error")] InternalError,
}

public enum EngineSeverity
{
    [WireValue("warning")] Warning,
    [WireValue("error")] Error,
    [WireValue("fatal")] Fatal,
}

public enum EngineRecoveryAction
{
    [WireValue("none")] None,
    [WireValue("replace_settings")] ReplaceSettings,
    [WireValue("prepare_models")] PrepareModels,
    [WireValue("retry")] Retry,
    [WireValue("reprocess")] Reprocess,
    [WireValue("retry_decisions")] RetryDecisions,
    [WireValue("select_device")] SelectDevice,
    [WireValue("free_disk_space")] FreeDiskSpace,
    [WireValue("inspect_session")] InspectSession,
    [WireValue("restart")] Restart,
}

public enum EngineScreen
{
    [WireValue("idle")] Idle,
    [WireValue("live")] Live,
    [WireValue("finalizing")] Finalizing,
    [WireValue("finalized")] Finalized,
}

public enum EngineSetupStatus
{
    [WireValue("settings_required")] SettingsRequired,
    [WireValue("models_required")] ModelsRequired,
    [WireValue("ready")] Ready,
}

public enum EngineRecoveryStatus
{
    [WireValue("pending")] Pending,
    [WireValue("running")] Running,
    [WireValue("completed")] Completed,
    [WireValue("failed")] Failed,
}

public enum EngineRecordingPhase
{
    [WireValue("starting")] Starting,
    [WireValue("recording")] Recording,
    [WireValue("waiting_for_device")] WaitingForDevice,
    [WireValue("stopping")] Stopping,
}

public enum EngineUnavailableCapability
{
    [WireValue("none")] None,
}

public enum EngineSessionStatus
{
    [WireValue("unreadable")] Unreadable,
    [WireValue("recording")] Recording,
    [WireValue("queued")] Queued,
    [WireValue("processing")] Processing,
    [WireValue("finalized")] Finalized,
    [WireValue("failed")] Failed,
}

public enum EngineSpeakerLabel
{
    [WireValue("Speaker 1")] Speaker1,
    [WireValue("Speaker 2")] Speaker2,
    [WireValue("Speaker 3")] Speaker3,
    [WireValue("Speaker 4")] Speaker4,
    [WireValue("Speaker 5")] Speaker5,
    [WireValue("Speaker 6")] Speaker6,
    [WireValue("Speaker 7")] Speaker7,
    [WireValue("OTHER")] Other,
    [WireValue("UNKNOWN")] Unknown,
}

public enum EngineClauseState
{
    [WireValue("awaiting_next_segment")] AwaitingNextSegment,
    [WireValue("boundary_pending")] BoundaryPending,
    [WireValue("priority_pending")] PriorityPending,
    [WireValue("classified")] Classified,
}

public enum EngineRowsKind
{
    [WireValue("snapshot")] Snapshot,
    [WireValue("changes")] Changes,
    [WireValue("reload_required")] ReloadRequired,
}

public enum EngineRecordingTone
{
    [WireValue("neutral")] Neutral,
    [WireValue("recording")] Recording,
    [WireValue("warning")] Warning,
    [WireValue("error")] Error,
}

public enum EnginePreparationPhase
{
    [WireValue("idle")] Idle,
    [WireValue("preparing")] Preparing,
    [WireValue("ready")] Ready,
    [WireValue("failed")] Failed,
}

public enum EngineProcessingIndicator
{
    [WireValue("idle")] Idle,
    [WireValue("running")] Running,
    [WireValue("backlogged")] Backlogged,
    [WireValue("complete")] Complete,
    [WireValue("partial_failure")] PartialFailure,
}

public enum EngineSessionSourceKind
{
    [WireValue("microphone")] Microphone,
    [WireValue("system_audio")] SystemAudio,
    [WireValue("imported")] Imported,
}

public enum EngineSessionAudioKind
{
    [WireValue("available")] Available,
    [WireValue("missing")] Missing,
    [WireValue("unreadable")] Unreadable,
}

public enum EngineSessionMetadataKind
{
    [WireValue("unreadable")] Unreadable,
    [WireValue("readable")] Readable,
}
