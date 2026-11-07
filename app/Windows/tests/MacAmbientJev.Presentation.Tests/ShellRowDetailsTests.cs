using System.Threading.Channels;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Presentation.Tests;

public sealed partial class ShellStoreTests
{
    [Theory]
    [InlineData(EngineClauseState.AwaitingNextSegment, "発話文: 続き待ち")]
    [InlineData(EngineClauseState.BoundaryPending, "発話文: 境界判定を保留中")]
    [InlineData(EngineClauseState.PriorityPending, "発話文: 優先度判定を待っています")]
    [InlineData(EngineClauseState.Classified, "発話文: 判定済み")]
    public async Task RowDetailsUsesEngineTextAndEveryOpaqueSpeakerPage(EngineClauseState clause, string text)
    {
        var (engine, clock, instance) = await StartRowDetailsAsync(); await using var store = instance;
        using var context = new ShellUiContext(store, new TestDispatcher(), clock);
        var live = new LiveViewModel(context);
        var read = live.ReadRowDetailsAsync("row"); var request = await engine.NextDetailsAsync();
        var payload = Assert.IsType<EngineCommand.TranscriptRowDetails>(request.Command).Payload;
        Assert.Equal("A", payload.SessionID); Assert.Equal(new EngineID(11), payload.Revision);
        Assert.Equal("row", payload.RowID); Assert.Null(payload.Cursor); Assert.Equal(200, payload.Limit);
        Assert.True(store.State.IsPending(EngineCommandName.TranscriptRowDetails));
        Assert.IsType<RowDetailsRead<ShellTranscriptRowDetails>.Failed>(await live.ReadRowDetailsAsync("row")); Assert.Equal(1, engine.DetailCount);
        Assert.Equal("同じ種類の操作を処理中です。", store.State.CommandError);
        request.Complete(new EngineResult.TranscriptRowDetails(DetailPage(clause, text) with
        {
            Speakers = [new("internal-1", "Speaker 1", 0, 850), new("internal-1", "Speaker 1", 700, 1500)],
            NextCursor = "opaque/not-a-number"
        }));
        request = await engine.NextDetailsAsync();
        var continuation = Assert.IsType<EngineCommand.TranscriptRowDetails>(request.Command).Payload;
        Assert.Equal(payload with { Cursor = "opaque/not-a-number" }, continuation);
        Assert.True(store.State.IsPending(EngineCommandName.TranscriptRowDetails)); Assert.False(read.IsCompleted);
        var labels = new[] { "Speaker 2", "Speaker 3", "Speaker 4", "Speaker 5", "Speaker 6", "Speaker 7", "OTHER", "UNKNOWN", "raw-speaker" };
        request.Complete(new EngineResult.TranscriptRowDetails(DetailPage(clause, text) with
        {
            Speakers = labels.Select(label => new EngineTranscriptSpeakerSpan("internal-" + label, label, 3_661_999, 3_723_999)).ToArray(),
            PreviousCursor = "opaque-previous"
        }));
        var details = Assert.IsType<RowDetailsRead<ShellTranscriptRowDetails>.Read>(await read).Details;
        Assert.Equal("A", details.SessionID); Assert.Equal(new EngineID(11), details.Revision); Assert.Equal("row", details.RowID);
        Assert.Equal(clause, details.ClauseState); Assert.Equal(text, details.ClauseStateText);
        Assert.Equal(new[] { "Speaker 1 · 00:00–00:00", "Speaker 1 · 00:00–00:01" }
            .Concat(labels.Select(label => label + " · 61:01–62:03")), details.SpeakerTexts);
        Assert.False(store.State.IsPending(EngineCommandName.TranscriptRowDetails));
        Assert.Null(store.State.CommandError); Assert.Equal(2, engine.DetailCount);
    }

    [Fact]
    public async Task RowDetailsPreservesEmptySpeakersAndServerDescriptionWithoutInference()
    {
        var (engine, clock, instance) = await StartRowDetailsAsync(); await using var store = instance;
        using var context = new ShellUiContext(store, new TestDispatcher(), clock);
        var live = new LiveViewModel(context); var read = live.ReadRowDetailsAsync("row");
        (await engine.NextDetailsAsync()).Complete(new EngineResult.TranscriptRowDetails(
            DetailPage(EngineClauseState.Classified, "engine-owned exact description")));
        var details = Assert.IsType<RowDetailsRead<ShellTranscriptRowDetails>.Read>(await read).Details;
        Assert.Equal("engine-owned exact description", details.ClauseStateText); Assert.Empty(details.SpeakerTexts);
    }

