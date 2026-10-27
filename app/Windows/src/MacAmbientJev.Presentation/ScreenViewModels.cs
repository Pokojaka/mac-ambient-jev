using MacAmbientJev.EngineClient;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public sealed record ShellSourceChoice(EngineSource Value, string Label);
public sealed record ShellDeviceChoice(EngineDevice Value, string Label);

public sealed partial class LiveViewModel : ScreenViewModel
{
    private EngineSource? _selectedSource = EngineSource.Microphone;
    private EngineDevice? _selectedDevice = new EngineDevice.Default();
    private bool _hasSourceChoices, _hasDeviceChoices;
    private EngineCapabilities? _sourceChoicesCapabilities, _deviceChoicesCapabilities;
    private EngineDevicesResult? _deviceChoicesResult;
    private EngineSource? _deviceChoicesSource;
    private IReadOnlyList<ShellSourceChoice> _sourceChoices = Array.Empty<ShellSourceChoice>();
    private IReadOnlyList<ShellDeviceChoice> _deviceChoices = Array.Empty<ShellDeviceChoice>();

    public LiveViewModel(ShellUiContext context) : base(context)
    {
        StartRecording = Command(CanStartRecording, _ => Context.Store.ExecuteAsync(
            new EngineCommand.RecordingStart(CreateRecordingStartPayload())));
        StopRecording = Command(CanStopRecording, _ =>
        {
            var recording = Context.Store.State.Engine?.Recording ?? throw new InvalidOperationException("There is no authoritative recording session to stop.");
            return Context.Store.ExecuteAsync(new EngineCommand.RecordingStop(new EngineSessionPayload(recording.SessionID)));
        });
        RefreshDevices = Command(CanRefreshDevices, _ => Context.Store.ReloadDevicesAsync(
            _selectedSource ?? throw new InvalidOperationException("A source must be selected before loading devices.")));
        ReturnToLatest = Command(_ =>
        {
            var state = Context.Store.State;
            return state.Transcript.SessionID is not null && !state.Transcript.Follow && !state.IsPending(EngineCommandName.TranscriptWatch);
        }, _ => Context.Store.ReturnToLatestAsync());
        ReadHistory = Command(CanReadHistory, parameter => Context.Store.ReadHistoryAsync((ShellPageMove)parameter!));
        _readOnlyRows = new System.Collections.ObjectModel.ReadOnlyObservableCollection<ShellTranscriptRowViewModel>(_rows);
        InitializeDisplay();
    }

    public EngineSource? SelectedSource
    {
        get => _selectedSource;
        set
        {
            if (_selectedSource == value) return;
            _selectedSource = value;
            _selectedDevice = null;
            _hasDeviceChoices = false;
            Context.RequestRefresh();
            if (RefreshDevices.CanExecute(null)) RefreshDevices.Execute(null);
        }
    }

    public EngineDevice? SelectedDevice
    {
        get => _selectedDevice;
        set
        {
            if (Equals(_selectedDevice, value)) return;
            _selectedDevice = value;
            Context.RequestRefresh();
        }
    }

    public IReadOnlyList<ShellSourceChoice> Sources
    {
        get
        {
            var capabilities = Snapshot.Capabilities;
            if (!_hasSourceChoices || !ReferenceEquals(_sourceChoicesCapabilities, capabilities))
            {
                _sourceChoicesCapabilities = capabilities;
                _sourceChoices = Array.AsReadOnly(capabilities is null
                    ? Array.Empty<ShellSourceChoice>()
                    : capabilities.Sources.Select(source => new ShellSourceChoice(source, SourceLabel(source))).ToArray());
                _hasSourceChoices = true;
            }
            return _sourceChoices;
        }
    }

