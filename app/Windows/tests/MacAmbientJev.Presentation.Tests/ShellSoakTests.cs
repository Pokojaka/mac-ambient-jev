using System.Diagnostics;
using System.Threading.Channels;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Presentation.Tests;

public sealed partial class ShellStoreTests
{
    [Fact]
    public async Task PortablePresentationSoakBoundsCachesAndRefreshes()
    {
        const int batches = 1_000, triplets = 334, batchSize = triplets * 3;
        const ulong historyRevision = 7;
        const long maxGrowth = 4 * 1024 * 1024;
        var stopwatch = Stopwatch.StartNew(); var clock = new ManualClock(); var engine = NewEngine();
        EngineTranscriptRow Row(string id, long start, string text) => new(id, start, start, text, [], null);
        var sample = StrictWireCodec.Encode(Row("history-0000000000", 0, "x")).Length;
        var largeTextLength = EngineCodec.MaxRowBytes - sample + 1;
        var sessionError = Failure(EngineErrorCode.InvalidSettings, "unreadable", EngineRecoveryAction.Retry);
        long watchSerial = 0, historyRowsCreated = 0; var historyPages = 0; var sessionPages = 0;
        EngineTranscriptPage History(EngineTranscriptReadPayload request)
        {
            if (request.Revision is EngineID revision && revision.Value != historyRevision) throw new InvalidOperationException("History revision changed.");
            if ((request.Revision is null) != (request.Cursor is null) || request.Cursor is not null && request.Cursor != "opaque-next") throw new InvalidOperationException("History cursor was not passed opaquely.");
            var first = historyRowsCreated; historyRowsCreated += 200; var rows = new EngineTranscriptRow[200];
            rows[0] = Row($"history-{first:D10}", 0, new string('x', largeTextLength));
            for (var i = 1; i < rows.Length; i++) rows[i] = Row($"history-{first + i:D10}", 0, "history");
            Assert.Equal(EngineCodec.MaxRowBytes, StrictWireCodec.Encode(rows[0]).Length);
            if (++historyPages == 1) Assert.True(StrictWireCodec.Encode(new EngineTranscriptPage(request.SessionID, new EngineID(historyRevision), rows, "opaque-next", "opaque-previous")).Length <= 700_000);
            return new EngineTranscriptPage(request.SessionID, new EngineID(historyRevision), rows, "opaque-next", "opaque-previous");
        }
        EngineTranscriptPage Watch(string sessionID)
        {
            var serial = Interlocked.Increment(ref watchSerial); var rows = Enumerable.Range(0, 200).Select(i => Row($"tail-{serial:D8}-{i:D3}", i, "tail")).ToArray();
            return new EngineTranscriptPage(sessionID, new EngineID((ulong)serial), rows, null, null);
        }
        EngineSessionListResult Sessions(EngineSessionListPayload request)
        {
            var page = ++sessionPages;
            if ((page == 1) != (request.Cursor is null) || request.Cursor is not null && request.Cursor != "opaque-next") throw new InvalidOperationException("Session cursor was not passed opaquely.");
            var sessions = Enumerable.Range(0, 100).Select(i => new EngineSessionSummary(
                $"session-{page:D4}-{i:D3}", null, EngineSessionStatus.Unreadable, sessionError, "unreadable", "Unreadable", "unreadable", null,
                false, false, false, new EngineSessionMetadata.Unreadable("unreadable"))).ToArray();
            return new EngineSessionListResult(sessions, "opaque-next", "opaque-previous");
        }
        engine.AutoResponse = command => command switch
        {
            EngineCommand.TranscriptWatch watch => new EngineResult.TranscriptWatch(Watch(watch.Payload.SessionID)),
            EngineCommand.TranscriptRead read => new EngineResult.TranscriptRead(History(read.Payload)),
            EngineCommand.SessionList list => new EngineResult.SessionList(Sessions(list.Payload)),
            _ => throw new InvalidOperationException($"Unexpected soak command: {command.Name}.")
        };
        await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        _ = new LiveViewModel(context); _ = new ProcessingQueueViewModel(context); _ = new SessionsViewModel(context);
        _ = new SettingsViewModel(context); _ = new DiagnosticsViewModel(context);
        var renderTimes = new List<long>(); context.Refreshed += (_, _) => renderTimes.Add(clock.GetTimestamp());
        string? selected = null; ulong sequence = 0, stateRevision = 1, progressUnits = 0;
        long emitted = 0, historyHighWater = 0, sessionsHighWater = 0, heapBaseline = 0, maxHeapGrowth = 0;
        var exercised = new HashSet<string>(); var selectedSessions = new[] { "A", "B", "C" };
        for (var batch = 1; batch <= batches; batch++)
        {
            var desired = selectedSessions[(batch - 1) / 125 % 3]; var changed = selected != desired;
            if (changed) { selected = desired; exercised.Add(selected); await store.SelectSessionAsync(selected); await PumpUntil(
                () => store.State.Transcript.Tail is { } tail && tail.SessionID == selected && tail.Rows.Length == 200, clock, store); }
            var activeSession = selected ?? throw new InvalidOperationException("No session was selected.");
            var finalProgress = new EngineProgressPayload(EngineStage.ValidatingModels, progressUnits + (ulong)triplets, null, null);
            var outputs = new EngineOutput[batchSize];
            for (var i = 0; i < triplets; i++)
            {
                var revision = ++stateRevision; var offset = i * 3;
                outputs[offset] = new EngineOutput(1, new EngineID(++sequence), null, new EngineEvent.State(State(EngineSetupStatus.Ready, revision)));
                outputs[offset + 1] = new EngineOutput(1, new EngineID(++sequence), null, new EngineEvent.Progress(new EngineProgressPayload(EngineStage.ValidatingModels, ++progressUnits, null, null)));
                var row = Row($"delta-{batch:D4}-{i:D3}", 0, "delta");
                outputs[offset + 2] = new EngineOutput(1, new EngineID(++sequence), null, new EngineEvent.Rows(new EngineRowsPayload(activeSession, new EngineID(revision), EngineRowsKind.Changes, [row], [], null)));
            }
            var acknowledged = ChangedAfter(store, state => state.Progress == finalProgress);
            engine.EmitBatch(outputs); emitted += outputs.Length; await acknowledged; await store.SelectSessionAsync(activeSession);
            Assert.Equal(stateRevision, store.State.Engine!.Revision.Value); Assert.Equal(finalProgress, store.State.Progress);
            Assert.True(await store.ListSessionsAsync(batch == 1 ? ShellPageMove.Reload : ShellPageMove.Next));
            Assert.True(await store.ReadHistoryAsync(changed ? ShellPageMove.Reload : ShellPageMove.Next));
            var storeRows = RowsIn(store.State); var storeSessions = store.State.Sessions.Pages.Sum(page => page.Sessions.Length);
            var uiRows = RowsIn(context.State); var uiSessions = context.State.Sessions.Pages.Sum(page => page.Sessions.Length);
            Assert.InRange(storeRows, 0, 800); Assert.InRange(storeSessions, 0, 300);
            Assert.InRange(uiRows, 0, 800); Assert.InRange(uiSessions, 0, 300);
            historyHighWater = Math.Max(historyHighWater, storeRows); sessionsHighWater = Math.Max(sessionsHighWater, storeSessions);
            Assert.Equal(ShellPhase.Running, store.State.Phase); Assert.Null(store.State.StoreFailure);
            Assert.InRange(dispatcher.PendingCount, 0, 1); clock.Advance(TimeSpan.FromMilliseconds(25)); await Task.Yield();
            if (batch % 4 == 0 && dispatcher.PendingCount > 0) dispatcher.Run();
            if (batch % 200 == 0)
            {
                await PumpUntil(() => ReferenceEquals(context.State, store.State), clock, store, dispatcher);
                var heap = GC.GetTotalMemory(true);
                if (batch == 200) heapBaseline = heap;
                else { maxHeapGrowth = Math.Max(maxHeapGrowth, heap - heapBaseline); Assert.True(heap - heapBaseline < maxGrowth, $"Managed heap grew {heap - heapBaseline} bytes."); }
            }
        }
        var lastSession = selected ?? throw new InvalidOperationException("No session was selected.");
        await PumpUntil(() => store.State.Transcript.Tail is { } tail && tail.SessionID == lastSession && tail.Rows.Length == 200, clock, store);
        await PumpUntil(() => ReferenceEquals(context.State, store.State), clock, store, dispatcher);
        Assert.Equal(batches * batchSize, emitted); Assert.Equal(1_002_000L, emitted);
        Assert.Equal(200_000L, historyRowsCreated); Assert.Equal(3, exercised.Count);
        Assert.Equal(800, historyHighWater); Assert.Equal(300, sessionsHighWater);
        Assert.Equal(1, dispatcher.MaximumPending); Assert.Equal(dispatcher.RenderCount, renderTimes.Count);
        for (var i = 1; i < renderTimes.Count; i++) Assert.True(clock.GetElapsedTime(renderTimes[i - 1], renderTimes[i]) >= TimeSpan.FromMilliseconds(100));
        var elapsed = clock.GetElapsedTime(0, clock.GetTimestamp()); Assert.True(dispatcher.RenderCount <= elapsed.TotalMilliseconds / 100 + 1);
        Assert.Equal(ShellPhase.Running, store.State.Phase); Assert.Null(store.State.StoreFailure);
        context.Dispose(); await store.DisposeAsync(); stopwatch.Stop();
        TestContext.Current.TestOutputHelper!.WriteLine($"P5b-7c soak: {emitted:N0} outputs, {stopwatch.Elapsed.TotalSeconds:F2}s, {dispatcher.RenderCount} renders, managed heap growth {maxHeapGrowth:N0} bytes.");
        Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(60), $"Soak took {stopwatch.Elapsed.TotalSeconds:F2}s.");
    }

    private static long RowsIn(ShellState state) => state.Transcript.History.Pages.Sum(page => page.Rows.Length) + (state.Transcript.Tail?.Rows.Length ?? 0);

    private static async Task PumpUntil(Func<bool> ready, ManualClock clock, ShellStore store, TestDispatcher? dispatcher = null)
    {
        var wake = Channel.CreateBounded<bool>(new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.DropWrite,
            SingleReader = true,
            SingleWriter = false
        });
        EventHandler storeChanged = (_, _) => wake.Writer.TryWrite(true);
        Action timerScheduled = () => wake.Writer.TryWrite(true);
        store.Changed += storeChanged;
        clock.TimerScheduled += timerScheduled;
        try
        {
            while (!ready())
            {
                if (dispatcher is not null && dispatcher.PendingCount > 0) dispatcher.Run();
                if (ready()) break;
                if (clock.TryAdvanceToNextTimer()) continue;
                if (ready()) break;
                await wake.Reader.ReadAsync(TestContext.Current.CancellationToken).AsTask()
                    .WaitAsync(TimeSpan.FromSeconds(3), TestContext.Current.CancellationToken);
            }
        }
        finally
        {
            store.Changed -= storeChanged;
            clock.TimerScheduled -= timerScheduled;
        }
        Assert.True(ready());
    }
}
