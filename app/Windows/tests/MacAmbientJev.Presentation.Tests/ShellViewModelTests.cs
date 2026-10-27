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
        Assert.True(live.StartRecording.CanExecute(payload)); live.StartRecording.Execute(payload); live.StartRecording.Execute(payload);
        Assert.False(live.StartRecording.CanExecute(payload)); var execution = live.StartRecording.Execution!; var request = await engine.NextRequestAsync();
        await ChangedTo(store, s => s.IsPending(EngineCommandName.RecordingStart));
        Assert.False(live.StartRecording.CanExecute(payload)); Assert.Equal(2, engine.SentCount);
        request.Reject(Failure(EngineErrorCode.Busy, "busy", EngineRecoveryAction.Retry)); await execution;
        var direct = store.ExecuteAsync(new EngineCommand.RecordingStart(payload)); request = await engine.NextRequestAsync();
        await ChangedTo(store, s => s.IsPending(EngineCommandName.RecordingStart)); Assert.False(live.StartRecording.CanExecute(payload));
        request.Reject(Failure(EngineErrorCode.Busy, "busy", EngineRecoveryAction.Retry)); Assert.False(await direct);
        var revision = 1UL;
        foreach (var phase in Enum.GetValues<EngineRecordingPhase>())
        {
            var state = State(EngineSetupStatus.Ready, ++revision) with { Recording = new EngineRecordingState("session", EngineSource.Microphone, new EngineDevice.Default(), phase) };
            engine.EmitBatch(new EngineOutput(1, new EngineID(revision), null, new EngineEvent.State(state)));
            await ChangedTo(store, s => s.Engine?.Revision == new EngineID(revision));
            Assert.False(live.StartRecording.CanExecute(payload));
            Assert.Equal(phase is EngineRecordingPhase.Recording or EngineRecordingPhase.WaitingForDevice, live.StopRecording.CanExecute(null));
        }
        var failed = new EngineClientFailure("exited", 1, Failure(EngineErrorCode.DeviceFailure, "failed", EngineRecoveryAction.Retry), new StderrSnapshot([], 0));
        engine.SignalFailure(failed); engine.CompleteFailure(failed); await ChangedTo(store, s => s.Phase == ShellPhase.EngineFailed);
        Assert.False(live.StartRecording.CanExecute(payload)); Assert.False(diagnostics.Refresh.CanExecute(null));
    }
    [Fact]
    public async Task OneDispatcherRefreshPerBatch()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var live = new LiveViewModel(context); var queue = new ProcessingQueueViewModel(context); var sessions = new SessionsViewModel(context);
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
}