    public IReadOnlyList<ShellDeviceChoice> Devices
    {
        get
        {
            var state = Snapshot;
            var capabilities = state.Capabilities;
            var devices = state.Devices;
            var source = _selectedSource;
            if (!_hasDeviceChoices || !ReferenceEquals(_deviceChoicesCapabilities, capabilities) ||
                !ReferenceEquals(_deviceChoicesResult, devices) || _deviceChoicesSource != source)
            {
                _deviceChoicesCapabilities = capabilities;
                _deviceChoicesResult = devices;
                _deviceChoicesSource = source;
                var choices = new List<ShellDeviceChoice> { new(new EngineDevice.Default(), "既定のデバイス") };
                if (source is EngineSource selectedSource && devices?.Source == selectedSource && devices.Devices is not null)
                    choices.AddRange(devices.Devices.Select(device => new ShellDeviceChoice(new EngineDevice.Id(device.ID), device.Name)));
                _deviceChoices = Array.AsReadOnly(choices.ToArray());
                _hasDeviceChoices = true;
            }
            return _deviceChoices;
        }
    }

    public bool CanChangeRecordingSelection
    {
        get
        {
            var state = Context.Store.State;
            return state.Phase == ShellPhase.Running && state.Engine is { Recording: null } &&
                !state.IsPending(EngineCommandName.RecordingStart) && !state.IsPending(EngineCommandName.RecordingStop) &&
                !state.IsPending(EngineCommandName.DevicesList);
        }
    }

    public EnginePresentationState? Presentation => Snapshot.Engine?.Presentation;
    public string? RecordingStatusText => Presentation?.RecordingStatusText;
    public string? SilenceWarningText => Presentation?.SilenceWarningText;
    public string? AudioGapText => Presentation?.AudioGapText;
    public IReadOnlyList<string>? LiveFailureNotices => Presentation?.LiveFailureNotices;
    public ShellTranscriptState Transcript => Snapshot.Transcript;
    public EngineRecordingState? Recording => Snapshot.Engine?.Recording;
    public string StartLabel => "録音を開始"; public string StopLabel => "録音を停止";
    public string ReturnToLatestLabel => "最新へ戻る"; public string EmptyTitle => "文字起こしはまだありません";
    public string EmptyDescription => "録音を開始するか、音声ファイルを読み込むとここに文字起こしが表示されます。";
    public ShellCommand StartRecording { get; } public ShellCommand StopRecording { get; }
    public ShellCommand RefreshDevices { get; } public ShellCommand ReturnToLatest { get; } public ShellCommand ReadHistory { get; }
    public Task UserScrolledAsync() => Context.Store.UserScrolledAsync();

    private EngineRecordingStartPayload CreateRecordingStartPayload() => new(
        _selectedSource ?? throw new InvalidOperationException("A source must be selected before recording."),
        _selectedDevice ?? throw new InvalidOperationException("A device must be selected before recording."));

    private bool CanStartRecording(object? parameter)
    {
        if (parameter is not null) return false;
        var state = Context.Store.State;
        var source = _selectedSource;
        var device = _selectedDevice;
        if (source is not EngineSource selectedSource || device is null || state.Capabilities is not { } capabilities ||
            !capabilities.Sources.Contains(selectedSource)) return false;
        if (device is EngineDevice.Id id &&
            (state.Devices is not { } listedDevices || listedDevices.Source != selectedSource || listedDevices.Devices is null ||
                !listedDevices.Devices.Any(endpoint => endpoint.ID == id.ID))) return false;
        var engine = state.Engine;
        return engine is { Setup: EngineSetupStatus.Ready, Recovery: EngineRecoveryStatus.Completed, Recording: null } &&
            engine.Presentation.PreparationPhase != EnginePreparationPhase.Preparing &&
            !state.IsPending(EngineCommandName.RecordingStart) && !state.IsPending(EngineCommandName.RecordingStop) &&
            !state.IsPending(EngineCommandName.DevicesList) && !state.IsPending(EngineCommandName.ModelsPrepare) &&
            !state.IsPending(EngineCommandName.SettingsReplace);
    }

