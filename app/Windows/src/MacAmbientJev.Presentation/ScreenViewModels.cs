using System.Windows.Input;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public sealed record ShellSourceChoice(EngineSource Value, string Label);
public sealed record ShellDeviceChoice(EngineDevice Value, string Label);

public enum ShellRecordingAction { Start, Stop }
public enum ShellRecordingGlyph { Record, Stop }

/// <summary>A toggle can stop an authoritative recording before its start request has completed.</summary>
public sealed class ShellRecordingCommand : ICommand
{
    private readonly ShellCommand _start, _stop;
    private readonly Func<ShellRecordingAction> _action;
    private ShellCommand? _lastExecuted;

    internal ShellRecordingCommand(ShellCommand start, ShellCommand stop, Func<ShellRecordingAction> action)
    {
        _start = start; _stop = stop; _action = action;
    }

    private ShellCommand Current => _action() == ShellRecordingAction.Stop ? _stop : _start;
    public Task? Execution => _lastExecuted?.Execution;
    public bool CanExecute(object? parameter) => Current.CanExecute(parameter);
    public void Execute(object? parameter)
    {
        var command = Current;
        if (!command.CanExecute(parameter)) return;
        _lastExecuted = command;
        command.Execute(parameter);
    }
    public event EventHandler? CanExecuteChanged
    {
        add { _start.CanExecuteChanged += value; _stop.CanExecuteChanged += value; }
        remove { _start.CanExecuteChanged -= value; _stop.CanExecuteChanged -= value; }
    }
}

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
        var start = Command(CanStartRecording, _ => Context.Store.ExecuteAsync(
            new EngineCommand.RecordingStart(CreateRecordingStartPayload())));
        var stop = Command(CanStopRecording, _ =>
        {
            var recording = Context.Store.State.Engine?.Recording ?? throw new InvalidOperationException("There is no authoritative recording session to stop.");
            return Context.Store.ExecuteAsync(new EngineCommand.RecordingStop(new EngineSessionPayload(recording.SessionID)));
        });
        ToggleRecording = new ShellRecordingCommand(start, stop, () => RecordingActionFor(Context.Store.State));
        ImportAudio = Command(CanImportAudio, ImportAudioAsync);
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

    public EngineSource? SelectedSource => _selectedSource;
    public EngineDevice? SelectedDevice => _selectedDevice;

    public ShellSourceChoice? SelectedSourceChoice
    {
        get => Sources.SingleOrDefault(choice => choice.Value == _selectedSource);
        set
        {
            // Replacing ItemsSource can write a transient null SelectedItem back to the binding.
            // Only an explicit choice changes the semantic selection.
            if (value is null || _selectedSource == value.Value) return;
            _selectedSource = value.Value;
            _selectedDevice = new EngineDevice.Default();
            _hasDeviceChoices = false;
            Context.RequestRefresh();
            if (RefreshDevices.CanExecute(null)) RefreshDevices.Execute(null);
        }
    }

    public ShellDeviceChoice? SelectedDeviceChoice
    {
        get => Devices.SingleOrDefault(choice => Equals(choice.Value, _selectedDevice));
        set
        {
            // A list refresh must not erase the selected endpoint, even if it disappeared.
            // An unavailable endpoint stays invalid rather than silently selecting the default.
            if (value is null || Equals(_selectedDevice, value.Value)) return;
            _selectedDevice = value.Value;
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
                !state.IsPending(EngineCommandName.DevicesList) && !state.IsPending(EngineCommandName.SessionImport);
        }
    }

    public EnginePresentationState? Presentation => Snapshot.Engine?.Presentation;
    public string? RecordingStatusText => Presentation?.RecordingStatusText;
    public EngineRecordingTone? RecordingTone => Presentation?.RecordingTone;
    public EngineProcessingIndicator? ProcessingIndicator => Presentation?.ProcessingIndicator;
    public string? ProcessingStatusText => Presentation?.ProcessingStatusText;
    public EnginePreparationPhase? PreparationPhase => Presentation?.PreparationPhase;
    public string? PreparationStatusText => Presentation?.PreparationStatusText;
    public string? RecoveryStatusText => Presentation?.RecoveryStatusText;
    public bool HasProcessingStatus => ProcessingStatusText is not null;
    public bool IsProcessing => ProcessingIndicator is EngineProcessingIndicator.Running or EngineProcessingIndicator.Backlogged;
    public bool HasPreparationStatus => PreparationStatusText is not null;
    public bool IsPreparingModels => PreparationPhase == EnginePreparationPhase.Preparing;
    public bool IsPreparationFailed => PreparationPhase == EnginePreparationPhase.Failed;
    public string? SilenceWarningText => Presentation?.SilenceWarningText;
    public bool HasSilenceWarning => Presentation?.SilenceWarningActive == true;
    public string? AudioGapText => Presentation?.AudioGapText;
    public bool HasAudioGap => AudioGapText is not null;
    public IReadOnlyList<string>? LiveFailureNotices => Presentation?.LiveFailureNotices;
    public bool HasLiveFailureNotices => LiveFailureNotices is { Count: > 0 };
    public ShellTranscriptState Transcript => Snapshot.Transcript;
    public EngineRecordingState? Recording => Snapshot.Engine?.Recording;
    public bool IsRecording => Recording?.Phase is EngineRecordingPhase.Recording or EngineRecordingPhase.WaitingForDevice;
    public bool IsRecordingStarting => Recording?.Phase == EngineRecordingPhase.Starting || Snapshot.IsPending(EngineCommandName.RecordingStart);
    public bool IsRecordingStopping => Recording?.Phase == EngineRecordingPhase.Stopping || Snapshot.IsPending(EngineCommandName.RecordingStop);
    public ShellRecordingAction RecordingAction => RecordingActionFor(Snapshot);
    public ShellRecordingGlyph RecordingGlyph => RecordingAction == ShellRecordingAction.Stop ? ShellRecordingGlyph.Stop : ShellRecordingGlyph.Record;
    public string RecordingLabel => RecordingAction == ShellRecordingAction.Stop ? "録音を停止" : "録音を開始";
    public string RecordingHelp => RecordingAction == ShellRecordingAction.Stop
        ? RecordingDisabledReason ?? "録音を終えて文字起こしを確定"
        : RecordingDisabledReason ?? (_selectedSource == EngineSource.SystemAudio
            ? "PC で再生中の音声を録音し、その場で文字起こし"
            : "マイクの音声を録音し、その場で文字起こし");
    public string ImportLabel => "音声ファイルを読み込む"; public bool IsImporting => Snapshot.IsPending(EngineCommandName.SessionImport);
    public string ImportHelp => ImportDisabledReason ?? "音声ファイルを読み込んで文字起こし";
    public string SourceHelp => CanChangeRecordingSelection
        ? "録音する音声をマイクかシステム音声から選択"
        : "録音中は切り替え不可";
    public string? ImportDisabledReason
    {
        get
        {
            var state = Snapshot;
            return state.Phase != ShellPhase.Running ? "エンジンの起動後に音声ファイルを読み込めます。" :
                state.Engine is null ? "エンジンの状態を確認してから音声ファイルを読み込んでください。" :
                state.Engine.Recording is not null ? "録音中は音声ファイルを読み込めません。" :
                state.IsPending(EngineCommandName.RecordingStart) || state.IsPending(EngineCommandName.RecordingStop) ? "録音の開始・停止中は音声ファイルを読み込めません。" :
                state.IsPending(EngineCommandName.SessionImport) || ImportAudio.Execution is { IsCompleted: false } ? "音声ファイルの読み込み中です。" : null;
        }
    }
    public string ReturnToLatestLabel => "最新へ戻る"; public string EmptyTitle => "文字起こしはまだありません";
    public string EmptyDescription => Snapshot.Transcript.UnavailableReason ?? (Snapshot.Transcript.SessionID is null
        ? "録音を開始するか、音声ファイルを読み込むか、保存済み録音を選ぶとここに文字起こしが表示されます。"
        : "この録音には表示できる文字起こしがありません。処理中の場合は、作成された行がここに表示されます。");
    public ShellRecordingCommand ToggleRecording { get; } public ShellCommand ImportAudio { get; }
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
            !state.IsPending(EngineCommandName.RecordingStart) && !state.IsPending(EngineCommandName.RecordingStop) &&
            !state.IsPending(EngineCommandName.DevicesList) && !state.IsPending(EngineCommandName.SettingsReplace) &&
            !state.IsPending(EngineCommandName.SessionImport);
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

    private bool CanImportAudio(object? parameter) => parameter is IPathPicker && ImportDisabledReason is null;

    private async Task ImportAudioAsync(object? parameter)
    {
        string? path; try { path = await ((IPathPicker)parameter!).PickAudioFileAsync(); }
        catch (Exception exception) { await Context.Store.ReportCommandErrorAsync(exception.Message); return; }
        if (path is not null) await Context.Store.ImportAudioAsync(path);
    }

    private bool CanStopRecording(object? parameter)
    {
        if (parameter is not null) return false;
        var state = Context.Store.State;
        // Starting cannot be cancelled by the engine protocol. Once capture is authoritative,
        // stopping is valid even if recording.start has not returned its response yet.
        return state.Engine?.Recording is { Phase: EngineRecordingPhase.Recording or EngineRecordingPhase.WaitingForDevice } &&
            !state.IsPending(EngineCommandName.RecordingStop);
    }

    private static ShellRecordingAction RecordingActionFor(ShellState state) =>
        state.Engine?.Recording is not null || state.IsPending(EngineCommandName.RecordingStart) || state.IsPending(EngineCommandName.RecordingStop)
            ? ShellRecordingAction.Stop : ShellRecordingAction.Start;

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
    public Task EditDraftAsync(EngineSettings? draft) => Context.Store.SetSettingsDraftAsync(draft);

    /// <summary>Null drafts are incomplete; exportDestinationChosen distinguishes a chosen null path from an unanswered choice.</summary>
    public static EngineSettings? CreateDraft(
        long? schemaVersion, EngineSource? source, EngineDevice? device, EngineASRSize? asrSize,
        EngineExecutionProvider? executionProvider, long? threads, bool? lowHeat, bool? decisionsEnabled,
        bool? automaticExport, bool exportDestinationChosen, string? exportDestinationPath)
    {
        if (schemaVersion is not long version || source is not EngineSource selectedSource || device is null ||
            asrSize is not EngineASRSize selectedAsrSize || executionProvider is not EngineExecutionProvider selectedProvider ||
            threads is not long selectedThreads || lowHeat is not bool selectedLowHeat ||
            decisionsEnabled is not bool selectedDecisionsEnabled || automaticExport is not bool selectedAutomaticExport ||
            !exportDestinationChosen) return null;
        var draft = new EngineSettings(version, selectedSource, device, selectedAsrSize, selectedProvider, selectedThreads,
            selectedLowHeat, selectedDecisionsEnabled, selectedAutomaticExport, exportDestinationPath);
        draft.Validate("$.settings");
        return draft;
    }

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