    [Fact]
    public async Task LiveRowDetailsReportsInvalidatedReadAsSupersededNotFailed()
    {
        var (engine, clock, instance) = await StartRowDetailsAsync(); await using var store = instance;
        using var context = new ShellUiContext(store, new TestDispatcher(), clock);
        var read = new LiveViewModel(context).ReadRowDetailsAsync("row"); var request = await engine.NextDetailsAsync();
        var progress = new EngineProgressPayload(EngineStage.ValidatingModels, 2, 3, null);
        engine.Inner.EmitBatch(Rows("A", EngineRowsKind.Changes), new EngineOutput(1, new EngineID(2), null, new EngineEvent.Progress(progress)));
        await ChangedTo(store, state => state.Progress == progress);
        request.Complete(new EngineResult.TranscriptRowDetails(DetailPage()));
        Assert.IsType<RowDetailsRead<ShellTranscriptRowDetails>.Superseded>(await read);
        Assert.Null(store.State.LastError); Assert.Null(store.State.CommandError);
    }

    [Fact]
    public async Task RowDetailsRejectsUnknownRowsAndMissingSessionWithoutSending()
    {
        var engine = new RowDetailsClient(NewEngine()); var clock = new ManualClock();
        await using var store = new ShellStore(engine, clock); await store.Initialization;
        Assert.IsType<RowDetailsRead<ShellRowDetails>.Failed>(await store.ReadRowDetailsAsync("row"));
        Assert.Equal("詳細を表示する文字起こしの行を選択してください。", store.State.CommandError);
        await SelectReady(store, engine.Inner, "A", Page("A", 11, "row", null, null));
        Assert.IsType<RowDetailsRead<ShellRowDetails>.Failed>(await store.ReadRowDetailsAsync("absent"));
        Assert.Equal("詳細を表示する文字起こしの行を選択してください。", store.State.CommandError);
        Assert.Equal(0, engine.DetailCount); Assert.Equal(ShellPhase.Running, store.State.Phase);
    }

    [Fact]
    public async Task RowDetailsStaleRevisionWhileTailIsCurrentIsNotShownAsAnError()
    {
        var (engine, _, instance) = await StartRowDetailsAsync(); await using var store = instance;
        var tail = store.State.Transcript.Tail;
        var read = store.ReadRowDetailsAsync("row"); var request = await engine.NextDetailsAsync();
        request.Reject(Failure(EngineErrorCode.StaleRevision, "engine moved ahead", EngineRecoveryAction.Retry));
        Assert.IsType<RowDetailsRead<ShellRowDetails>.Superseded>(await read); Assert.Null(store.State.LastError); Assert.Null(store.State.CommandError);
        Assert.Same(tail, store.State.Transcript.Tail);
        Assert.False(store.State.IsPending(EngineCommandName.TranscriptRowDetails)); Assert.Equal(1, engine.DetailCount);
    }

    [Theory]
    [InlineData(EngineErrorCode.InvalidCursor)]
    [InlineData(EngineErrorCode.RowTooLarge)]
    [InlineData(EngineErrorCode.Busy)]
    public async Task RowDetailsErrorsAreExplicitAndNeverRetryOrInventDetails(EngineErrorCode code)
    {
        var (engine, _, instance) = await StartRowDetailsAsync(); await using var store = instance;
        var tail = store.State.Transcript.Tail;
        var read = store.ReadRowDetailsAsync("row"); var request = await engine.NextDetailsAsync();
        request.Reject(Failure(code, "engine row-details error", EngineRecoveryAction.Retry));
        Assert.IsType<RowDetailsRead<ShellRowDetails>.Failed>(await read); Assert.Equal(code, store.State.LastError!.Code);
        Assert.Equal("engine row-details error", store.State.LastError.Message); Assert.Same(tail, store.State.Transcript.Tail);
        Assert.Equal(ShellPhase.Running, store.State.Phase); Assert.False(store.State.IsPending(EngineCommandName.TranscriptRowDetails));
        Assert.Equal(1, engine.DetailCount);
    }

