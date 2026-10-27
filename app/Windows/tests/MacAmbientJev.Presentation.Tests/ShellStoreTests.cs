using System.Threading.Channels;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Presentation.Tests;

public sealed partial class ShellStoreTests
{
    [Theory]
    [InlineData(EngineSetupStatus.SettingsRequired, EngineErrorCode.SettingsRequired, ShellSettingsStatus.Required)]
    [InlineData(EngineSetupStatus.SettingsRequired, EngineErrorCode.InvalidSettings, ShellSettingsStatus.Corrupt)]
    [InlineData(EngineSetupStatus.Ready, null, ShellSettingsStatus.Available)]
    [InlineData(EngineSetupStatus.ModelsRequired, null, ShellSettingsStatus.Available)]
    public async Task InitializationReducesSetupAndSettings(EngineSetupStatus setup, EngineErrorCode? failure, ShellSettingsStatus status)
    {
        var settings = Settings(2, false, false, false, null);
        var response = failure is null ? Response(SettingsResult(4, settings)) : Task.FromException<EngineResult>(new EngineRequestException(Failure(failure.Value, "settings response", EngineRecoveryAction.Retry)));
        await using var store = await Start(new Fake(State(setup, 3), response));
        Assert.Equal(setup, store.State.Engine!.Setup);
        Assert.Equal(new EngineID(3), store.State.Engine.Revision);
        Assert.Equal(status, store.State.SettingsStatus);
        if (failure is null)
        {
            Assert.Equal(SettingsResult(4, settings), store.State.ConfirmedSettings);
            Assert.Equal(settings, store.State.SettingsDraft);
        }
        else
        {
            Assert.Null(store.State.ConfirmedSettings);
            Assert.Null(store.State.SettingsDraft);
            Assert.Equal(failure, store.State.LastError!.Code);
        }
    }

    [Fact]
    public async Task CommitSendsWholeDraftAndPreservesEditsMadeInFlight()
    {
        var old = Settings(2, false, false, false, null); var draft = Settings(3, true, true, false, "/draft");
        var newer = Settings(4, false, true, true, "/newer"); var returned = Settings(1, true, false, true, "/committed");
        var engine = new Fake(State(EngineSetupStatus.Ready, 2), Response(SettingsResult(7, old)));
        await using var store = await Start(engine);
        await store.SetSettingsDraftAsync(draft);
        var commit = store.CommitSettingsAsync(); var request = await engine.NextRequestAsync();
        await ChangedTo(store, state => state.IsPending(EngineCommandName.SettingsReplace));
        var payload = Assert.IsType<EngineCommand.SettingsReplace>(request.Command).Payload;
        Assert.Equal(new EngineID(7), payload.ExpectedRevision); Assert.Equal(draft, payload.Settings);
        Assert.True(store.State.IsPending(EngineCommandName.SettingsReplace)); Assert.Equal(SettingsResult(7, old), store.State.ConfirmedSettings);
        var sent = engine.SentCount; Assert.False(await store.ReloadSettingsAsync()); Assert.Equal(sent, engine.SentCount);
        await store.SetSettingsDraftAsync(newer);
        request.Complete(new EngineResult.SettingsReplace(SettingsResult(11, returned)));
        Assert.True(await commit); Assert.Equal(SettingsResult(11, returned), store.State.ConfirmedSettings);
        Assert.Equal(newer, store.State.SettingsDraft); Assert.False(store.State.IsPending(EngineCommandName.SettingsReplace));
    }

