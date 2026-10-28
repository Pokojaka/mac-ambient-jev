using System.Collections.Specialized;
using System.ComponentModel;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Presentation.Tests;

public sealed partial class ShellStoreTests
{
    [Fact]
    public async Task CanExecuteTracksPendingAndPhase()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var live = new LiveViewModel(context); var diagnostics = new DiagnosticsViewModel(context);
        var payload = new EngineRecordingStartPayload(EngineSource.Microphone, new EngineDevice.Default());
        Assert.True(live.StartRecording.CanExecute(null)); live.StartRecording.Execute(null); live.StartRecording.Execute(null);
        Assert.False(live.StartRecording.CanExecute(null)); var execution = live.StartRecording.Execution!; var request = await engine.NextRequestAsync();
        await ChangedTo(store, s => s.IsPending(EngineCommandName.RecordingStart));
        Assert.False(live.StartRecording.CanExecute(null)); Assert.Equal(2, engine.SentCount);
        request.Reject(Failure(EngineErrorCode.Busy, "busy", EngineRecoveryAction.Retry)); await execution;
        var direct = store.ExecuteAsync(new EngineCommand.RecordingStart(payload)); request = await engine.NextRequestAsync();
        await ChangedTo(store, s => s.IsPending(EngineCommandName.RecordingStart)); Assert.False(live.StartRecording.CanExecute(null));
        request.Reject(Failure(EngineErrorCode.Busy, "busy", EngineRecoveryAction.Retry)); Assert.False(await direct);
        var revision = 1UL;
        foreach (var phase in Enum.GetValues<EngineRecordingPhase>())
        {
            var state = State(EngineSetupStatus.Ready, ++revision) with { Recording = new EngineRecordingState("session", EngineSource.Microphone, new EngineDevice.Default(), phase) };
            engine.EmitBatch(new EngineOutput(1, new EngineID(revision), null, new EngineEvent.State(state)));
            await ChangedTo(store, s => s.Engine?.Revision == new EngineID(revision));
            Assert.False(live.StartRecording.CanExecute(null));
            Assert.Equal(phase is EngineRecordingPhase.Recording or EngineRecordingPhase.WaitingForDevice, live.StopRecording.CanExecute(null));
        }
        var failed = new EngineClientFailure("exited", 1, Failure(EngineErrorCode.DeviceFailure, "failed", EngineRecoveryAction.Retry), new StderrSnapshot([], 0));
        engine.SignalFailure(failed); engine.CompleteFailure(failed); await ChangedTo(store, s => s.Phase == ShellPhase.EngineFailed);
        Assert.False(live.StartRecording.CanExecute(null)); Assert.False(diagnostics.Refresh.CanExecute(null));
    }
    [Fact]
    public async Task RecordingSelectionUsesCurrentSourceAndDeviceDraft()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var live = new LiveViewModel(context);
        Assert.Equal(EngineSource.Microphone, live.SelectedSource);
        Assert.Equal(new EngineDevice.Default(), live.SelectedDevice);
        Assert.Equal("既定のデバイス", Assert.Single(live.Devices).Label);

        var capabilities = new EngineCapabilities([EngineSource.Microphone, EngineSource.SystemAudio], [EngineASRSize.Small],
            [EngineExecutionProvider.Cpu], 4, EngineUnavailableCapability.None, EngineUnavailableCapability.None);
        var capabilitiesChanged = ChangedAfter(store, state => ReferenceEquals(state.Capabilities, capabilities));
        engine.EmitBatch(new EngineOutput(1, new EngineID(1), null,
            new EngineEvent.Ready(new EngineReadyPayload(capabilities, State(EngineSetupStatus.Ready, 2)))));
        await capabilitiesChanged; dispatcher.Run();
        var sourceChoices = live.Sources;
        Assert.Equal(new[] { EngineSource.Microphone, EngineSource.SystemAudio }, sourceChoices.Select(choice => choice.Value));
        Assert.Equal(new[] { "マイク", "システム音声" }, sourceChoices.Select(choice => choice.Label));

        var requestedSources = new List<EngineSource>();
        EngineResult DevicesResponse(EngineCommand command)
        {
            var request = Assert.IsType<EngineCommand.DevicesList>(command);
            var source = request.Payload.Source; requestedSources.Add(source);
            var endpoint = source switch
            {
                EngineSource.Microphone => new EngineDeviceInfo("mic-endpoint", "Microphone endpoint", false),
                EngineSource.SystemAudio => new EngineDeviceInfo("system-endpoint", "System endpoint", false),
                _ => throw new InvalidOperationException($"Unexpected source {source}.")
            };
            return new EngineResult.DevicesList(new EngineDevicesResult(source, [endpoint], null));
        }
        engine.AutoResponse = DevicesResponse;
        Assert.True(live.RefreshDevices.CanExecute(null));
        live.RefreshDevices.Execute(null); await live.RefreshDevices.Execution!;
        await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(100)); dispatcher.Run();
        Assert.Equal(new[] { EngineSource.Microphone }, requestedSources);
        var microphoneChoices = live.Devices;
        var microphoneChoice = Assert.Single(microphoneChoices, choice => choice.Value is EngineDevice.Id);
        Assert.Equal("Microphone endpoint", microphoneChoice.Label);
        Assert.Same(sourceChoices, live.Sources);

        engine.AutoResponse = null;
        live.SelectedDevice = microphoneChoice.Value;
        Assert.True(live.StartRecording.CanExecute(null));
        live.StartRecording.Execute(null);
        var startExecution = live.StartRecording.Execution!; var startRequest = await engine.NextRequestAsync();
        await ChangedTo(store, state => state.IsPending(EngineCommandName.RecordingStart));
        Assert.False(live.CanChangeRecordingSelection);
        Assert.Equal(new EngineRecordingStartPayload(EngineSource.Microphone, new EngineDevice.Id("mic-endpoint")),
            Assert.IsType<EngineCommand.RecordingStart>(startRequest.Command).Payload);
        startRequest.Reject(Failure(EngineErrorCode.Busy, "busy", EngineRecoveryAction.Retry)); await startExecution;
        await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(100)); dispatcher.Run();
        Assert.Same(sourceChoices, live.Sources); Assert.Same(microphoneChoices, live.Devices);

        live.SelectedDevice = null;
        Assert.False(live.StartRecording.CanExecute(null));
        live.SelectedDevice = microphoneChoice.Value;
        engine.AutoResponse = DevicesResponse;
        var systemDevicesPending = ChangedAfter(store, state => state.IsPending(EngineCommandName.DevicesList));
        live.SelectedSource = EngineSource.SystemAudio;
        Assert.Null(live.SelectedDevice);
        Assert.Equal("既定のデバイス", Assert.Single(live.Devices).Label);
        await systemDevicesPending;
        await live.RefreshDevices.Execution!;
        await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(100)); dispatcher.Run();
        engine.AutoResponse = null;
        Assert.Equal(new[] { EngineSource.Microphone, EngineSource.SystemAudio }, requestedSources);
        Assert.DoesNotContain(live.Devices, choice => choice.Value is EngineDevice.Id id && id.ID == "mic-endpoint");
        Assert.Contains(live.Devices, choice => choice.Value is EngineDevice.Id id && id.ID == "system-endpoint");
        live.SelectedDevice = microphoneChoice.Value;
        Assert.False(live.StartRecording.CanExecute(null));
        live.SelectedDevice = null;
        Assert.False(live.StartRecording.CanExecute(null));
        live.SelectedSource = (EngineSource)999;
        Assert.False(live.StartRecording.CanExecute(null));
        Assert.False(live.RefreshDevices.CanExecute(null));
    }

    [Fact]
    public async Task OneDispatcherRefreshPerBatch()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var live = new LiveViewModel(context); var queue = new ProcessingQueueViewModel(context); var sessions = new SessionsViewModel(context, new TestFolderRevealer());
        var settings = new SettingsViewModel(context); var diagnostics = new DiagnosticsViewModel(context);
        var notifications = 0; var commandNotifications = 0;
        void PropertyChanged(object? sender, PropertyChangedEventArgs args) { Assert.True(dispatcher.IsRunningCallback); Interlocked.Increment(ref notifications); }
        foreach (var vm in new ScreenViewModel[] { live, queue, sessions, settings, diagnostics }) vm.PropertyChanged += PropertyChanged;
        foreach (var command in new[] { live.StartRecording, sessions.List, settings.Commit, diagnostics.Refresh })
            command.CanExecuteChanged += (_, _) => { Assert.True(dispatcher.IsRunningCallback); Interlocked.Increment(ref commandNotifications); };
        var first = new EngineProgressPayload(EngineStage.ValidatingModels, 1, 9, null);
        var incoming = State(EngineSetupStatus.Ready, 2) with { Presentation = State(EngineSetupStatus.Ready, 2).Presentation with { RecordingStatusText = "changed" } };
        var firstChanged = ChangedAfter(store, s => s.Progress == first);
        engine.EmitBatch(new EngineOutput(1, new EngineID(1), null, new EngineEvent.State(incoming)), new EngineOutput(1, new EngineID(2), null, new EngineEvent.Progress(first)), Rows("irrelevant", EngineRowsKind.Changes));
        await ChangedTo(store, s => s.Progress == first); await firstChanged; Assert.Equal(1, dispatcher.PendingCount);
        Assert.Equal("Idle", live.RecordingStatusText); Assert.Null(queue.Progress); Assert.Null(diagnostics.Diagnostics);
        Assert.Equal(store.State.SettingsDraft, settings.Draft); Assert.Equal(0, notifications); Assert.Equal(0, commandNotifications);
        dispatcher.Run(); Assert.Equal(5, notifications); Assert.True(commandNotifications > 0); Assert.Equal("changed", live.RecordingStatusText); Assert.Equal(first, queue.Progress);
        var second = new EngineProgressPayload(EngineStage.LoadingModels, 3, 9, null);
        var delayChanged = ChangedAfter(store, s => s.Progress?.CompletedUnits == 2);
        engine.EmitBatch(new EngineOutput(1, new EngineID(3), null, new EngineEvent.Progress(new EngineProgressPayload(EngineStage.LoadingModels, 2, 9, null)))); await delayChanged;
        await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(100));
        var latestChanged = ChangedAfter(store, s => s.Progress == second); engine.EmitBatch(new EngineOutput(1, new EngineID(4), null, new EngineEvent.Progress(second)));
        await ChangedTo(store, s => s.Progress == second); await latestChanged; Assert.Equal(1, dispatcher.PendingCount); Assert.Equal(1, dispatcher.MaximumPending);
        dispatcher.Run(); Assert.Equal(second, queue.Progress);
        var nested = new EngineProgressPayload(EngineStage.LoadingModels, 4, 9, null); Task<ShellState>? nestedChange = null;
        live.PropertyChanged += (_, _) => { if (dispatcher.IsRunningCallback && nestedChange is null) { nestedChange = ChangedAfter(store, s => s.Progress == nested); engine.EmitBatch(new EngineOutput(1, new EngineID(5), null, new EngineEvent.Progress(nested))); } };
        var third = new EngineProgressPayload(EngineStage.LoadingModels, 5, 9, null); var thirdChanged = ChangedAfter(store, s => s.Progress == third);
        engine.EmitBatch(new EngineOutput(1, new EngineID(6), null, new EngineEvent.Progress(third)));
        await ChangedTo(store, s => s.Progress == third); await thirdChanged; await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(100)); Assert.Equal(1, dispatcher.PendingCount); dispatcher.Run(); await ChangedTo(store, s => s.Progress == nested); await nestedChange!;
        await clock.WaitForTimerAsync(); Assert.Equal(0, dispatcher.PendingCount); clock.Advance(TimeSpan.FromMilliseconds(100)); Assert.Equal(1, dispatcher.PendingCount); dispatcher.Run();
        Assert.Equal(nested, queue.Progress); Assert.Equal(1, dispatcher.MaximumPending);
    }
    [Fact]
    public async Task DispatcherRejectionFailsStore()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher { Reject = true }; using var context = new ShellUiContext(store, dispatcher, clock);
        var diagnostics = new DiagnosticsViewModel(context); var notifications = 0;
        diagnostics.PropertyChanged += (_, _) => notifications++;
        var progress = new EngineProgressPayload(EngineStage.ValidatingModels, 1, 2, null);
        engine.EmitBatch(new EngineOutput(1, new EngineID(1), null, new EngineEvent.Progress(progress)));
        var failed = await ChangedTo(store, s => s.StoreFailure is not null && s.Phase == ShellPhase.EngineFailed);
        Assert.Contains("dispatcher rejected", failed.StoreFailure!, StringComparison.OrdinalIgnoreCase); Assert.Equal(0, notifications);
        engine.EmitBatch(new EngineOutput(1, new EngineID(2), null, new EngineEvent.Progress(progress with { CompletedUnits = 2 })));
        await ChangedTo(store, s => s.Progress?.CompletedUnits == 2); Assert.Equal(1, dispatcher.EnqueueCount); Assert.Equal(0, notifications);
    }
    [Fact]
    public async Task SettingsEditsOnlyDraft()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var vm = new SettingsViewModel(context); var confirmed = store.State.ConfirmedSettings; var original = vm.Draft;
        var edited = Settings(3, true, true, false, "/draft"); var sent = engine.SentCount;
        await vm.EditDraftAsync(edited);
        Assert.Same(confirmed, store.State.ConfirmedSettings); Assert.Equal(edited, store.State.SettingsDraft);
        Assert.Equal(original, vm.Draft); Assert.Equal(sent, engine.SentCount); dispatcher.Run();
        Assert.Equal(edited, vm.Draft); Assert.Same(confirmed, store.State.ConfirmedSettings); Assert.Equal(sent, engine.SentCount);
    }
    [Fact]
    public async Task CreateDraftRequiresEveryExplicitChoice()
    {
        var complete = SettingsViewModel.CreateDraft(1, EngineSource.Microphone, new EngineDevice.Default(), EngineASRSize.Large,
            EngineExecutionProvider.Cpu, 1, false, false, false, true, null);
        Assert.Equal(new EngineSettings(1, EngineSource.Microphone, new EngineDevice.Default(), EngineASRSize.Large,
            EngineExecutionProvider.Cpu, 1, false, false, false, null), complete);
        EngineSettings? Draft(int missing) => SettingsViewModel.CreateDraft(
            missing == 0 ? null : 1, missing == 1 ? null : EngineSource.Microphone,
            missing == 2 ? null : new EngineDevice.Default(), missing == 3 ? null : EngineASRSize.Large,
            missing == 4 ? null : EngineExecutionProvider.Cpu, missing == 5 ? null : 1,
            missing == 6 ? null : false, missing == 7 ? null : false, missing == 8 ? null : false,
            missing != 9, null);
        for (var missing = 0; missing < 10; missing++) Assert.Null(Draft(missing));

        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var vm = new SettingsViewModel(context); var confirmed = store.State.ConfirmedSettings;
        await vm.EditDraftAsync(null);
        Assert.Same(confirmed, store.State.ConfirmedSettings); Assert.Null(store.State.SettingsDraft); Assert.False(vm.Commit.CanExecute(null));
        await vm.EditDraftAsync(complete);
        Assert.Same(confirmed, store.State.ConfirmedSettings); Assert.True(vm.Commit.CanExecute(null));
    }
    [Fact]
    public async Task DiagnosticsLoadingDoesNotInventCounters()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var vm = new DiagnosticsViewModel(context); var pendingChange = ChangedAfter(store, s => s.IsPending(EngineCommandName.DiagnosticsGet)); vm.Refresh.Execute(null); var request = await engine.NextRequestAsync();
        await ChangedTo(store, s => s.IsPending(EngineCommandName.DiagnosticsGet)); await pendingChange; dispatcher.Run(); Assert.True(vm.IsLoading); Assert.Null(vm.Usage);
        var usage = new EngineDecisionUsageSnapshot(7, 11, 5, 2, 1, 2, new EngineDecisionRequestUsage(4, 6, 3, 1), new EngineDecisionRequestUsage(3, 5, 2, 1));
        request.Complete(new EngineResult.DiagnosticsGet(new EngineDiagnosticsResult(EngineDiagnosticsScope.EngineProcess, new EngineDecisionUsage.Available(usage), EngineUnavailableCapability.None, EngineUnavailableCapability.None)));
        await vm.Refresh.Execution!; await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(100)); dispatcher.Run();
        Assert.False(vm.IsLoading); Assert.Equal(usage, vm.Usage);
        pendingChange = ChangedAfter(store, s => s.IsPending(EngineCommandName.ModelsInspect)); vm.InspectModels.Execute(null); request = await engine.NextRequestAsync(); await ChangedTo(store, s => s.IsPending(EngineCommandName.ModelsInspect)); await pendingChange;
        await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(100)); dispatcher.Run(); Assert.True(vm.IsInspectingModels);
        var modelFailure = Failure(EngineErrorCode.InvalidSettings, "invalid model metadata", EngineRecoveryAction.Retry);
        request.Complete(new EngineResult.ModelsInspect(new EngineModelsInspection(new EngineClauseTaggerInspection.Invalid(modelFailure))));
        await vm.InspectModels.Execution!; await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(100)); dispatcher.Run();
        Assert.False(vm.IsInspectingModels); Assert.Equal(modelFailure, Assert.IsType<EngineClauseTaggerInspection.Invalid>(vm.ModelsInspection!.ClauseTagger).Error);
        pendingChange = ChangedAfter(store, s => s.IsPending(EngineCommandName.DiagnosticsGet)); vm.Refresh.Execute(null); request = await engine.NextRequestAsync(); await ChangedTo(store, s => s.IsPending(EngineCommandName.DiagnosticsGet)); await pendingChange;
        await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(100)); dispatcher.Run(); Assert.True(vm.IsLoading); Assert.Equal(usage, vm.Usage);
        request.Reject(Failure(EngineErrorCode.Busy, "busy", EngineRecoveryAction.Retry)); await vm.Refresh.Execution!;
    }
    [Fact]
    public async Task LiveRowsProjectAndReconcileInsideDispatcher()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock); var live = new LiveViewModel(context);
        var sawSnapshotBeforeRows = false;
        live.PropertyChanged += (_, _) =>
        {
            Assert.True(dispatcher.IsRunningCallback);
            var emptyInSnapshot = live.Transcript.Tail is not { Rows.Length: > 0 };
            Assert.Equal(emptyInSnapshot, live.IsEmpty);
            if (!emptyInSnapshot && !sawSnapshotBeforeRows) { Assert.Empty(live.Rows); sawSnapshotBeforeRows = true; }
        };
        ((INotifyCollectionChanged)live.Rows).CollectionChanged += (_, change) =>
        {
            Assert.True(dispatcher.IsRunningCallback); Assert.NotEqual(NotifyCollectionChangedAction.Reset, change.Action);
            Assert.InRange(live.Rows.Count, 0, 200);
        };
        EngineTranscriptRow TranscriptRow(string id, long start, string text, EngineSpeakerLabel[] headings, EngineClauseState? clause = null) =>
            new(id, start, start, text, headings, clause);
        var a = TranscriptRow("a", 65_000, "こんにちは🌸\n次の行", [EngineSpeakerLabel.Speaker1], EngineClauseState.AwaitingNextSegment);
        var b = TranscriptRow("b", 125_000, "続き😊\n二行目", [EngineSpeakerLabel.Speaker1]);
        var c = TranscriptRow("c", 190_000, "空の見出し", []);
        var d = TranscriptRow("d", 605_000, "OTHER", [EngineSpeakerLabel.Other]);
        await store.SelectSessionAsync("session"); var watch = await engine.NextRequestAsync();
        watch.Complete(new EngineResult.TranscriptWatch(new EngineTranscriptPage("session", new EngineID(1), [a, b, c, d], null, null)));
        await ChangedTo(store, state => state.Transcript.Tail?.Revision == new EngineID(1));
        Assert.Empty(live.Rows); dispatcher.Run(); Assert.True(sawSnapshotBeforeRows); Assert.False(live.IsEmpty);
        Assert.Equal(new[]
        {
            new ShellTranscriptRowViewModel("a", a.Text, "01:05", "Speaker 1", "発話文の続き待ち"),
            new ShellTranscriptRowViewModel("b", b.Text, "02:05", "", ""),
            new ShellTranscriptRowViewModel("c", c.Text, "03:10", "", ""),
            new ShellTranscriptRowViewModel("d", d.Text, "10:05", "OTHER", "")
        }, live.Rows);
        var stable = live.Rows[0]; var oldD = live.Rows[3];
        var progress = new EngineProgressPayload(EngineStage.ValidatingModels, 1, 2, null);
        engine.EmitBatch(Rows("session", EngineRowsKind.Changes), new EngineOutput(1, new EngineID(2), null, new EngineEvent.Progress(progress)));
        await ChangedTo(store, state => state.Progress == progress);
        await clock.WaitForTimerAsync(); await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(250));
        watch = await engine.NextRequestAsync();
        var changedD = TranscriptRow("d", 610_000, "OTHER updated", [EngineSpeakerLabel.Other]);
        var added = TranscriptRow("e", 2_000, "追加", []);
        watch.Complete(new EngineResult.TranscriptWatch(new EngineTranscriptPage("session", new EngineID(2), [changedD, a, added], null, null)));
        await ChangedTo(store, state => state.Transcript.Tail?.Revision == new EngineID(2)); dispatcher.Run();
        Assert.Equal(new[]
        {
            new ShellTranscriptRowViewModel("d", "OTHER updated", "10:10", "OTHER", ""),
            new ShellTranscriptRowViewModel("a", a.Text, "01:05", "Speaker 1", "発話文の続き待ち"),
            new ShellTranscriptRowViewModel("e", "追加", "00:02", "", "")
        }, live.Rows);
        Assert.Same(stable, live.Rows[1]); Assert.NotSame(oldD, live.Rows[0]);
        async Task RenderScreen(EngineScreen screen, ulong revision, string expected)
        {
            engine.EmitBatch(new EngineOutput(1, new EngineID(revision), null,
                new EngineEvent.State(State(EngineSetupStatus.Ready, revision) with { Screen = screen })));
            await ChangedTo(store, state => state.Engine?.Revision == new EngineID(revision));
            await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(100)); dispatcher.Run(); Assert.Equal(expected, live.BadgeText);
        }
        await RenderScreen(EngineScreen.Live, 2, "ライブ（暫定）");
        await RenderScreen(EngineScreen.Finalizing, 3, "確定処理中");
        await RenderScreen(EngineScreen.Finalized, 4, "確定済み");
        var failure = new EngineClientFailure("process exited", 7, Failure(EngineErrorCode.DeviceFailure, "final engine error", EngineRecoveryAction.Retry),
            new StderrSnapshot(System.Text.Encoding.UTF8.GetBytes("stderr details"), 0));
        engine.SignalFailure(failure); engine.CompleteFailure(failure);
        await ChangedTo(store, state => state.EngineFailure is { ExitCode: 7 });
        await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(100)); dispatcher.Run();
        Assert.Contains("process exited", live.FailureText); Assert.Contains("終了コード: 7", live.FailureText);
        Assert.Contains("標準エラー出力: stderr details", live.FailureText); Assert.Equal("a", live.Rows[1].RowID); Assert.False(live.IsEmpty);
    }
    private static async Task<ShellState> ChangedAfter(ShellStore store, Func<ShellState, bool> predicate)
    {
        var done = new TaskCompletionSource<ShellState>(TaskCreationOptions.RunContinuationsAsynchronously); EventHandler handler = null!;
        handler = (_, _) => { var state = store.State; if (predicate(state)) { store.Changed -= handler; done.TrySetResult(state); } };
        store.Changed += handler;
        try { return await done.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken); } finally { store.Changed -= handler; }
    }
    private sealed class TestDispatcher : IUiDispatcher
    {
        private readonly object _gate = new(); private readonly Queue<Action> _queue = new(); private int _running, _maximumPending, _enqueueCount, _renderCount;
        public bool Reject { get; set; } public bool IsRunningCallback => Volatile.Read(ref _running) != 0;
        public int PendingCount { get { lock (_gate) return _queue.Count; } }
        public int MaximumPending { get { lock (_gate) return _maximumPending; } }
        public int EnqueueCount { get { lock (_gate) return _enqueueCount; } } public int RenderCount { get { lock (_gate) return _renderCount; } }
        public bool TryEnqueue(Action callback)
        {
            lock (_gate) { _enqueueCount++; if (Reject) return false; _queue.Enqueue(callback); _maximumPending = Math.Max(_maximumPending, _queue.Count); return true; }
        }
        public void Run()
        {
            Action callback; lock (_gate) { if (!_queue.TryDequeue(out var queued)) throw new InvalidOperationException("No dispatcher callback is queued."); callback = queued; }
            Interlocked.Exchange(ref _running, 1); try { callback(); } finally { Interlocked.Exchange(ref _running, 0); lock (_gate) _renderCount++; }
        }
    }
    private sealed class TestFolderRevealer : IFolderRevealer
    {
        public string? RequestedPath { get; private set; }
        public Exception? Failure { get; set; }
        public Task RevealAsync(string path)
        {
            RequestedPath = path;
            return Failure is null ? Task.CompletedTask : Task.FromException(Failure);
        }
    }
}
