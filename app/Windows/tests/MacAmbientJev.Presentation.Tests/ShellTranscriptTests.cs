using System.Threading.Channels;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Presentation.Tests;

public sealed partial class ShellStoreTests
{
    [Fact] public async Task TranscriptInvalidationsCoalesceAndRespectRefreshCadence()
    {
        var engine = new Fake(State(EngineSetupStatus.Ready, 1), Response(SettingsResult(1, Settings(2, false, false, false, null))));
        var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await SelectReady(store, engine, "A", Page("A", 1, "old", null, null));
        var progress = new EngineProgressPayload(EngineStage.ValidatingModels, 1, 2, null);
        engine.EmitBatch(Enumerable.Range(0, 20).Select(i => Rows("A", i % 2 == 0 ? EngineRowsKind.Changes : EngineRowsKind.ReloadRequired)).Append(new EngineOutput(1, new EngineID(1), null, new EngineEvent.Progress(progress))).ToArray());
        await ChangedTo(store, s => s.Progress == progress); await clock.WaitForTimerAsync();
        Assert.Equal("old", store.State.Transcript.Tail!.Rows[0].Text);
        var sent = engine.SentCount;
        clock.Advance(TimeSpan.FromMilliseconds(249)); Assert.Equal(sent, engine.SentCount);
        clock.Advance(TimeSpan.FromMilliseconds(1)); var refresh = await engine.NextRequestAsync(); var firstRefreshStart = clock.GetTimestamp();
        Assert.Equal("A", Assert.IsType<EngineCommand.TranscriptWatch>(refresh.Command).Payload.SessionID);
        var nextProgress = new EngineProgressPayload(EngineStage.ValidatingModels, 2, 2, null);
        engine.EmitBatch(Rows("A", EngineRowsKind.Changes), new EngineOutput(1, new EngineID(2), null, new EngineEvent.Progress(nextProgress)));
        await ChangedTo(store, s => s.Progress == nextProgress);
        refresh.Complete(new EngineResult.TranscriptWatch(Page("A", 2, "late", null, null) with { Rows = [Row("late", 90, "late"), Row("early", 10, "early")] }));
        var unsorted = await ChangedTo(store, s => s.Transcript.Tail?.Revision == new EngineID(2));
        Assert.Equal(new[] { "late", "early" }, unsorted.Transcript.Tail!.Rows.Select(r => r.Text)); await clock.WaitForTimerAsync();
        sent = engine.SentCount; clock.Advance(TimeSpan.FromMilliseconds(249)); Assert.Equal(sent, engine.SentCount);
        clock.Advance(TimeSpan.FromMilliseconds(1)); var second = await engine.NextRequestAsync();
        Assert.True(clock.GetElapsedTime(firstRefreshStart, clock.GetTimestamp()) >= TimeSpan.FromMilliseconds(250));
        second.Complete(new EngineResult.TranscriptWatch(Page("A", 3, "final", null, null)));
        await ChangedTo(store, s => s.Transcript.Tail?.Revision == new EngineID(3));
        sent = engine.SentCount; clock.Advance(TimeSpan.FromHours(1)); Assert.Equal(sent, engine.SentCount);
    }

