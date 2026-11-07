using System.Collections.Immutable;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public enum ShellPhase { Connecting, Running, EngineFailed, Closed, Disposed }
public enum ShellSettingsStatus { Unknown, Required, Corrupt, Available }
public sealed record DeviceLostNotice(string Message, string SessionID);

/// <summary>A complete, revision-bound row-details snapshot returned by the engine.</summary>
public sealed record ShellRowDetails(string SessionID, EngineID Revision, string RowID,
    EngineClauseState ClauseState, string ClauseStateText, ImmutableArray<EngineTranscriptSpeakerSpan> Speakers);

public sealed record ShellState
{
    public ShellPhase Phase { get; init; } = ShellPhase.Connecting;
    public EngineCapabilities? Capabilities { get; init; }
    public EngineDevicesResult? Devices { get; init; }
    public EngineState? Engine { get; init; }
    public EngineProgressPayload? Progress { get; init; }
    public EngineDiagnosticsResult? Diagnostics { get; init; }
    public EngineModelsInspection? ModelsInspection { get; init; }
    public EngineSettingsResult? ConfirmedSettings { get; init; }
    public EngineSettings? SettingsDraft { get; init; }
    public ShellSettingsStatus SettingsStatus { get; init; } = ShellSettingsStatus.Unknown;
    public bool SettingsConflict { get; init; }
    public EngineFailure? LastError { get; init; }
    public DeviceLostNotice? DeviceLostNotice { get; init; }
    public string? CommandError { get; init; }
    public EngineClientFailure? EngineFailure { get; init; }
    public string? StoreFailure { get; init; }
    public ShellTranscriptState Transcript { get; init; } = new();
    public ShellPageWindow<EngineSessionListResult> Sessions { get; init; } = new();
    public string? SelectedFolderID { get; init; }
    public EngineSessionSummary? SessionInspection { get; init; }
    public ImmutableHashSet<EngineCommandName> Pending { get; init; } = ImmutableHashSet<EngineCommandName>.Empty;
    public bool IsPending(EngineCommandName command) => Pending.Contains(command);
}