    private bool CanRefreshDevices(object? parameter)
    {
        if (parameter is not null) return false;
        var source = _selectedSource;
        var state = Context.Store.State;
        return source is EngineSource selectedSource && state.Capabilities is { } capabilities &&
            capabilities.Sources.Contains(selectedSource) && !state.IsPending(EngineCommandName.DevicesList);
    }

    private static string SourceLabel(EngineSource source) => source switch
    {
        EngineSource.Microphone => "マイク",
        EngineSource.SystemAudio => "システム音声",
        _ => throw new InvalidOperationException($"Unknown engine source: {source}.")
    };

    private bool CanStopRecording(object? parameter)
    {
        if (parameter is not null) return false;
        var state = Context.Store.State;
        return state.Engine?.Recording is { Phase: EngineRecordingPhase.Recording or EngineRecordingPhase.WaitingForDevice } &&
            !state.IsPending(EngineCommandName.RecordingStart) && !state.IsPending(EngineCommandName.RecordingStop);
    }

    private bool CanReadHistory(object? parameter)
    {
        if (parameter is not ShellPageMove move) return false;
        var state = Context.Store.State;
        if (state.IsPending(EngineCommandName.TranscriptRead) || state.Transcript.SessionID is null) return false;
        if (move == ShellPageMove.Reload) return true;
        var transcript = state.Transcript; var page = transcript.History.Current;
        if (transcript.HistoryStale || page?.SessionID != transcript.SessionID) return false;
        return move switch
        {
            ShellPageMove.Next => page.NextCursor is not null,
            ShellPageMove.Previous => page.PreviousCursor is not null,
            _ => false
        };
    }
}

public sealed class ProcessingQueueViewModel : ScreenViewModel
{
    public ProcessingQueueViewModel(ShellUiContext context) : base(context) { }
    public IReadOnlyList<EngineQueuedOperation>? Queue => Snapshot.Engine?.Queue;
    public EngineProgressPayload? Progress => Snapshot.Progress;
    public string? ProcessingStatusText => Snapshot.Engine?.Presentation.ProcessingStatusText;
    public EngineProcessingIndicator? Indicator => Snapshot.Engine?.Presentation.ProcessingIndicator;
}

public sealed class SessionsViewModel : ScreenViewModel
{
    public SessionsViewModel(ShellUiContext context) : base(context)
    {
        List = Command(CanList, parameter => Context.Store.ListSessionsAsync((ShellPageMove)parameter!));
        Select = Command(CanSelect, parameter => Context.Store.SelectSessionAsync(((EngineSessionSummary)parameter!).SessionID!));
    }

    public ShellPageWindow<EngineSessionListResult> Pages => Snapshot.Sessions;
    public string Title => "保存済み録音"; public string RefreshLabel => "更新";
    public string EmptyTitle => "録音を選択してください"; public string EmptyDescription => "選んだ録音の処理状態を確認できます。";
    public ShellCommand List { get; } public ShellCommand Select { get; }

    private bool CanList(object? parameter)
    {
        if (parameter is not ShellPageMove move) return false;
        var state = Context.Store.State;
        if (state.IsPending(EngineCommandName.SessionList)) return false;
        if (move == ShellPageMove.Reload) return true;
        var page = state.Sessions.Current;
        return move switch
        {
            ShellPageMove.Next => page?.NextCursor is not null,
            ShellPageMove.Previous => page?.PreviousCursor is not null,
            _ => false
        };
    }

    private bool CanSelect(object? parameter)
    {
        if (parameter is not EngineSessionSummary { SessionID: not null }) return false;
        var state = Context.Store.State;
        return state.Engine is { Recording: null } && !state.IsPending(EngineCommandName.TranscriptWatch);
    }
}

public sealed class SettingsViewModel : ScreenViewModel
{
    public SettingsViewModel(ShellUiContext context) : base(context)
    {
        Commit = Command(CanCommit, _ => Context.Store.CommitSettingsAsync());
        Reload = Command(_ => !HasSettingsRequest(Context.Store.State), _ => Context.Store.ReloadSettingsAsync());
        PrepareModels = Command(CanPrepareModels, _ => Context.Store.ExecuteAsync(new EngineCommand.ModelsPrepare(new EngineEmptyPayload())));
    }

