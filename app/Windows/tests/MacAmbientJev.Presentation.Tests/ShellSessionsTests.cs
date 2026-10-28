using System.IO;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Presentation.Tests;

public sealed partial class ShellStoreTests
{
    [Fact]
    public async Task SelectionInspectsFolderIncludingUnreadable()
    {
        var engine = new SessionInspectClient(NewEngine()); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var summary = new EngineSessionSummary("opaque-folder", null, EngineSessionStatus.Unreadable,
            Failure(EngineErrorCode.InvalidSettings, "読み取り不能の理由", EngineRecoveryAction.Retry), "一覧の名前", "一覧の状態",
            "/engine/actual/session", null, false, false, false, new EngineSessionMetadata.Unreadable("一覧の理由"));
        var response = summary with { DisplayName = "engine response name", StatusText = "エンジン検査状態" };
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock); var vm = new SessionsViewModel(context, new TestFolderRevealer());
        var sentBeforeSelection = engine.SentCount;
        Assert.True(vm.Select.CanExecute(summary)); vm.Select.Execute(summary); vm.Select.Execute(summary);
        var request = await engine.NextRequestAsync();
        await ChangedTo(store, state => state.IsPending(EngineCommandName.SessionInspect));
        Assert.False(vm.CanSelectSession); Assert.False(vm.Select.CanExecute(summary));
        Assert.Equal("opaque-folder", Assert.IsType<EngineCommand.SessionInspect>(request.Command).Payload.FolderID);
        Assert.Equal(sentBeforeSelection + 1, engine.SentCount);
        request.Complete(new EngineResult.SessionInspect(response));
        await vm.Select.Execution!; await RenderAsync(dispatcher, clock);
        Assert.Equal("opaque-folder", vm.SelectedFolderID);
        Assert.Same(response, vm.Inspection); Assert.Equal("エンジン検査状態", vm.Inspection!.StatusText);
        Assert.Null(vm.Inspection.SessionID); Assert.Null(store.State.Transcript.SessionID);
        var recording = State(EngineSetupStatus.Ready, 2) with { Recording = new EngineRecordingState("active", EngineSource.Microphone, new EngineDevice.Default(), EngineRecordingPhase.Recording) };
        engine.EmitBatch(new EngineOutput(1, new EngineID(2), null, new EngineEvent.State(recording)));
        await ChangedTo(store, state => state.Engine?.Revision == new EngineID(2)); await RenderAsync(dispatcher, clock);
        Assert.False(vm.CanSelectSession); Assert.False(vm.Select.CanExecute(summary)); var sent = engine.SentCount;
        Assert.False(await store.InspectSessionAsync("opaque-folder")); Assert.Equal(sent, engine.SentCount);
    }

    [Fact]
    public async Task ActionsRequireEnginePermission()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        const string folder = "opaque-readable-folder", session = "engine-session";
        var allowReprocess = false; var allowRetry = false; var status = "初回検査"; var requests = new List<EngineCommand>();
        engine.AutoResponse = command => { requests.Add(command); return command switch
        {
            EngineCommand.SessionInspect inspect => new EngineResult.SessionInspect(Readable(inspect.Payload.FolderID, session, allowReprocess, allowRetry, status)),
            EngineCommand.SessionReprocess action => new EngineResult.SessionReprocess(new EngineSessionPayload(action.Payload.SessionID)),
            EngineCommand.SessionRetryDecisions action => new EngineResult.SessionRetryDecisions(new EngineSessionPayload(action.Payload.SessionID)),
            _ => throw new NotSupportedException($"Unexpected command: {command.Name}.")
        }; };
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock); var vm = new SessionsViewModel(context, new TestFolderRevealer());
        var candidate = Readable(folder, session, false, false, "一覧"); vm.Select.Execute(candidate); await vm.Select.Execution!; await RenderAsync(dispatcher, clock);
        Assert.False(vm.Reprocess.CanExecute(null)); Assert.False(vm.RetryDecisions.CanExecute(null));
        var sent = engine.SentCount; Assert.False(await store.ReprocessSessionAsync()); Assert.False(await store.RetrySessionDecisionsAsync()); Assert.Equal(sent, engine.SentCount);
        var pending = new List<(EngineCommandName Name, bool Select, bool Reprocess, bool Retry)>();
        store.Changed += (_, _) =>
        {
            foreach (var name in new[] { EngineCommandName.SessionReprocess, EngineCommandName.SessionRetryDecisions })
                if (store.State.IsPending(name)) pending.Add((name, vm.Select.CanExecute(candidate), vm.Reprocess.CanExecute(null), vm.RetryDecisions.CanExecute(null)));
        };
        foreach (var retry in new[] { false, true })
        {
            allowReprocess = !retry; allowRetry = retry; status = retry ? "再試行可能" : "再処理可能";
            Assert.True(await store.InspectSessionAsync(folder)); await RenderAsync(dispatcher, clock);
            Assert.Equal(!retry, vm.Reprocess.CanExecute(null)); Assert.Equal(retry, vm.RetryDecisions.CanExecute(null));
            allowReprocess = false; allowRetry = false; status = "操作後の新しい検査";
            var before = requests.Count; var action = retry ? vm.RetryDecisions : vm.Reprocess;
            action.Execute(null); action.Execute(null); await action.Execution!; await RenderAsync(dispatcher, clock);
            Assert.Equal(before + 2, requests.Count);
            if (retry) Assert.Equal(session, Assert.IsType<EngineCommand.SessionRetryDecisions>(requests[before]).Payload.SessionID);
            else Assert.Equal(session, Assert.IsType<EngineCommand.SessionReprocess>(requests[before]).Payload.SessionID);
            Assert.Equal(folder, Assert.IsType<EngineCommand.SessionInspect>(requests[before + 1]).Payload.FolderID);
            Assert.Equal("操作後の新しい検査", vm.Inspection!.StatusText);
            Assert.False(vm.Inspection.CanReprocess); Assert.False(vm.Inspection.CanRetryDecisions);
            var name = retry ? EngineCommandName.SessionRetryDecisions : EngineCommandName.SessionReprocess;
            Assert.Contains(pending, observation => observation.Name == name && !observation.Select && !observation.Reprocess && !observation.Retry);
        }
    }

    [Fact]
    public async Task RevealFailureShowsMissingFolderWithoutEngineFailure()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        const string folder = "opaque-folder", path = "/engine/actual/missing", error = "録音フォルダが見つかりません: /engine/actual/missing";
        var inspection = Readable(folder, "saved-session", false, false, "検査済み") with { FolderPath = path };
        var requests = new List<EngineCommand>();
        engine.AutoResponse = command => { requests.Add(command); return command switch
        {
            EngineCommand.SessionInspect => new EngineResult.SessionInspect(inspection),
            _ => throw new NotSupportedException($"Unexpected command: {command.Name}.")
        }; };
        var revealer = new TestFolderRevealer { Failure = new DirectoryNotFoundException(error) };
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock); var vm = new SessionsViewModel(context, revealer);
        vm.Select.Execute(inspection); await vm.Select.Execution!; await RenderAsync(dispatcher, clock);
        var sent = engine.SentCount; vm.RevealFolder.Execute(null); await vm.RevealFolder.Execution!; await RenderAsync(dispatcher, clock);
        Assert.Equal(path, revealer.RequestedPath); Assert.Equal(error, vm.CommandError);
        Assert.Equal(ShellPhase.Running, store.State.Phase); Assert.Null(store.State.StoreFailure);
        Assert.Equal(sent, engine.SentCount); Assert.Single(requests);
    }

    private static EngineSessionSummary Readable(string folder, string session, bool reprocess, bool retry, string status) =>
        new(folder, session, EngineSessionStatus.Finalized, null, "Engine display", status, "/engine/actual/session", null,
            reprocess, retry, false, new EngineSessionMetadata.Readable(1, new EngineSessionSource.Microphone(), new EngineSessionAudio.Available(), true));

    private static async Task<ShellStore> Start(SessionInspectClient engine, TimeProvider clock)
    {
        var store = new ShellStore(engine, clock);
        await store.Initialization.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        return store;
    }

    private static async Task RenderAsync(TestDispatcher dispatcher, ManualClock clock)
    {
        if (dispatcher.PendingCount == 0) { await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(100)); }
        dispatcher.Run();
    }

    private sealed class SessionInspectClient(Fake inner) : IEngineClient
    {
        private readonly TaskCompletionSource<SessionInspectRequest> _request = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _sentCount;

        public int SentCount => inner.SentCount + Volatile.Read(ref _sentCount);
        public Task<EngineResult> Hello => inner.Hello;
        public Task<EngineResult> SendAsync(EngineCommand command)
        {
            if (command is not EngineCommand.SessionInspect) return inner.SendAsync(command);
            Interlocked.Increment(ref _sentCount);
            var result = new TaskCompletionSource<EngineResult>(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!_request.TrySetResult(new SessionInspectRequest(command, result))) throw new InvalidOperationException("Unexpected second session inspection request.");
            return result.Task;
        }
        public Task<SessionInspectRequest> NextRequestAsync() => _request.Task.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        public IReadOnlyList<EngineOutput> DrainEvents() => inner.DrainEvents();
        public void EmitBatch(params EngineOutput[] events) => inner.EmitBatch(events);
        public Task WaitForEventsAsync(CancellationToken cancellationToken) => inner.WaitForEventsAsync(cancellationToken);
        public Task<EngineClientState> Completion => inner.Completion;
        public EngineClientState State => inner.State;
        public EngineClientFailure? Failure => inner.Failure;
    }

    private sealed record SessionInspectRequest(EngineCommand Command, TaskCompletionSource<EngineResult> Result)
    {
        public void Complete(EngineResult result) => Result.TrySetResult(result);
    }
}