    [Fact]
    public async Task ConflictKeepsEditsUntilExplicitReload()
    {
        var old = Settings(2, false, false, false, null); var draft = Settings(3, true, true, false, "/draft");
        var authoritative = Settings(1, false, true, true, "/engine");
        var engine = new Fake(State(EngineSetupStatus.Ready, 2), Response(SettingsResult(7, old)));
        await using var store = await Start(engine);
        await store.SetSettingsDraftAsync(draft);
        var commit = store.CommitSettingsAsync(); var request = await engine.NextRequestAsync();
        request.Reject(Failure(EngineErrorCode.StaleRevision, "revision moved", EngineRecoveryAction.Retry));
        Assert.False(await commit); Assert.Equal(SettingsResult(7, old), store.State.ConfirmedSettings);
        Assert.Equal(draft, store.State.SettingsDraft); Assert.True(store.State.SettingsConflict);
        Assert.Equal(EngineErrorCode.StaleRevision, store.State.LastError!.Code);
        engine.SettingsGetResponse = Response(SettingsResult(9, authoritative));
        Assert.True(await store.ReloadSettingsAsync());
        Assert.Equal(SettingsResult(9, authoritative), store.State.ConfirmedSettings);
        Assert.Equal(authoritative, store.State.SettingsDraft); Assert.False(store.State.SettingsConflict);
    }

    [Fact]
    public async Task DuplicateRecordingActivationIsGuardedUntilEngineRejectionCompletes()
    {
        var engine = new Fake(State(EngineSetupStatus.Ready, 2), Response(SettingsResult(7, Settings(2, false, false, false, null))));
        await using var store = await Start(engine);
        var command = new EngineCommand.RecordingStart(new EngineRecordingStartPayload(EngineSource.Microphone, new EngineDevice.Default()));
        var first = store.ExecuteAsync(command); var request = await engine.NextRequestAsync();
        Assert.Equal(EngineCommandName.RecordingStart, request.Command.Name);
        Assert.False(await store.ExecuteAsync(command)); Assert.Equal(2, engine.SentCount);
        request.Reject(Failure(EngineErrorCode.Busy, "busy", EngineRecoveryAction.Retry));
        Assert.False(await first); Assert.Equal(ShellPhase.Running, store.State.Phase);
        Assert.False(store.State.IsPending(EngineCommandName.RecordingStart)); Assert.Equal(EngineErrorCode.Busy, store.State.LastError!.Code);
        var retry = store.ExecuteAsync(command); var retryRequest = await engine.NextRequestAsync();
        retryRequest.Complete(new EngineResult.RecordingStart(new EngineSessionPayload("session-1")));
        Assert.True(await retry); Assert.Equal(ShellPhase.Running, store.State.Phase);
    }

    [Fact]
    public async Task RecordingStartSelectsReturnedSessionAndRefreshesItsTail()
    {
        var engine = new Fake(State(EngineSetupStatus.Ready, 2), Response(SettingsResult(7, Settings(2, false, false, false, null))));
        var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await store.SelectSessionAsync("old-session");
        var oldWatch = await engine.NextRequestAsync();
        oldWatch.Complete(new EngineResult.TranscriptWatch(Page("old-session", 1, "old-tail", null, null)));
        await ChangedTo(store, s => s.Transcript.Tail?.Revision == new EngineID(1));
        var history = store.ReadHistoryAsync(ShellPageMove.Reload); var historyRequest = await engine.NextRequestAsync();
        historyRequest.Complete(new EngineResult.TranscriptRead(Page("old-session", 2, "old-history", null, null)));
        Assert.True(await history);
        Assert.Equal("old-tail", store.State.Transcript.Tail!.Rows[0].Text);
        Assert.Equal("old-history", store.State.Transcript.History.Current!.Rows[0].Text);

        clock.Advance(TimeSpan.FromMilliseconds(250));
        var start = store.ExecuteAsync(new EngineCommand.RecordingStart(new EngineRecordingStartPayload(EngineSource.Microphone, new EngineDevice.Default())));
        var startRequest = await engine.NextRequestAsync();
        startRequest.Complete(new EngineResult.RecordingStart(new EngineSessionPayload("new-session")));
        Assert.True(await start);
        var switched = await ChangedTo(store, s => s.Transcript.SessionID == "new-session" && s.Transcript.Tail is null && s.Transcript.History.Pages.IsEmpty);
        Assert.Null(switched.Transcript.Tail);
        Assert.Empty(switched.Transcript.History.Pages);

        var newWatch = await engine.NextRequestAsync();
        Assert.Equal("new-session", Assert.IsType<EngineCommand.TranscriptWatch>(newWatch.Command).Payload.SessionID);
        newWatch.Complete(new EngineResult.TranscriptWatch(Page("new-session", 3, "new-tail", null, null)));
        var refreshed = await ChangedTo(store, s => s.Transcript.Tail?.Revision == new EngineID(3));
        Assert.Equal("new-session", refreshed.Transcript.Tail!.SessionID);
        Assert.Equal("new-tail", refreshed.Transcript.Tail.Rows[0].Text);
    }