    [Fact]
    public async Task RowDetailsDoesNotReturnPartialSpeakersIfContinuationFails()
    {
        var (engine, _, instance) = await StartRowDetailsAsync(); await using var store = instance;
        var read = store.ReadRowDetailsAsync("row"); var request = await engine.NextDetailsAsync();
        request.Complete(new EngineResult.TranscriptRowDetails(DetailPage() with
        { Speakers = [new("id", "Speaker 2", 0, 1000)], NextCursor = "next" }));
        (await engine.NextDetailsAsync()).Reject(Failure(EngineErrorCode.InvalidCursor, "expired", EngineRecoveryAction.Retry));
        Assert.IsType<RowDetailsRead<ShellRowDetails>.Failed>(await read); Assert.Equal("expired", store.State.LastError!.Message); Assert.Equal(2, engine.DetailCount);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RowDetailsIgnoresLateRepliesAfterSwitchingAwayAndBack(bool error)
    {
        var (engine, clock, instance) = await StartRowDetailsAsync(); await using var store = instance;
        var read = store.ReadRowDetailsAsync("row"); var request = await engine.NextDetailsAsync();
        await store.SelectSessionAsync("B"); await store.SelectSessionAsync("A");
        await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(250));
        var watch = await engine.Inner.NextRequestAsync();
        watch.Complete(new EngineResult.TranscriptWatch(Page("A", 11, "row", null, null)));
        await ChangedTo(store, state => state.Transcript.Tail?.Revision == new EngineID(11));
        if (error) request.Reject(Failure(EngineErrorCode.StaleRevision, "obsolete error", EngineRecoveryAction.Retry));
        else request.Complete(new EngineResult.TranscriptRowDetails(DetailPage()));
        Assert.IsType<RowDetailsRead<ShellRowDetails>.Superseded>(await read); Assert.Null(store.State.LastError); Assert.Null(store.State.StoreFailure);
        Assert.False(store.State.IsPending(EngineCommandName.TranscriptRowDetails)); Assert.Equal(1, engine.DetailCount);
    }

    [Theory]
    [InlineData(EngineRowsKind.Changes)]
    [InlineData(EngineRowsKind.ReloadRequired)]
    public async Task RowDetailsInvalidationDiscardsDetailsBeforeTailRefresh(EngineRowsKind kind)
    {
        var (engine, _, instance) = await StartRowDetailsAsync(); await using var store = instance;
        var read = store.ReadRowDetailsAsync("row"); var request = await engine.NextDetailsAsync();
        var progress = new EngineProgressPayload(EngineStage.ValidatingModels, 2, 3, null);
        engine.Inner.EmitBatch(Rows("A", kind), new EngineOutput(1, new EngineID(2), null, new EngineEvent.Progress(progress)));
        await ChangedTo(store, state => state.Progress == progress);
        request.Complete(new EngineResult.TranscriptRowDetails(DetailPage() with
        { Speakers = [new("id", "Speaker 1", 0, 1000)], NextCursor = "must-not-be-used" }));
        Assert.IsType<RowDetailsRead<ShellRowDetails>.Superseded>(await read); Assert.Equal(1, engine.DetailCount); Assert.Null(store.State.StoreFailure);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RowDetailsDiscardsObsoleteReplyThenRerequestsSameRowAtNewTailRevision(bool error)
    {
        var (engine, clock, instance) = await StartRowDetailsAsync(); await using var store = instance;
        var read = store.ReadRowDetailsAsync("row"); var request = await engine.NextDetailsAsync();
        await store.ReturnToLatestAsync(); await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(250));
        var watch = await engine.Inner.NextRequestAsync(); watch.Complete(new EngineResult.TranscriptWatch(Page("A", 12, "row", null, null)));
        await ChangedTo(store, state => state.Transcript.Tail?.Revision == new EngineID(12));
        Assert.IsType<RowDetailsRead<ShellRowDetails>.Failed>(await store.ReadRowDetailsAsync("row"));
        Assert.Equal("同じ種類の操作を処理中です。", store.State.CommandError);
        Assert.Equal(1, engine.DetailCount); // The caller waits for the old strict-store request to settle.
        if (error) request.Reject(Failure(EngineErrorCode.StaleRevision, "obsolete error", EngineRecoveryAction.Retry));
        else request.Complete(new EngineResult.TranscriptRowDetails(DetailPage()));
        Assert.IsType<RowDetailsRead<ShellRowDetails>.Superseded>(await read); Assert.Null(store.State.LastError);
        Assert.False(store.State.IsPending(EngineCommandName.TranscriptRowDetails));

        var refresh = store.ReadRowDetailsAsync("row"); var current = await engine.NextDetailsAsync();
        var payload = Assert.IsType<EngineCommand.TranscriptRowDetails>(current.Command).Payload;
        Assert.Equal("A", payload.SessionID); Assert.Equal("row", payload.RowID); Assert.Equal(new EngineID(12), payload.Revision);
        current.Complete(new EngineResult.TranscriptRowDetails(DetailPage() with { Revision = new EngineID(12), ClauseStateText = "更新後の判定" }));
        var details = Assert.IsType<RowDetailsRead<ShellRowDetails>.Read>(await refresh).Details;
        Assert.Equal(new EngineID(12), details.Revision); Assert.Equal("更新後の判定", details.ClauseStateText);
        Assert.Equal(2, engine.DetailCount); Assert.Null(store.State.CommandError); Assert.Null(store.State.StoreFailure);
    }