    [Fact] public async Task TranscriptHistoryEvictsAtThreePagesAndRefetchesWithOpaquePreviousCursor()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await SelectReady(store, engine, "A", Page("A", 1, "tail", null, null));
        for (var i = 1; i <= 4; i++)
        {
            var move = i == 1 ? ShellPageMove.Reload : ShellPageMove.Next;
            var read = store.ReadHistoryAsync(move); var request = await engine.NextRequestAsync();
            var payload = Assert.IsType<EngineCommand.TranscriptRead>(request.Command).Payload;
            Assert.Equal("A", payload.SessionID); Assert.Equal(200, payload.Limit);
            Assert.Equal(i == 1 ? null : $"opaque-next-{i - 1}", payload.Cursor);
            Assert.Equal(i == 1 ? null : new EngineID(44), payload.Revision);
            request.Complete(new EngineResult.TranscriptRead(Page("A", 44, $"p{i}", i < 4 ? $"opaque-next-{i}" : null, i > 1 ? $"opaque-prev-{i - 1}" : null)));
            Assert.True(await read);
        }
        Assert.Equal(new[] { "p2", "p3", "p4" }, store.State.Transcript.History.Pages.Select(p => p.Rows[0].Text));
        foreach (var target in new[] { "p3", "p2", "p1" })
        {
            var read = store.ReadHistoryAsync(ShellPageMove.Previous); var request = await engine.NextRequestAsync();
            var payload = Assert.IsType<EngineCommand.TranscriptRead>(request.Command).Payload;
            Assert.Equal(target == "p3" ? "opaque-prev-3" : target == "p2" ? "opaque-prev-2" : "opaque-prev-1", payload.Cursor);
            Assert.Equal(new EngineID(44), payload.Revision);
            request.Complete(new EngineResult.TranscriptRead(Page("A", 44, target, $"next-{target}", target == "p1" ? null : $"opaque-prev-{target[^1] - '0' - 1}")));
            Assert.True(await read);
        }
        Assert.Equal(new[] { "p1", "p2", "p3" }, store.State.Transcript.History.Pages.Select(p => p.Rows[0].Text));
        Assert.Equal(0, store.State.Transcript.History.Index);
        var sent = engine.SentCount; Assert.False(await store.ReadHistoryAsync(ShellPageMove.Previous));
        Assert.Equal(sent, engine.SentCount); Assert.Contains("previous", store.State.CommandError!, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData(EngineErrorCode.StaleRevision, true)]
    [InlineData(EngineErrorCode.InvalidCursor, false)]
    public async Task TranscriptHistoryErrorsKeepPagesAndOnlyStaleRevisionBlocksContinuation(EngineErrorCode code, bool stale)
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await SelectReady(store, engine, "A", Page("A", 1, "tail", null, null));
        var first = store.ReadHistoryAsync(ShellPageMove.Reload); var request = await engine.NextRequestAsync();
        Assert.Null(Assert.IsType<EngineCommand.TranscriptRead>(request.Command).Payload.Cursor);
        request.Complete(new EngineResult.TranscriptRead(Page("A", 7, "kept", "opaque-next", null))); Assert.True(await first);
        var pages = store.State.Transcript.History.Pages;
        var next = store.ReadHistoryAsync(ShellPageMove.Next); request = await engine.NextRequestAsync();
        var continuation = Assert.IsType<EngineCommand.TranscriptRead>(request.Command).Payload;
        Assert.Equal(new EngineID(7), continuation.Revision); Assert.Equal("opaque-next", continuation.Cursor);
        request.Reject(Failure(code, "history rejected", EngineRecoveryAction.Retry));
        Assert.False(await next); Assert.Equal(pages, store.State.Transcript.History.Pages);
        Assert.Equal(stale, store.State.Transcript.HistoryStale); Assert.Equal(code, store.State.LastError!.Code);
        if (stale)
        {
            var sent = engine.SentCount; Assert.False(await store.ReadHistoryAsync(ShellPageMove.Next)); Assert.Equal(sent, engine.SentCount);
        }
        var reload = store.ReadHistoryAsync(ShellPageMove.Reload); request = await engine.NextRequestAsync();
        var reloadPayload = Assert.IsType<EngineCommand.TranscriptRead>(request.Command).Payload;
        Assert.Null(reloadPayload.Revision); Assert.Null(reloadPayload.Cursor); Assert.Equal(pages, store.State.Transcript.History.Pages);
        request.Complete(new EngineResult.TranscriptRead(Page("A", 9, "replacement", null, null))); Assert.True(await reload);
        Assert.Equal(new[] { "replacement" }, store.State.Transcript.History.Pages.Select(p => p.Rows[0].Text));
        Assert.False(store.State.Transcript.HistoryStale);
    }

    [Fact] public async Task SwitchingSessionClearsAndIgnoresOldResultsWithoutOverlappingWatches()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var watchA = await SelectRequest(store, engine, "A");
        var firstHistoryA = store.ReadHistoryAsync(ShellPageMove.Reload); var firstReadA = await engine.NextRequestAsync();
        firstReadA.Complete(new EngineResult.TranscriptRead(Page("A", 3, "kept-A", "opaque-A", null))); Assert.True(await firstHistoryA);
        var historyA = store.ReadHistoryAsync(ShellPageMove.Next); var readA = await engine.NextRequestAsync();
        Assert.NotEmpty(store.State.Transcript.History.Pages);
        await store.SelectSessionAsync("B"); Assert.Equal("B", store.State.Transcript.SessionID);
        Assert.Empty(store.State.Transcript.History.Pages);
        var sent = engine.SentCount; Assert.False(await store.ReadHistoryAsync(ShellPageMove.Reload)); Assert.Equal(sent, engine.SentCount);
        readA.Complete(new EngineResult.TranscriptRead(Page("A", 3, "late-A", null, null))); Assert.True(await historyA);
        Assert.Empty(store.State.Transcript.History.Pages);
        var historyB = store.ReadHistoryAsync(ShellPageMove.Reload); var readB = await engine.NextRequestAsync();
        Assert.Equal("B", Assert.IsType<EngineCommand.TranscriptRead>(readB.Command).Payload.SessionID);
        readB.Complete(new EngineResult.TranscriptRead(Page("B", 4, "B-history", null, null))); Assert.True(await historyB); Assert.Equal(sent + 1, engine.SentCount);
        watchA.Complete(new EngineResult.TranscriptWatch(Page("A", 5, "late-tail", null, null)));
        await clock.WaitForTimerAsync(); Assert.Null(store.State.Transcript.Tail);
        sent = engine.SentCount; clock.Advance(TimeSpan.FromMilliseconds(249)); Assert.Equal(sent, engine.SentCount);
        clock.Advance(TimeSpan.FromMilliseconds(1)); var watchB = await engine.NextRequestAsync();
        Assert.Equal("B", Assert.IsType<EngineCommand.TranscriptWatch>(watchB.Command).Payload.SessionID);
        watchB.Complete(new EngineResult.TranscriptWatch(Page("B", 6, "B-tail", null, null)));
        var state = await ChangedTo(store, s => s.Transcript.Tail?.Revision == new EngineID(6));
        Assert.Equal("B", state.Transcript.Tail!.SessionID); Assert.Equal("B-history", state.Transcript.History.Current!.Rows[0].Text);
    }

    [Fact] public async Task FollowChangesOnlyFromUserIntentAndReturnToLatestRefetches()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await SelectReady(store, engine, "A", Page("A", 1, "initial", null, null)); Assert.True(store.State.Transcript.Follow);
        await store.UserScrolledAsync(); Assert.False(store.State.Transcript.Follow);
        var progress = new EngineProgressPayload(EngineStage.ValidatingModels, 1, 3, null);
        engine.EmitBatch(Rows("A", EngineRowsKind.Changes), new EngineOutput(1, new EngineID(1), null, new EngineEvent.State(State(EngineSetupStatus.Ready, 2))), new EngineOutput(1, new EngineID(2), null, new EngineEvent.Progress(progress)));
        await ChangedTo(store, s => s.Progress == progress); Assert.False(store.State.Transcript.Follow); Assert.True(store.State.Transcript.NewUpdatesAvailable);
        await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(250)); var refresh = await engine.NextRequestAsync();
        refresh.Complete(new EngineResult.TranscriptWatch(Page("A", 2, "replacement", null, null)));
        var updated = await ChangedTo(store, s => s.Transcript.Tail?.Revision == new EngineID(2));
        Assert.False(updated.Transcript.Follow); Assert.True(updated.Transcript.NewUpdatesAvailable);
        await store.ReturnToLatestAsync(); Assert.True(store.State.Transcript.Follow); Assert.False(store.State.Transcript.NewUpdatesAvailable);
        await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(250)); refresh = await engine.NextRequestAsync();
        Assert.Equal("A", Assert.IsType<EngineCommand.TranscriptWatch>(refresh.Command).Payload.SessionID);
        refresh.Complete(new EngineResult.TranscriptWatch(Page("A", 3, "latest", null, null)));
        await ChangedTo(store, s => s.Transcript.Tail?.Revision == new EngineID(3));
        var afterLatest = new EngineProgressPayload(EngineStage.ValidatingModels, 3, 3, null);
        engine.EmitBatch(new EngineOutput(1, new EngineID(3), null, new EngineEvent.State(State(EngineSetupStatus.Ready, 3))), new EngineOutput(1, new EngineID(4), null, new EngineEvent.Progress(afterLatest)));
        await ChangedTo(store, s => s.Progress == afterLatest); Assert.True(store.State.Transcript.Follow); Assert.False(store.State.Transcript.NewUpdatesAvailable);
        var sent = engine.SentCount; clock.Advance(TimeSpan.FromHours(1)); Assert.Equal(sent, engine.SentCount);
    }

    [Fact] public async Task SessionPagesEvictAndNavigateBackwardWithOpaqueCursors()
    {
        var engine = NewEngine(); var storeClock = new ManualClock(); await using var store = await Start(engine, storeClock);
        for (var i = 1; i <= 4; i++)
        {
            var list = store.ListSessionsAsync(i == 1 ? ShellPageMove.Reload : ShellPageMove.Next); var request = await engine.NextRequestAsync();
            var payload = Assert.IsType<EngineCommand.SessionList>(request.Command).Payload;
            Assert.Equal(100, payload.Limit); Assert.Equal(i == 1 ? null : $"forward-{i - 1}", payload.Cursor);
            request.Complete(new EngineResult.SessionList(SessionPage($"s{i}", i < 4 ? $"forward-{i}" : null, i > 1 ? $"opaque-back-{i - 1}" : null)));
            Assert.True(await list);
        }
        Assert.Equal(new[] { "s2", "s3", "s4" }, store.State.Sessions.Pages.Select(p => p.Sessions[0].FolderID));
        foreach (var target in new[] { "s3", "s2", "s1" })
        {
            var list = store.ListSessionsAsync(ShellPageMove.Previous); var request = await engine.NextRequestAsync();
            var payload = Assert.IsType<EngineCommand.SessionList>(request.Command).Payload;
            Assert.Equal(target == "s3" ? "opaque-back-3" : target == "s2" ? "opaque-back-2" : "opaque-back-1", payload.Cursor);
            request.Complete(new EngineResult.SessionList(SessionPage(target, $"forward-{target}", target == "s1" ? null : $"opaque-back-{target[^1] - '0' - 1}")));
            Assert.True(await list);
        }
        Assert.Equal(new[] { "s1", "s2", "s3" }, store.State.Sessions.Pages.Select(p => p.Sessions[0].FolderID));
        Assert.Equal(0, store.State.Sessions.Index);
        var sent = engine.SentCount; Assert.False(await store.ListSessionsAsync(ShellPageMove.Previous)); Assert.Equal(sent, engine.SentCount);
        var old = store.State.Sessions.Pages; var next = store.ListSessionsAsync(ShellPageMove.Next); var bad = await engine.NextRequestAsync();
        bad.Reject(Failure(EngineErrorCode.InvalidCursor, "session cursor rejected", EngineRecoveryAction.Retry));
        Assert.False(await next); Assert.Equal(old, store.State.Sessions.Pages); Assert.Equal(EngineErrorCode.InvalidCursor, store.State.LastError!.Code);
    }

    [Fact] public async Task ReloadRequiredStalesHistoryInvalidatesReadAndRefreshesSelectedSession()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await SelectReady(store, engine, "A", Page("A", 1, "tail", null, null));
        var initial = store.ReadHistoryAsync(ShellPageMove.Reload); var first = await engine.NextRequestAsync();
        first.Complete(new EngineResult.TranscriptRead(Page("A", 10, "kept", "old-cursor", null))); Assert.True(await initial);
        var pending = store.ReadHistoryAsync(ShellPageMove.Reload); var inFlight = await engine.NextRequestAsync();
        var progress = new EngineProgressPayload(EngineStage.ValidatingModels, 2, 3, null);
        engine.EmitBatch(Rows("A", EngineRowsKind.ReloadRequired), new EngineOutput(1, new EngineID(2), null, new EngineEvent.Progress(progress)));
        var stale = await ChangedTo(store, s => s.Progress == progress && s.Transcript.HistoryStale);
        Assert.Equal("kept", stale.Transcript.History.Current!.Rows[0].Text);
        inFlight.Complete(new EngineResult.TranscriptRead(Page("A", 11, "obsolete", null, null))); Assert.True(await pending);
        Assert.Equal("kept", store.State.Transcript.History.Current!.Rows[0].Text);
        await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(250)); var watch = await engine.NextRequestAsync();
        Assert.Equal("A", Assert.IsType<EngineCommand.TranscriptWatch>(watch.Command).Payload.SessionID);
        watch.Complete(new EngineResult.TranscriptWatch(Page("A", 12, "tail", null, null)));
        await ChangedTo(store, s => s.Transcript.Tail?.Revision == new EngineID(12));
        var reload = store.ReadHistoryAsync(ShellPageMove.Reload); var request = await engine.NextRequestAsync();
        var payload = Assert.IsType<EngineCommand.TranscriptRead>(request.Command).Payload;
        Assert.Null(payload.Revision); Assert.Null(payload.Cursor); Assert.True(store.State.Transcript.HistoryStale);
        request.Complete(new EngineResult.TranscriptRead(Page("A", 13, "fresh", null, null))); Assert.True(await reload);
        Assert.Equal("fresh", store.State.Transcript.History.Current!.Rows[0].Text); Assert.False(store.State.Transcript.HistoryStale);
    }
    private static Fake NewEngine() => new(State(EngineSetupStatus.Ready, 1), Response(SettingsResult(1, Settings(2, false, false, false, null))));
    private static async Task<ShellStore> Start(Fake engine, TimeProvider clock) { var store = new ShellStore(engine, clock); await store.Initialization.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken); return store; }
    private static async Task<Request> SelectRequest(ShellStore store, Fake engine, string id)
    {
        await store.SelectSessionAsync(id); var request = await engine.NextRequestAsync();
        Assert.Equal(id, Assert.IsType<EngineCommand.TranscriptWatch>(request.Command).Payload.SessionID); return request;
    }
    private static async Task SelectReady(ShellStore store, Fake engine, string id, EngineTranscriptPage page)
    {
        var request = await SelectRequest(store, engine, id); request.Complete(new EngineResult.TranscriptWatch(page));
        await ChangedTo(store, s => s.Transcript.Tail?.Revision == page.Revision);
    }
    private static EngineTranscriptRow Row(string id, long start, string text) => new(id, start, start, text, [], null);
    private static EngineTranscriptPage Page(string session, ulong revision, string id, string? next, string? previous) => new(session, new EngineID(revision), [Row(id, 1, id)], next, previous);
    private static EngineOutput Rows(string session, EngineRowsKind kind) => new(1, new EngineID(1), null, new EngineEvent.Rows(new EngineRowsPayload(session, new EngineID(1), kind, [], [], null)));
    private static EngineSessionListResult SessionPage(string id, string? next, string? previous) => new([new EngineSessionSummary(id, null, EngineSessionStatus.Unreadable, Failure(EngineErrorCode.InvalidSettings, "unreadable", EngineRecoveryAction.Retry), id, "Unreadable", id, null, false, false, false, new EngineSessionMetadata.Unreadable("unreadable"))], next, previous);

    private sealed class ManualClock : TimeProvider
    {
        private readonly object _gate = new(); private readonly List<ManualTimer> _timers = []; private readonly Channel<bool> _registrations = Channel.CreateUnbounded<bool>();
        private long _ticks;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() { lock (_gate) return _ticks; }
        public override DateTimeOffset GetUtcNow() => DateTimeOffset.UnixEpoch.AddTicks(GetTimestamp());
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var timer = new ManualTimer(this, callback, state); lock (_gate) _timers.Add(timer); timer.Change(dueTime, period); return timer;
        }
        public async Task WaitForTimerAsync() => await _registrations.Reader.ReadAsync(TestContext.Current.CancellationToken).AsTask().WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        public void Advance(TimeSpan amount)
        {
            if (amount < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(amount)); List<(TimerCallback Callback, object? State)> ready;
            lock (_gate) { _ticks = checked(_ticks + amount.Ticks); ready = _timers.Where(t => t.TakeIfDue(_ticks)).Select(t => (t.Callback, t.State)).ToList(); }
            foreach (var timer in ready) timer.Callback(timer.State);
        }
        private sealed class ManualTimer(ManualClock clock, TimerCallback callback, object? state) : ITimer
        {
            private long? _due; private bool _disposed;
            internal TimerCallback Callback { get; } = callback; internal object? State { get; } = state;
            public bool Change(TimeSpan dueTime, TimeSpan period)
            {
                if (period != Timeout.InfiniteTimeSpan) throw new NotSupportedException("ManualClock supports one-shot timers only.");
                if (dueTime < Timeout.InfiniteTimeSpan) throw new ArgumentOutOfRangeException(nameof(dueTime));
                lock (clock._gate) { if (_disposed) return false; _due = dueTime == Timeout.InfiniteTimeSpan ? null : checked(clock._ticks + dueTime.Ticks); }
                if (dueTime != Timeout.InfiniteTimeSpan && !clock._registrations.Writer.TryWrite(true)) throw new InvalidOperationException("Timer registration channel closed.");
                return true;
            }
            internal bool TakeIfDue(long now) { if (_disposed || _due is not long due || due > now) return false; _due = null; return true; }
            public void Dispose() { lock (clock._gate) { _disposed = true; _due = null; } }
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }
}
