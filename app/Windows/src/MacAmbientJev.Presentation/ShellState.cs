using System.Collections.Immutable;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public enum ShellPhase { Connecting, Running, EngineFailed, Closed, Disposed }
public enum ShellSettingsStatus { Unknown, Required, Corrupt, Available }

public sealed record ShellState
{
    public ShellPhase Phase { get; init; } = ShellPhase.Connecting;
    public EngineCapabilities? Capabilities { get; init; }
    public EngineState? Engine { get; init; }
    public EngineProgressPayload? Progress { get; init; }
    public EngineSettingsResult? ConfirmedSettings { get; init; }
    public EngineSettings? SettingsDraft { get; init; }
    public ShellSettingsStatus SettingsStatus { get; init; } = ShellSettingsStatus.Unknown;
    public bool SettingsConflict { get; init; }
    public EngineFailure? LastError { get; init; }
    public string? CommandError { get; init; }
    public EngineClientFailure? EngineFailure { get; init; }
    public string? StoreFailure { get; init; }
    public ShellTranscriptState Transcript { get; init; } = new();
    public ShellPageWindow<EngineSessionListResult> Sessions { get; init; } = new();
    public ImmutableHashSet<EngineCommandName> Pending { get; init; } = ImmutableHashSet<EngineCommandName>.Empty;
    public bool IsPending(EngineCommandName command) => Pending.Contains(command);
}