    [Fact]
    public async Task RowDetailsCanReadAnotherDisplayedRowAfterPendingRequestCompletes()
    {
        var (engine, clock, instance) = await StartRowDetailsAsync(); await using var store = instance;
        await store.ReturnToLatestAsync(); await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(250));
        (await engine.Inner.NextRequestAsync()).Complete(new EngineResult.TranscriptWatch(
            Page("A", 12, "row", null, null) with { Rows = [Row("row", 0, "最初"), Row("other", 1000, "別の行")] }));
        await ChangedTo(store, state => state.Transcript.Tail?.Revision == new EngineID(12));
        var first = store.ReadRowDetailsAsync("row"); var request = await engine.NextDetailsAsync();
        Assert.IsType<RowDetailsRead<ShellRowDetails>.Failed>(await store.ReadRowDetailsAsync("other")); Assert.Equal(1, engine.DetailCount);
        request.Complete(new EngineResult.TranscriptRowDetails(DetailPage() with { Revision = new EngineID(12) }));
        Assert.IsType<RowDetailsRead<ShellRowDetails>.Read>(await first);
        var switched = store.ReadRowDetailsAsync("other"); request = await engine.NextDetailsAsync();
        var payload = Assert.IsType<EngineCommand.TranscriptRowDetails>(request.Command).Payload;
        Assert.Equal("other", payload.RowID); Assert.Equal(new EngineID(12), payload.Revision);
        request.Complete(new EngineResult.TranscriptRowDetails(DetailPage() with { Revision = new EngineID(12), RowID = "other" }));
        Assert.Equal("other", Assert.IsType<RowDetailsRead<ShellRowDetails>.Read>(await switched).Details.RowID);
        Assert.Equal(2, engine.DetailCount); Assert.Null(store.State.CommandError);
    }

    [Fact]
    public async Task RowDetailsDiscardsReplyAndRejectsNewReadWhenRowWasRemoved()
    {
        var (engine, clock, instance) = await StartRowDetailsAsync(); await using var store = instance;
        var read = store.ReadRowDetailsAsync("row"); var request = await engine.NextDetailsAsync();
        await store.ReturnToLatestAsync(); await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(250));
        (await engine.Inner.NextRequestAsync()).Complete(new EngineResult.TranscriptWatch(Page("A", 12, "replacement", null, null)));
        await ChangedTo(store, state => state.Transcript.Tail?.Revision == new EngineID(12));
        request.Complete(new EngineResult.TranscriptRowDetails(DetailPage()));
        Assert.IsType<RowDetailsRead<ShellRowDetails>.Superseded>(await read); Assert.IsType<RowDetailsRead<ShellRowDetails>.Failed>(await store.ReadRowDetailsAsync("row"));
        Assert.Equal("詳細を表示する文字起こしの行を選択してください。", store.State.CommandError);
        Assert.Equal(1, engine.DetailCount); Assert.Null(store.State.LastError); Assert.Null(store.State.StoreFailure);
    }

    [Theory]
    [InlineData("session")]
    [InlineData("revision")]
    [InlineData("row")]
    [InlineData("type")]
    public async Task RowDetailsRejectsMismatchedResponseIdentity(string mismatch)
    {
        var (engine, _, instance) = await StartRowDetailsAsync(); await using var store = instance;
        var read = store.ReadRowDetailsAsync("row"); var request = await engine.NextDetailsAsync();
        var page = mismatch switch
        {
            "session" => DetailPage() with { SessionID = "B" },
            "revision" => DetailPage() with { Revision = new EngineID(12) },
            "row" => DetailPage() with { RowID = "other" },
            _ => DetailPage()
        };
        request.Complete(mismatch == "type" ? new EngineResult.TranscriptWatch(Page("A", 11, "row", null, null))
            : new EngineResult.TranscriptRowDetails(page));
        Assert.IsType<RowDetailsRead<ShellRowDetails>.Failed>(await read); Assert.Equal(ShellPhase.EngineFailed, store.State.Phase);
        Assert.Contains("transcript.row_details", store.State.StoreFailure!);
        Assert.False(store.State.IsPending(EngineCommandName.TranscriptRowDetails));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RowDetailsRejectsInconsistentOrNonAdvancingContinuation(bool clauseChanged)
    {
        var (engine, _, instance) = await StartRowDetailsAsync(); await using var store = instance;
        var read = store.ReadRowDetailsAsync("row"); var request = await engine.NextDetailsAsync();
        var page = DetailPage() with { Speakers = [new("id", "Speaker 1", 0, 1000)], NextCursor = "same-cursor" };
        request.Complete(new EngineResult.TranscriptRowDetails(page)); request = await engine.NextDetailsAsync();
        request.Complete(new EngineResult.TranscriptRowDetails(clauseChanged ? page with { ClauseStateText = "changed" } : page));
        Assert.IsType<RowDetailsRead<ShellRowDetails>.Failed>(await read); Assert.Equal(ShellPhase.EngineFailed, store.State.Phase); Assert.Equal(2, engine.DetailCount);
    }

    [Fact]
    public async Task RowDetailsDisposalCancelsAwaitAndDoesNotOwnClientLifetime()
    {
        var (engine, _, store) = await StartRowDetailsAsync();
        var read = store.ReadRowDetailsAsync("row"); var request = await engine.NextDetailsAsync();
        await store.DisposeAsync(); await Assert.ThrowsAnyAsync<OperationCanceledException>(() => read);
        Assert.Equal(ShellPhase.Disposed, store.State.Phase); Assert.Empty(store.State.Pending);
        Assert.Equal(EngineClientState.Running, engine.State);
        request.Complete(new EngineResult.TranscriptRowDetails(DetailPage()));
    }

    private static EngineTranscriptRowDetailsPage DetailPage(EngineClauseState clause = EngineClauseState.Classified,
        string text = "発話文: 判定済み") => new("A", new EngineID(11), "row", clause, text, [], null, null);

    private static async Task<(RowDetailsClient Engine, ManualClock Clock, ShellStore Store)> StartRowDetailsAsync()
    {
        var engine = new RowDetailsClient(NewEngine()); var clock = new ManualClock();
        var store = new ShellStore(engine, clock); await store.Initialization;
        await SelectReady(store, engine.Inner, "A", Page("A", 11, "row", null, null));
        return (engine, clock, store);
    }

    private sealed class RowDetailsClient(Fake inner) : IEngineClient
    {
        private readonly Channel<Request> _details = Channel.CreateUnbounded<Request>();
        private int _count;
        public Fake Inner { get; } = inner;
        public int DetailCount => Volatile.Read(ref _count);
        public Task<EngineResult> Hello => Inner.Hello;
        public Task<EngineClientState> Completion => Inner.Completion;
        public EngineClientState State => Inner.State;
        public EngineClientFailure? Failure => Inner.Failure;
        public Task<EngineResult> SendAsync(EngineCommand command)
        {
            if (command is not EngineCommand.TranscriptRowDetails) return Inner.SendAsync(command);
            Interlocked.Increment(ref _count);
            var result = new TaskCompletionSource<EngineResult>(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!_details.Writer.TryWrite(new Request(command, result))) throw new InvalidOperationException("Details channel closed.");
            return result.Task;
        }
        public async Task<Request> NextDetailsAsync() => await _details.Reader.ReadAsync(TestContext.Current.CancellationToken)
            .AsTask().WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        public IReadOnlyList<EngineOutput> DrainEvents() => Inner.DrainEvents();
        public Task WaitForEventsAsync(CancellationToken cancellationToken) => Inner.WaitForEventsAsync(cancellationToken);
    }
}
