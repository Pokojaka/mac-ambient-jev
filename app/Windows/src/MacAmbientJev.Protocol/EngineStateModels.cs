using System;
using System.Linq;

namespace MacAmbientJev.Protocol;

[WireObject]
public sealed record EngineErrorDetail(
    [property: WireMember("domain")] string Domain,
    [property: WireMember("code")] string Code,
    [property: WireMember("message")] string Message,
    [property: WireMember("path", IsNullable = true)] string? Path,
    [property: WireMember("device_id", IsNullable = true)] string? DeviceID) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(Domain, path + ".domain");
        WireCheck.Nonempty(Code, path + ".code");
        WireCheck.Nonempty(Message, path + ".message");
        WireCheck.OptionalNonempty(Path, path + ".path");
        WireCheck.OptionalNonempty(DeviceID, path + ".device_id");
    }
}

[WireObject]
public sealed record EngineFailure(
    [property: WireMember("code")] EngineErrorCode Code,
    [property: WireMember("message")] string Message,
    [property: WireMember("stage")] EngineStage Stage,
    [property: WireMember("request_id", IsNullable = true)] EngineID? RequestID,
    [property: WireMember("session_id", IsNullable = true)] string? SessionID,
    [property: WireMember("severity")] EngineSeverity Severity,
    [property: WireMember("recovery_action")] EngineRecoveryAction RecoveryAction,
    [property: WireMember("details")] EngineErrorDetail[] Details,
    [property: WireMember("cleanup_errors")] EngineErrorDetail[] CleanupErrors) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(Message, path + ".message");
        WireCheck.OptionalNonempty(SessionID, path + ".session_id");
    }
}

[WireObject]
public sealed record EngineCapabilities(
    [property: WireMember("sources")] EngineSource[] Sources,
    [property: WireMember("asr_sizes")] EngineASRSize[] AsrSizes,
    [property: WireMember("execution_providers")] EngineExecutionProvider[] ExecutionProviders,
    [property: WireMember("maximum_threads")] long MaximumThreads,
    [property: WireMember("automatic_input_volume")] EngineUnavailableCapability AutomaticInputVolume,
    [property: WireMember("thermal_monitoring")] EngineUnavailableCapability ThermalMonitoring) : IWireValidatable
{
    public void Validate(string path)
    {
        if (Sources is not null)
        {
            WireCheck.Require(Sources.Length > 0, path + ".sources", "sources must not be empty.");
            WireCheck.Unique(Sources, path + ".sources");
        }

        if (AsrSizes is not null)
        {
            WireCheck.Require(AsrSizes.Length > 0, path + ".asr_sizes", "asr_sizes must not be empty.");
            WireCheck.Unique(AsrSizes, path + ".asr_sizes");
        }

        if (ExecutionProviders is not null)
        {
            WireCheck.Require(ExecutionProviders.Length > 0, path + ".execution_providers", "execution_providers must not be empty.");
            EngineExecutionProvider[] uniqueProviders = ExecutionProviders.Select<EngineExecutionProvider, EngineExecutionProvider>(provider => provider switch
            {
                EngineExecutionProvider.Cpu cpu => cpu,
                EngineExecutionProvider.WindowsML windowsML => new EngineExecutionProvider.WindowsML(
                    WireCheck.CanonicalString(windowsML.ProviderName),
                    WireCheck.CanonicalString(windowsML.DeviceKey),
                    WireCheck.CanonicalString(windowsML.VerificationID)),
                _ => throw new InvalidOperationException("Unknown execution provider type."),
            }).ToArray();
            WireCheck.Unique(uniqueProviders, path + ".execution_providers");
        }
        WireCheck.Range(MaximumThreads, 1, 4, path + ".maximum_threads");
    }
}

[WireObject]
public sealed record EngineRecordingState(
    [property: WireMember("session_id")] string SessionID,
    [property: WireMember("source")] EngineSource Source,
    [property: WireMember("device")] EngineDevice Device,
    [property: WireMember("phase")] EngineRecordingPhase Phase) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(SessionID, path + ".session_id");
        if (Device is EngineDevice.Id id)
        {
            WireCheck.Nonempty(id.ID, path + ".device.id");
        }
    }
}

[WireObject]
public sealed record EngineQueuedOperation(
    [property: WireMember("session_id")] string SessionID,
    [property: WireMember("stage")] EngineStage Stage) : IWireValidatable
{
    public void Validate(string path) => WireCheck.Nonempty(SessionID, path + ".session_id");
}

[WireObject]
public sealed record EngineState(
    [property: WireMember("revision")] EngineID Revision,
    [property: WireMember("screen")] EngineScreen Screen,
    [property: WireMember("setup")] EngineSetupStatus Setup,
    [property: WireMember("profile_setup")] EngineProfileSetup ProfileSetup,
    [property: WireMember("resource_protection")] EngineResourceProtection ResourceProtection,
    [property: WireMember("recovery")] EngineRecoveryStatus Recovery,
    [property: WireMember("recording", IsNullable = true)] EngineRecordingState? Recording,
    [property: WireMember("queue")] EngineQueuedOperation[] Queue,
    [property: WireMember("failures")] EngineFailure[] Failures,
    [property: WireMember("presentation")] EnginePresentationState Presentation) : IWireValidatable
{
    public void Validate(string path)
    {
        if (Queue is not null)
        {
            WireCheck.Require(Queue.Length <= 16, path + ".queue", "queue must contain at most 16 operations.");
        }
    }
}