    [Fact]
    public async Task ClientFailurePublishesEarlyThenFinalSnapshotWithoutLosingShellData()
    {
        var engine = new Fake(State(EngineSetupStatus.Ready, 5), Response(SettingsResult(7, Settings(2, false, false, false, null))));
        await using var store = await Start(engine);
        var priorEngine = store.State.Engine; var priorSettings = store.State.ConfirmedSettings;
        engine.SignalFailure(new EngineClientFailure("process exited", null, Failure(EngineErrorCode.DeviceFailure, "デバイス障害", EngineRecoveryAction.Retry), new StderrSnapshot(new byte[] { 1, 2 }, 0)));
        var early = await ChangedTo(store, s => s.EngineFailure is { ExitCode: null });
        Assert.Equal(ShellPhase.EngineFailed, early.Phase);
        Assert.Equal(new byte[] { 1, 2 }, early.EngineFailure!.Stderr.Bytes);
        var bytes = new byte[] { 9, 8, 7 };
        engine.CompleteFailure(new EngineClientFailure("process exited", 7, Failure(EngineErrorCode.DeviceFailure, "最終エラー", EngineRecoveryAction.Retry), new StderrSnapshot(bytes, 13)));
        var final = await ChangedTo(store, s => s.EngineFailure is { ExitCode: 7 });
        Assert.Equal(7, final.EngineFailure!.ExitCode); Assert.Equal(new byte[] { 9, 8, 7 }, final.EngineFailure.Stderr.Bytes);
        Assert.Equal(13, final.EngineFailure.Stderr.DiscardedBytes); Assert.Equal(EngineErrorCode.DeviceFailure, final.EngineFailure.LastEngineError!.Code);
        Assert.Equal("最終エラー", final.EngineFailure.LastEngineError.Message);
        Assert.Equal(priorEngine, final.Engine); Assert.Equal(priorSettings, final.ConfirmedSettings);
        var sent = engine.SentCount;
        Assert.False(await store.ExecuteAsync(new EngineCommand.StateGet(new EngineEmptyPayload()))); Assert.Equal(sent, engine.SentCount);
    }

    [Fact]
    public async Task EventBatchAndRevisionsPublishOneSnapshotAndIgnoreOlderState()
    {
        var engine = new Fake(State(EngineSetupStatus.Ready, 1), Response(SettingsResult(1, Settings(2, false, false, false, null))));
        await using var store = await Start(engine);
        var changes = 0; store.Changed += (_, _) => Interlocked.Increment(ref changes);
        var notices = new[] { "録音エラー" };
        var incoming = State(EngineSetupStatus.Ready, 5) with { Presentation = new EnginePresentationState("録音中", EngineRecordingTone.Neutral, EnginePreparationPhase.Preparing, "モデル準備中", null, null, notices, false, null, 0, null, EngineProcessingIndicator.Idle) };
        var progress = new EngineProgressPayload(EngineStage.ValidatingModels, 100, 100, null);
        var publishedChanged = ChangedAfter(store, s => s.Engine?.Revision == new EngineID(5) && s.Progress == progress);
        engine.EmitBatch(new EngineOutput(1, new EngineID(1), null, new EngineEvent.State(incoming)), new EngineOutput(1, new EngineID(2), null, new EngineEvent.Progress(progress)));
        var published = await publishedChanged;
        Assert.Equal(1, Volatile.Read(ref changes)); Assert.Equal("録音中", published.Engine!.Presentation.RecordingStatusText);
        Assert.Equal(EnginePreparationPhase.Preparing, published.Engine.Presentation.PreparationPhase);
        Assert.Equal(new[] { "録音エラー" }, published.Engine.Presentation.LiveFailureNotices);
        var older = store.ExecuteAsync(new EngineCommand.StateGet(new EngineEmptyPayload())); var request = await engine.NextRequestAsync();
        request.Complete(new EngineResult.StateGet(State(EngineSetupStatus.Ready, 3)));
        Assert.True(await older); Assert.Equal(new EngineID(5), store.State.Engine!.Revision);
        Assert.Equal(EnginePreparationPhase.Preparing, store.State.Engine.Presentation.PreparationPhase);
    }

