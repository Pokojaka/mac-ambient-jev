using MacAmbientJev.EngineClient;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public sealed partial class ShellStore
{
    private static readonly TimeSpan TailRefreshInterval = TimeSpan.FromMilliseconds(250);
    private long _selectionGeneration, _historyEpoch;
    private long? _tailLastStart;
    private bool _tailDirty, _tailWorkerScheduled;
    private Task? _tailTask;

    public Task SelectSessionAsync(string sessionID)
    {
        ArgumentException.ThrowIfNullOrEmpty(sessionID);
        return Post(() =>
        {
            var current = _working.Transcript;
            if (current.SessionID == sessionID) return;
            if (_working.Phase != ShellPhase.Running) { _working = _working with { CommandError = "The engine is not running." }; return; }
            _selectionGeneration = checked(_selectionGeneration + 1);
            _historyEpoch = checked(_historyEpoch + 1);
            _working = _working with { Transcript = new ShellTranscriptState { SessionID = sessionID, Follow = current.Follow }, CommandError = null };
            _tailDirty = true;
            EnsureTailWorker();
        });
    }

    public Task UserScrolledAsync() => Post(() =>
        _working = _working with { Transcript = _working.Transcript with { Follow = false } });

    public Task ReturnToLatestAsync() => Post(() =>
    {
        if (_working.Transcript.SessionID is null || _working.Phase != ShellPhase.Running)
        { _working = _working with { CommandError = "Select a session while the engine is running." }; return; }
        _working = _working with { Transcript = _working.Transcript with { Follow = true, NewUpdatesAvailable = false }, CommandError = null };
        _tailDirty = true;
        EnsureTailWorker();
    });

    public Task<bool> ReadHistoryAsync(ShellPageMove move)
    {
        ValidateMove(move);
        string? sessionID = null;
        EngineID? requestedRevision = null;
        string? cursor = null;
        long generation = 0, epoch = 0;
        return RunRequestAsync(() =>
        {
            if (_working.Phase != ShellPhase.Running) { _working = _working with { CommandError = "The engine is not running." }; return null; }
            var transcript = _working.Transcript;
            if (transcript.SessionID is null) { _working = _working with { CommandError = "Select a session before reading transcript history." }; return null; }
            if (move != ShellPageMove.Reload)
            {
                var page = transcript.History.Current;
                if (transcript.HistoryStale || page is null || page.SessionID != transcript.SessionID)
                { _working = _working with { CommandError = "Reload transcript history before navigating." }; return null; }
                requestedRevision = page.Revision;
                cursor = move == ShellPageMove.Next ? page.NextCursor : page.PreviousCursor;
                if (cursor is null)
                { _working = _working with { CommandError = $"There is no {move.ToString().ToLowerInvariant()} transcript page." }; return null; }
            }
            sessionID = transcript.SessionID;
            generation = _selectionGeneration;
            epoch = _historyEpoch;
            return new EngineCommand.TranscriptRead(new EngineTranscriptReadPayload(sessionID, requestedRevision, cursor, 200));
        }, (command, result) =>
        {
            if (result is not EngineResult.TranscriptRead read) throw new InvalidOperationException("transcript.read returned an unexpected result type.");
            var page = read.Result;
            if (page.SessionID != sessionID) throw new InvalidOperationException("transcript.read returned a page for another session.");
            if (requestedRevision is EngineID revision && page.Revision != revision)
                throw new InvalidOperationException("transcript.read continuation returned another revision.");
            if (generation != _selectionGeneration || epoch != _historyEpoch) return;
            var transcript = _working.Transcript;
            _working = _working with { Transcript = transcript with { History = transcript.History.Apply(page, move), HistoryStale = move == ShellPageMove.Reload ? false : transcript.HistoryStale }, CommandError = null };
        }, (name, exception, admission) =>
        {
            if (exception is EngineRequestException && (generation != _selectionGeneration || epoch != _historyEpoch))
            { RemovePending(name); return; }
            if (exception is EngineRequestException { Failure.Code: EngineErrorCode.StaleRevision })
                _working = _working with { Transcript = _working.Transcript with { HistoryStale = true } };
            HandleRequestFailure(name, exception, admission);
        });
    }

    public Task<bool> ListSessionsAsync(ShellPageMove move)
    {
        ValidateMove(move);
        string? cursor = null;
        return RunRequestAsync(() =>
        {
            if (_working.Phase != ShellPhase.Running) { _working = _working with { CommandError = "The engine is not running." }; return null; }
            if (move != ShellPageMove.Reload)
            {
                var page = _working.Sessions.Current;
                cursor = move == ShellPageMove.Next ? page?.NextCursor : page?.PreviousCursor;
                if (cursor is null)
                { _working = _working with { CommandError = $"There is no {move.ToString().ToLowerInvariant()} session page." }; return null; }
            }
            return new EngineCommand.SessionList(new EngineSessionListPayload(cursor, 100));
        }, (command, result) =>
        {
            if (result is not EngineResult.SessionList list) throw new InvalidOperationException("session.list returned an unexpected result type.");
            _working = _working with { Sessions = _working.Sessions.Apply(list.Result, move), CommandError = null };
        }, HandleRequestFailure);
    }

    private static void ValidateMove(ShellPageMove move)
    {
        if (move is not (ShellPageMove.Reload or ShellPageMove.Next or ShellPageMove.Previous))
            throw new ArgumentOutOfRangeException(nameof(move), move, "Unknown page move.");
    }

    private void ReduceRows(EngineRowsPayload payload)
    {
        var transcript = _working.Transcript;
        if (transcript.SessionID != payload.SessionID) return;
        if (!transcript.Follow) transcript = transcript with { NewUpdatesAvailable = true };
        if (payload.Kind == EngineRowsKind.ReloadRequired)
        {
            _historyEpoch = checked(_historyEpoch + 1);
            if (transcript.History.Pages.Length != 0 || _working.Pending.Contains(EngineCommandName.TranscriptRead))
                transcript = transcript with { HistoryStale = true };
        }
        _working = _working with { Transcript = transcript };
        _tailDirty = true;
        EnsureTailWorker();
    }

    private void EnsureTailWorker()
    {
        if (_stop.IsCancellationRequested || !_tailDirty || _tailWorkerScheduled ||
            _working.Transcript.SessionID is null || _working.Phase != ShellPhase.Running) return;
        _tailWorkerScheduled = true;
        _tailTask = Task.Run(TailWorkerAsync);
    }

    private async Task TailWorkerAsync()
    {
        try
        {
            while (true)
            {
                TimeSpan delay = TimeSpan.Zero;
                var eligible = false;
                await Post(() =>
                {
                    eligible = _tailDirty && _working.Transcript.SessionID is not null && _working.Phase == ShellPhase.Running;
                    if (!eligible || _tailLastStart is not long last) return;
                    var elapsed = _timeProvider.GetElapsedTime(last, _timeProvider.GetTimestamp());
                    if (elapsed < TailRefreshInterval) delay = TailRefreshInterval - elapsed;
                }).ConfigureAwait(false);
                if (!eligible) return;
                if (delay > TimeSpan.Zero) await Task.Delay(delay, _timeProvider, _stop.Token).ConfigureAwait(false);

                var admitted = false;
                string? sessionID = null;
                long generation = 0;
                await RunRequestAsync(() =>
                {
                    if (!_tailDirty || _working.Transcript.SessionID is null || _working.Phase != ShellPhase.Running) return null;
                    var timestamp = _timeProvider.GetTimestamp();
                    if (_tailLastStart is long previous && _timeProvider.GetElapsedTime(previous, timestamp) < TailRefreshInterval) return null;
                    _tailDirty = false;
                    _tailLastStart = timestamp;
                    generation = _selectionGeneration;
                    sessionID = _working.Transcript.SessionID;
                    admitted = true;
                    return new EngineCommand.TranscriptWatch(new EngineSessionPayload(sessionID));
                }, (command, result) =>
                {
                    if (result is not EngineResult.TranscriptWatch watch) throw new InvalidOperationException("transcript.watch returned an unexpected result type.");
                    var page = watch.Result;
                    if (page.SessionID != sessionID || page.NextCursor is not null || page.PreviousCursor is not null)
                        throw new InvalidOperationException("transcript.watch returned an invalid session or cursor.");
                    if (generation != _selectionGeneration || sessionID != _working.Transcript.SessionID) return;
                    _working = _working with { Transcript = _working.Transcript with { Tail = page } };
                }, (name, exception, admission) =>
                {
                    if (exception is EngineRequestException && generation != _selectionGeneration)
                    { RemovePending(name); return; }
                    HandleRequestFailure(name, exception, admission);
                }).ConfigureAwait(false);
                if (!admitted) continue;
            }
        }
        catch (OperationCanceledException) when (_stop.IsCancellationRequested) { }
        catch (ObjectDisposedException) when (_stop.IsCancellationRequested) { }
        catch (Exception exception)
        {
            try { await Post(() => FailStore(exception)).ConfigureAwait(false); }
            catch (ObjectDisposedException) when (_stop.IsCancellationRequested) { }
        }
        finally
        {
            try
            {
                await Post(() =>
                {
                    _tailWorkerScheduled = false;
                    EnsureTailWorker();
                }).ConfigureAwait(false);
            }
            catch (ObjectDisposedException) when (_stop.IsCancellationRequested) { }
        }
    }
}