[WireObject]
public sealed record EngineReadyPayload(
    [property: WireMember("capabilities")] EngineCapabilities Capabilities,
    [property: WireMember("state")] EngineState State);

[WireObject]
public sealed record EngineDeviceInfo(
    [property: WireMember("id")] string ID,
    [property: WireMember("name")] string Name,
    [property: WireMember("is_default")] bool IsDefault) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(ID, path + ".id");
        WireCheck.Nonempty(Name, path + ".name");
    }
}

[WireObject]
public sealed record EngineDevicesResult(
    [property: WireMember("source")] EngineSource Source,
    [property: WireMember("devices")] EngineDeviceInfo[] Devices,
    [property: WireMember("default_device_id", IsNullable = true)] string? DefaultDeviceID) : IWireValidatable
{
    public void Validate(string path)
    {
        if (Devices is null)
        {
            return;
        }

        var ids = Devices.Where(device => device is not null && device.ID is not null).Select(device => device.ID);
        WireCheck.Unique(ids, path + ".devices");

        var defaults = Devices.Where(device => device is not null && device.IsDefault).ToArray();
        WireCheck.Require(defaults.Length <= 1, path + ".devices", "at most one device may be default.");
        if (DefaultDeviceID is not null)
        {
            WireCheck.Nonempty(DefaultDeviceID, path + ".default_device_id");
            WireCheck.Require(defaults.Length == 1, path + ".default_device_id", "default_device_id requires exactly one default device.");
            WireCheck.Require(WireCheck.EquivalentStrings(defaults[0].ID, DefaultDeviceID), path + ".default_device_id", "default_device_id must name the default device.");
        }
        else
        {
            WireCheck.Require(defaults.Length == 0, path + ".default_device_id", "a default device requires default_device_id.");
        }
    }
}

[WireObject]
public sealed record EngineSettingsResult(
    [property: WireMember("revision")] EngineID Revision,
    [property: WireMember("settings")] EngineSettings Settings);

[WireObject]
public sealed record EngineProgressPayload(
    [property: WireMember("stage")] EngineStage Stage,
    [property: WireMember("completed_units")] ulong CompletedUnits,
    [property: WireMember("total_units", IsNullable = true)] ulong? TotalUnits,
    [property: WireMember("session_id", IsNullable = true)] string? SessionID) : IWireValidatable
{
    public void Validate(string path)
    {
        if (TotalUnits.HasValue)
        {
            WireCheck.Require(CompletedUnits <= TotalUnits.Value, path + ".completed_units", "completed_units must not exceed total_units.");
        }

        WireCheck.OptionalNonempty(SessionID, path + ".session_id");
    }
}

[WireObject]
public sealed record EnginePresentationState(
    [property: WireMember("recording_status_text")] string RecordingStatusText,
    [property: WireMember("recording_tone")] EngineRecordingTone RecordingTone,
    [property: WireMember("preparation_phase")] EnginePreparationPhase PreparationPhase,
    [property: WireMember("preparation_status_text", IsNullable = true)] string? PreparationStatusText,
    [property: WireMember("recovery_status_text", IsNullable = true)] string? RecoveryStatusText,
    [property: WireMember("processing_status_text", IsNullable = true)] string? ProcessingStatusText,
    [property: WireMember("live_failure_notices")] string[] LiveFailureNotices,
    [property: WireMember("silence_warning_active")] bool SilenceWarningActive,
    [property: WireMember("silence_warning_text", IsNullable = true)] string? SilenceWarningText,
    [property: WireMember("audio_gap_count")] ulong AudioGapCount,
    [property: WireMember("audio_gap_text", IsNullable = true)] string? AudioGapText,
    [property: WireMember("processing_indicator")] EngineProcessingIndicator ProcessingIndicator) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(RecordingStatusText, path + ".recording_status_text");
        var preparationRequiresStatusText = PreparationPhase is EnginePreparationPhase.Preparing or EnginePreparationPhase.Failed;
        WireCheck.Require(
            (PreparationStatusText is not null) == preparationRequiresStatusText,
            path + ".preparation_status_text",
            "preparation_status_text presence must match preparation_phase.");
        WireCheck.OptionalNonempty(PreparationStatusText, path + ".preparation_status_text");
        WireCheck.OptionalNonempty(RecoveryStatusText, path + ".recovery_status_text");
        WireCheck.OptionalNonempty(ProcessingStatusText, path + ".processing_status_text");
        if (LiveFailureNotices is not null)
        {
            for (var index = 0; index < LiveFailureNotices.Length; index++)
            {
                WireCheck.Nonempty(LiveFailureNotices[index], path + ".live_failure_notices[" + index + "]");
            }
        }

        WireCheck.Require(
            SilenceWarningActive == (SilenceWarningText is not null),
            path + ".silence_warning_active",
            "silence_warning_active must match silence_warning_text presence.");
        WireCheck.OptionalNonempty(SilenceWarningText, path + ".silence_warning_text");
        if (AudioGapText is not null)
        {
            WireCheck.Nonempty(AudioGapText, path + ".audio_gap_text");
            WireCheck.Require(AudioGapCount > 0, path + ".audio_gap_count", "audio_gap_text requires a positive audio_gap_count.");
        }
    }
}