    [Fact]
    public async Task UnexpectedResultFailsStoreAndClearsPendingRequest()
    {
        var engine = new Fake(State(EngineSetupStatus.Ready, 1), Response(SettingsResult(1, Settings(2, false, false, false, null))));
        await using var store = await Start(engine);
        var execution = store.ExecuteAsync(new EngineCommand.ModelsPrepare(new EngineEmptyPayload())); var request = await engine.NextRequestAsync();
        request.Complete(new EngineResult.RecordingStart(new EngineSessionPayload("wrong")));
        Assert.False(await execution); Assert.Equal(ShellPhase.EngineFailed, store.State.Phase);
        Assert.NotNull(store.State.StoreFailure); Assert.False(store.State.IsPending(EngineCommandName.ModelsPrepare));
    }

    [Fact]
    public async Task CorruptSettingsCanBeRepairedWithoutExpectedRevision()
    {
        var old = Settings(2, false, false, false, null); var draft = Settings(3, true, true, true, "/repaired");
        var engine = new Fake(State(EngineSetupStatus.Ready, 1), Response(SettingsResult(7, old)));
        await using var store = await Start(engine);
        engine.SettingsGetResponse = Task.FromException<EngineResult>(new EngineRequestException(Failure(EngineErrorCode.InvalidSettings, "corrupt", EngineRecoveryAction.ReplaceSettings)));
        Assert.False(await store.ReloadSettingsAsync()); Assert.Equal(ShellSettingsStatus.Corrupt, store.State.SettingsStatus);
        Assert.Equal(SettingsResult(7, old), store.State.ConfirmedSettings);
        await store.SetSettingsDraftAsync(draft);
        var commit = store.CommitSettingsAsync(); var request = await engine.NextRequestAsync();
        var payload = Assert.IsType<EngineCommand.SettingsReplace>(request.Command).Payload;
        Assert.Null(payload.ExpectedRevision); Assert.Equal(draft, payload.Settings);
        request.Complete(new EngineResult.SettingsReplace(SettingsResult(1, draft)));
        Assert.True(await commit); Assert.Equal(SettingsResult(1, draft), store.State.ConfirmedSettings);
        Assert.Equal(draft, store.State.SettingsDraft); Assert.Equal(ShellSettingsStatus.Available, store.State.SettingsStatus);
    }