    public EngineSettings? Draft => Snapshot.SettingsDraft; public EngineSettingsResult? Confirmed => Snapshot.ConfirmedSettings;
    public ShellSettingsStatus Status => Snapshot.SettingsStatus; public bool HasConflict => Snapshot.SettingsConflict;
    public EngineCapabilities? Capabilities => Snapshot.Capabilities;
    public string Title => "設定"; public string GeneralTab => "一般"; public string DiagnosticsTab => "診断";
    public string PrepareLabel => "モデルを準備";
    public string? AutomaticInputVolume => Capabilities?.AutomaticInputVolume switch
    { null => null, EngineUnavailableCapability.None => "なし", _ => throw new InvalidOperationException("Unknown automatic input volume capability.") };
    public string? ThermalMonitoring => Capabilities?.ThermalMonitoring switch
    { null => null, EngineUnavailableCapability.None => "なし", _ => throw new InvalidOperationException("Unknown thermal monitoring capability.") };
    public ShellCommand Commit { get; } public ShellCommand Reload { get; } public ShellCommand PrepareModels { get; }
    public Task EditDraftAsync(EngineSettings draft) => Context.Store.SetSettingsDraftAsync(draft);

    private bool CanCommit(object? parameter)
    {
        var state = Context.Store.State;
        return state.SettingsDraft is not null && !HasSettingsRequest(state) && CanRunWithoutRecording(state);
    }
    private bool CanPrepareModels(object? parameter)
    {
        var state = Context.Store.State;
        return state.ConfirmedSettings is not null && !state.IsPending(EngineCommandName.ModelsPrepare) &&
            !state.IsPending(EngineCommandName.SettingsReplace) && CanRunWithoutRecording(state);
    }
    private static bool HasSettingsRequest(ShellState state) =>
        state.IsPending(EngineCommandName.SettingsGet) || state.IsPending(EngineCommandName.SettingsReplace);
    private static bool CanRunWithoutRecording(ShellState state) =>
        state.Engine is { Recording: null } engine && engine.Presentation.PreparationPhase != EnginePreparationPhase.Preparing;
}

public sealed class DiagnosticsViewModel : ScreenViewModel
{
    public DiagnosticsViewModel(ShellUiContext context) : base(context)
    {
        Refresh = Command(_ => !Context.Store.State.IsPending(EngineCommandName.DiagnosticsGet),
            _ => Context.Store.ExecuteAsync(new EngineCommand.DiagnosticsGet(new EngineEmptyPayload())));
        InspectModels = Command(_ => !Context.Store.State.IsPending(EngineCommandName.ModelsInspect),
            _ => Context.Store.ExecuteAsync(new EngineCommand.ModelsInspect(new EngineEmptyPayload())));
    }

    public EngineDiagnosticsResult? Diagnostics => Snapshot.Diagnostics;
    public EngineModelsInspection? ModelsInspection => Snapshot.ModelsInspection;
    public bool IsLoading => Snapshot.IsPending(EngineCommandName.DiagnosticsGet);
    public bool IsInspectingModels => Snapshot.IsPending(EngineCommandName.ModelsInspect);
    public EngineDecisionUsageSnapshot? Usage => Snapshot.Diagnostics?.DecisionUsage is EngineDecisionUsage.Available available ? available.Snapshot : null;
    public EngineFailure? UsageError => Snapshot.Diagnostics?.DecisionUsage is EngineDecisionUsage.Unavailable unavailable ? unavailable.Error : null;
    public EngineClientFailure? EngineFailure => Snapshot.EngineFailure;
    public string Title => "診断"; public string UsageTitle => "発話文判定の利用状況（判定リクエスト単位）";
    public string RefreshLabel => "利用状況を更新"; public string InspectModelsLabel => "モデルを確認";
    public ShellCommand Refresh { get; } public ShellCommand InspectModels { get; }
}
