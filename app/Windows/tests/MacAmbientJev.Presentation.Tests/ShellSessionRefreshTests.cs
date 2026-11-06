using System.Reflection;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Presentation.Tests;

public sealed partial class ShellStoreTests
{
    [Fact]
    public async Task OpeningSavedListReloadsOnlyListAndPreservesSelectionAndLiveTranscript()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var inspect = store.InspectSessionAsync("saved-folder"); var inspectionRequest = await engine.NextRequestAsync();
        var inspection = Readable("saved-folder", "saved-session", false, false, "saved inspection");
        inspectionRequest.Complete(new EngineResult.SessionInspect(inspection)); Assert.True(await inspect);
        await SelectReady(store, engine, "live-session", Page("live-session", 1, "live-tail", null, null));
        var transcript = store.State.Transcript;
        var timers = 0; clock.TimerScheduled += () => Interlocked.Increment(ref timers);

        await store.SetSessionsVisibleAsync(true);
        var refresh = await engine.NextRequestAsync(); AssertReload(refresh);
        refresh.Complete(new EngineResult.SessionList(SessionPage("saved-row", null, null)));
        await SessionsRefreshIdle(store);

        Assert.Equal("saved-row", store.State.Sessions.Current!.Sessions[0].FolderID);
        Assert.Equal("saved-folder", store.State.SelectedFolderID); Assert.Same(inspection, store.State.SessionInspection);
        Assert.Same(transcript, store.State.Transcript);
        var sent = engine.SentCount;
        await store.SetSessionsVisibleAsync(true); await SessionsRefreshIdle(store);
        Assert.Equal(sent, engine.SentCount); Assert.Equal(0, Volatile.Read(ref timers));
    }

    [Fact]
    public async Task SavedListOpenedBeforeHelloRefreshesWhenEngineBecomesRunning()
    {
        var engine = NewEngine(); var client = new DelayedSessionsHello(engine); var clock = new ManualClock();
        await using var store = new ShellStore(client, clock);
        await store.SetSessionsVisibleAsync(true); Assert.Equal(0, engine.SentCount);
        client.HelloCompletion.SetResult(await engine.Hello);
        await store.Initialization.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        var refresh = await engine.NextRequestAsync(); AssertReload(refresh);
        refresh.Complete(new EngineResult.SessionList(SessionPage("opened-during-startup", null, null)));
        await SessionsRefreshIdle(store);
        Assert.Equal("opened-during-startup", store.State.Sessions.Current!.Sessions[0].FolderID);
    }

    [Fact]
    public async Task StructuralStateChangesRefreshOpenListIncludingQueueProcessingAndRecovery()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await OpenAndCompleteSessions(store, engine);
        var transitions = new Func<EngineState, EngineState>[]
        {
            state => state with { Recording = new EngineRecordingState("live", EngineSource.Microphone, new EngineDevice.Default(), EngineRecordingPhase.Recording) },
            state => state with { Recording = state.Recording! with { Phase = EngineRecordingPhase.Stopping } },
            state => state with { Recording = null },
            state => state with { Queue = [new EngineQueuedOperation("imported", EngineStage.Import)] },
            state => state with { Queue = [new EngineQueuedOperation("imported", EngineStage.Asr)] },
            state => state with { Queue = [] },
            state => state with { Failures = [Failure(EngineErrorCode.ProcessingFailure, "failed processing", EngineRecoveryAction.Reprocess)] },
            state => state with { Failures = [] },
            state => state with { Recovery = EngineRecoveryStatus.Running },
            state => state with { Recovery = EngineRecoveryStatus.Completed }
        };
        var next = store.State.Engine!;
        foreach (var transition in transitions)
        {
            next = transition(next) with { Revision = new EngineID(next.Revision.Value + 1) };
            EmitSessionState(engine, next);
            var refresh = await engine.NextRequestAsync(); AssertReload(refresh);
            refresh.Complete(new EngineResult.SessionList(SessionPage($"revision-{next.Revision.Value}", null, null)));
            await SessionsRefreshIdle(store);
            Assert.Equal($"revision-{next.Revision.Value}", store.State.Sessions.Current!.Sessions[0].FolderID);
        }
        Assert.Null(store.State.SelectedFolderID); Assert.Null(store.State.Transcript.SessionID);
    }

    [Fact]
    public async Task ScreenPresentationAndEquivalentArraySnapshotsDoNotInvalidateSavedList()
    {
        var initial = State(EngineSetupStatus.Ready, 1) with
        {
            Queue = [new EngineQueuedOperation("queued", EngineStage.Asr)],
            Failures = [Failure(EngineErrorCode.ProcessingFailure, "retained failure", EngineRecoveryAction.Reprocess) with
            {
                Details = [new EngineErrorDetail("engine", "processing", "retained detail", null, null)],
                CleanupErrors = [new EngineErrorDetail("filesystem", "cleanup", "retained cleanup", null, null)]
            }]
        };
        var engine = new Fake(initial, Response(SettingsResult(1, Settings(2, false, false, false, null))));
        var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await OpenAndCompleteSessions(store, engine);
        var sent = engine.SentCount;
        var unchanged = initial with
        {
            Revision = new EngineID(2), Screen = EngineScreen.Finalized,
            Queue = initial.Queue.Select(item => item with { }).ToArray(),
            Failures = initial.Failures.Select(item => item with
            {
                Details = item.Details.Select(detail => detail with { }).ToArray(),
                CleanupErrors = item.CleanupErrors.Select(detail => detail with { }).ToArray()
            }).ToArray(),
            Presentation = initial.Presentation with { ProcessingStatusText = "presentation-only update" }
        };
        engine.EmitBatch(new EngineOutput(1, new EngineID(2), null, new EngineEvent.State(unchanged)),
            Rows("unselected", EngineRowsKind.ReloadRequired),
            new EngineOutput(1, new EngineID(3), null, new EngineEvent.Progress(new EngineProgressPayload(EngineStage.Asr, 1, 2, "queued"))));
        await ChangedTo(store, state => state.Engine?.Revision == new EngineID(2) && state.Progress is not null);
        await SessionsRefreshIdle(store);
        Assert.Equal(sent, engine.SentCount);
    }

    [Fact]
    public async Task InvalidationsWaitForManualListAndCoalesceWithOneFollowupPerInflightRequest()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var manual = store.ListSessionsAsync(ShellPageMove.Reload); var manualRequest = await engine.NextRequestAsync();
        await store.SetSessionsVisibleAsync(true);
        EmitQueuedSessionChanges(engine, 2, 21);
        await ChangedTo(store, state => state.Engine?.Revision == new EngineID(21));
        Assert.Equal(2, engine.SentCount); Assert.Null(store.State.CommandError);
        manualRequest.Complete(new EngineResult.SessionList(SessionPage("manual", null, null))); Assert.True(await manual);

        var refresh = await engine.NextRequestAsync(); AssertReload(refresh);
        EmitQueuedSessionChanges(engine, 22, 41);
        await ChangedTo(store, state => state.Engine?.Revision == new EngineID(41));
        Assert.Equal(3, engine.SentCount); Assert.Null(store.State.CommandError);
        refresh.Complete(new EngineResult.SessionList(SessionPage("first-refresh", null, null)));
        var followup = await engine.NextRequestAsync(); AssertReload(followup);
        followup.Complete(new EngineResult.SessionList(SessionPage("coalesced", null, null)));
        await SessionsRefreshIdle(store);
        Assert.Equal(4, engine.SentCount); Assert.Single(store.State.Sessions.Pages);
        Assert.Equal("coalesced", store.State.Sessions.Current!.Sessions[0].FolderID);
    }

    [Fact]
    public async Task ClosingSavedListDropsQueuedRefreshesAndReopeningReloads()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await store.SetSessionsVisibleAsync(true); var refresh = await engine.NextRequestAsync();
        EmitQueuedSessionChanges(engine, 2, 3);
        await ChangedTo(store, state => state.Engine?.Revision == new EngineID(3));
        await store.SetSessionsVisibleAsync(false);
        refresh.Complete(new EngineResult.SessionList(SessionPage("last-open-result", null, null)));
        await SessionsRefreshIdle(store); var sent = engine.SentCount;
        EmitQueuedSessionChanges(engine, 4, 5);
        await ChangedTo(store, state => state.Engine?.Revision == new EngineID(5));
        await SessionsRefreshIdle(store); Assert.Equal(sent, engine.SentCount);
        clock.Advance(TimeSpan.FromDays(1)); Assert.Equal(sent, engine.SentCount);

        await store.SetSessionsVisibleAsync(true); var reopened = await engine.NextRequestAsync(); AssertReload(reopened);
        reopened.Complete(new EngineResult.SessionList(SessionPage("reopened", null, null)));
        await SessionsRefreshIdle(store); Assert.Equal(sent + 1, engine.SentCount);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SuccessfulImportAndStopCompletionRefreshOpenList(bool stop)
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await SelectReady(store, engine, "current-view", Page("current-view", 1, "kept", null, null));
        await OpenAndCompleteSessions(store, engine);
        var transcript = store.State.Transcript;
        var action = stop
            ? store.ExecuteAsync(new EngineCommand.RecordingStop(new EngineSessionPayload("current-view")))
            : store.ImportAudioAsync("/input/audio.wav");
        var request = await engine.NextRequestAsync();
        Assert.Equal(stop ? EngineCommandName.RecordingStop : EngineCommandName.SessionImport, request.Command.Name);
        request.Complete(stop
            ? new EngineResult.RecordingStop(new EngineSessionPayload("completed-session"))
            : new EngineResult.SessionImport(new EngineSessionPayload("completed-session")));
        Assert.True(await action);
        var refresh = await engine.NextRequestAsync(); AssertReload(refresh);
        refresh.Complete(stop
            ? new EngineResult.SessionList(SessionPage("completed-session", null, null))
            : new EngineResult.SessionList(new EngineSessionListResult(
                [Readable("completed-folder", "completed-session", false, false, "処理中") with { DisplayName = "engine import name" }], null, null)));
        await SessionsRefreshIdle(store);
        if (stop) Assert.Same(transcript, store.State.Transcript);
        else { Assert.Equal("completed-session", store.State.Transcript.SessionID); Assert.Null(store.State.Transcript.Tail); }
        Assert.Null(store.State.SelectedFolderID); Assert.Null(store.State.SessionInspection);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FailedAutomaticListSurfacesErrorAndDoesNotRetryWithoutNewInvalidation(bool admissionFailure)
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var timers = 0; clock.TimerScheduled += () => Interlocked.Increment(ref timers);
        if (admissionFailure) engine.AutoResponse = _ => throw new EngineClientOverloadedException("list capacity exhausted");
        await store.SetSessionsVisibleAsync(true);
        if (!admissionFailure)
        {
            var request = await engine.NextRequestAsync();
            request.Reject(Failure(EngineErrorCode.Filesystem, "list failed", EngineRecoveryAction.Retry));
        }
        await ChangedTo(store, state => admissionFailure ? state.CommandError == "list capacity exhausted" : state.LastError?.Message == "list failed");
        await SessionsRefreshIdle(store);
        Assert.Equal(ShellPhase.Running, store.State.Phase); Assert.False(store.State.IsPending(EngineCommandName.SessionList));
        Assert.Equal(2, engine.SentCount); Assert.Equal(0, Volatile.Read(ref timers));
        EmitSessionState(engine, store.State.Engine! with { Revision = new EngineID(2), Screen = EngineScreen.Finalized });
        await ChangedTo(store, state => state.Engine?.Revision == new EngineID(2));
        clock.Advance(TimeSpan.FromDays(1)); await SessionsRefreshIdle(store); Assert.Equal(2, engine.SentCount);

        engine.AutoResponse = null;
        EmitSessionState(engine, store.State.Engine! with { Revision = new EngineID(3), Queue = [new EngineQueuedOperation("new", EngineStage.Asr)] });
        var retry = await engine.NextRequestAsync(); AssertReload(retry);
        retry.Complete(new EngineResult.SessionList(SessionPage("after-new-invalidation", null, null)));
        await SessionsRefreshIdle(store); Assert.Equal(3, engine.SentCount);
    }

    [Fact]
    public async Task DisposingWhileAutomaticListIsPendingStopsWorkerWithoutClosingClient()
    {
        var engine = NewEngine(); var clock = new ManualClock(); var store = await Start(engine, clock);
        await store.SetSessionsVisibleAsync(true); var request = await engine.NextRequestAsync();
        await store.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.Equal(ShellPhase.Disposed, store.State.Phase); Assert.Equal(EngineClientState.Running, engine.State);
        Assert.Empty(store.State.Pending);
        request.Complete(new EngineResult.SessionList(SessionPage("too-late", null, null)));
        Assert.Empty(store.State.Sessions.Pages);
    }

    private sealed class DelayedSessionsHello(Fake inner) : IEngineClient
    {
        public TaskCompletionSource<EngineResult> HelloCompletion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task<EngineResult> Hello => HelloCompletion.Task;
        public Task<EngineResult> SendAsync(EngineCommand command) => inner.SendAsync(command);
        public IReadOnlyList<EngineOutput> DrainEvents() => inner.DrainEvents();
        public Task WaitForEventsAsync(CancellationToken token) => inner.WaitForEventsAsync(token);
        public Task<EngineClientState> Completion => inner.Completion;
        public EngineClientState State => inner.State;
        public EngineClientFailure? Failure => inner.Failure;
    }

    private static void AssertReload(Request request)
    {
        var payload = Assert.IsType<EngineCommand.SessionList>(request.Command).Payload;
        Assert.Null(payload.Cursor); Assert.Equal(100, payload.Limit);
    }

    private static async Task OpenAndCompleteSessions(ShellStore store, Fake engine)
    {
        await store.SetSessionsVisibleAsync(true); var request = await engine.NextRequestAsync(); AssertReload(request);
        request.Complete(new EngineResult.SessionList(SessionPage("initial", null, null)));
        await SessionsRefreshIdle(store);
    }

    private static void EmitSessionState(Fake engine, EngineState state) =>
        engine.EmitBatch(new EngineOutput(1, state.Revision, null, new EngineEvent.State(state)));

    private static void EmitQueuedSessionChanges(Fake engine, ulong first, ulong last) => engine.EmitBatch(
        Enumerable.Range(0, checked((int)(last - first + 1))).Select(index =>
        {
            var revision = first + (ulong)index;
            return new EngineOutput(1, new EngineID(revision), null, new EngineEvent.State(State(EngineSetupStatus.Ready, revision) with
            { Queue = [new EngineQueuedOperation($"session-{revision}", EngineStage.Asr)] }));
        }).ToArray());

    // Only the quiescence barrier uses implementation access: externally observed requests,
    // snapshots and errors are asserted above. Awaiting the actual worker makes no-spin and
    // negative assertions deterministic without sleeps or extra production test APIs.
    private static async Task SessionsRefreshIdle(ShellStore store)
    {
        var field = typeof(ShellStore).GetField("_sessionsRefreshTask", BindingFlags.Instance | BindingFlags.NonPublic)!;
        while (field.GetValue(store) is Task worker)
        {
            await worker.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
            if (ReferenceEquals(worker, field.GetValue(store))) return;
        }
    }
}