    private static async Task<ShellStore> Start(Fake engine) { var store = new ShellStore(engine); await store.Initialization.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken); return store; }
    private static async Task<ShellState> ChangedTo(ShellStore store, Func<ShellState, bool> predicate)
    {
        if (predicate(store.State)) return store.State;
        var result = new TaskCompletionSource<ShellState>(TaskCreationOptions.RunContinuationsAsynchronously);
        EventHandler handler = (_, _) => { var state = store.State; if (predicate(state)) result.TrySetResult(state); };
        store.Changed += handler;
        try { if (predicate(store.State)) result.TrySetResult(store.State); return await result.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken); }
        finally { store.Changed -= handler; }
    }
    private static EngineSettings Settings(long threads, bool lowHeat, bool decisions, bool export, string? path) => new(1, EngineSource.Microphone, new EngineDevice.Default(), EngineASRSize.Small, EngineExecutionProvider.Cpu, threads, lowHeat, decisions, export, path);
    private static EngineSettingsResult SettingsResult(ulong revision, EngineSettings settings) => new(new EngineID(revision), settings);
    private static Task<EngineResult> Response(EngineSettingsResult result) => Task.FromResult<EngineResult>(new EngineResult.SettingsGet(result));
    private static EngineFailure Failure(EngineErrorCode code, string message, EngineRecoveryAction action) => new(code, message, EngineStage.Settings, null, null, EngineSeverity.Error, action, [], []);
    private static EngineState State(EngineSetupStatus setup, ulong revision) => new(new EngineID(revision), EngineScreen.Idle, setup, EngineRecoveryStatus.Completed, null, [], [], new EnginePresentationState("Idle", EngineRecordingTone.Neutral, EnginePreparationPhase.Idle, null, null, null, [], false, null, 0, null, EngineProcessingIndicator.Idle));

    private sealed class Fake(EngineState initial, Task<EngineResult> settingsGet) : IEngineClient
    {
        private readonly Channel<(EngineCommand Command, TaskCompletionSource<EngineResult> Result)> _requests = Channel.CreateUnbounded<(EngineCommand, TaskCompletionSource<EngineResult>)>();
        private readonly Channel<bool> _wake = Channel.CreateUnbounded<bool>();
        private readonly object _gate = new(); private readonly List<EngineOutput> _events = [];
        private readonly TaskCompletionSource<EngineClientState> _completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _sentCount;
        public Task<EngineResult> Hello { get; } = Task.FromResult<EngineResult>(new EngineResult.Hello(new EngineReadyPayload(new EngineCapabilities([EngineSource.Microphone], [EngineASRSize.Small], [EngineExecutionProvider.Cpu], 4, EngineUnavailableCapability.None, EngineUnavailableCapability.None), initial)));
        public Task<EngineResult> SettingsGetResponse { get; set; } = settingsGet;
        public Func<EngineCommand, EngineResult>? AutoResponse { get; set; }
        public int SentCount => Volatile.Read(ref _sentCount); public Task<EngineClientState> Completion => _completion.Task;
        public EngineClientState State { get; private set; } = EngineClientState.Running; public EngineClientFailure? Failure { get; private set; }
        public Task<EngineResult> SendAsync(EngineCommand command)
        {
            Interlocked.Increment(ref _sentCount);
            if (command is EngineCommand.SettingsGet) return SettingsGetResponse;
            if (AutoResponse is not null) return Task.FromResult(AutoResponse(command));
            if (command is not (EngineCommand.StateGet or EngineCommand.SettingsReplace or EngineCommand.RecordingStart or EngineCommand.RecordingStop or EngineCommand.ModelsPrepare or EngineCommand.ModelsInspect or EngineCommand.DiagnosticsGet or EngineCommand.TranscriptWatch or EngineCommand.TranscriptRead or EngineCommand.SessionList)) throw new NotSupportedException($"Unexpected command: {command.Name}.");
            var result = new TaskCompletionSource<EngineResult>(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!_requests.Writer.TryWrite((command, result))) throw new InvalidOperationException("Request channel closed.");
            return result.Task;
        }
        public async Task<Request> NextRequestAsync()
        {
            var item = await _requests.Reader.ReadAsync(TestContext.Current.CancellationToken).AsTask().WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
            return new Request(item.Command, item.Result);
        }
        public IReadOnlyList<EngineOutput> DrainEvents() { lock (_gate) { var events = _events.ToArray(); _events.Clear(); while (_wake.Reader.TryRead(out _)) { } return events; } }
        public async Task WaitForEventsAsync(CancellationToken token) => await _wake.Reader.ReadAsync(token);
        public void EmitBatch(params EngineOutput[] events) { lock (_gate) { _events.AddRange(events); if (!_wake.Writer.TryWrite(true)) throw new InvalidOperationException("Event channel closed."); } }
        public void SignalFailure(EngineClientFailure failure) { lock (_gate) { Failure = failure; State = EngineClientState.Failed; if (!_wake.Writer.TryWrite(true)) throw new InvalidOperationException("Event channel closed."); } }
        public void CompleteFailure(EngineClientFailure failure) { Failure = failure; _completion.TrySetResult(EngineClientState.Failed); }
    }

    private sealed record Request(EngineCommand Command, TaskCompletionSource<EngineResult> Result)
    {
        public void Complete(EngineResult result) => Result.TrySetResult(result);
        public void Reject(EngineFailure failure) => Result.TrySetException(new EngineRequestException(failure));
    }
}
