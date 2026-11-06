using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public sealed partial class ShellStore
{
    // These flags are reducer-owned. The task is also observed by disposal.
    private bool _sessionsVisible, _sessionsDirty, _sessionsRefreshWorkerScheduled;
    private string? _importDisplayNameSessionID;
    private Task? _sessionsRefreshTask;

    public Task SetSessionsVisibleAsync(bool visible) => Post(() =>
    {
        if (_sessionsVisible == visible) return;
        _sessionsVisible = visible;
        if (visible) InvalidateSessions();
        else _sessionsDirty = _importDisplayNameSessionID is not null;
    });

    private void InvalidateSessions()
    {
        if (!_sessionsVisible && _importDisplayNameSessionID is null) return;
        _sessionsDirty = true;
        EnsureSessionsRefreshWorker();
    }

    private void ObserveSessionChanges(EngineState? previous, EngineState next)
    {
        if (previous is null || previous.Recording != next.Recording || previous.Recovery != next.Recovery ||
            !previous.Queue.SequenceEqual(next.Queue) || !FailuresEqual(previous.Failures, next.Failures))
            InvalidateSessions();
    }

    private static bool FailuresEqual(EngineFailure[] previous, EngineFailure[] next)
    {
        if (previous.Length != next.Length) return false;
        for (var index = 0; index < previous.Length; index++)
        {
            var left = previous[index];
            var right = next[index];
            if (left.Code != right.Code || left.Message != right.Message || left.Stage != right.Stage ||
                left.RequestID != right.RequestID || left.SessionID != right.SessionID || left.Severity != right.Severity ||
                left.RecoveryAction != right.RecoveryAction || !left.Details.SequenceEqual(right.Details) ||
                !left.CleanupErrors.SequenceEqual(right.CleanupErrors))
                return false;
        }
        return true;
    }

    private bool CanRefreshSessions() => !_stop.IsCancellationRequested && (_sessionsVisible || _importDisplayNameSessionID is not null) && _sessionsDirty &&
        _working.Phase == ShellPhase.Running && !_working.Pending.Contains(EngineCommandName.SessionList);

    private void ResolveImportedDisplayName(EngineSessionListResult result)
    {
        if (_importDisplayNameSessionID is not { } sessionID) return;
        var summary = result.Sessions.SingleOrDefault(item => StringComparer.Ordinal.Equals(item.SessionID, sessionID));
        if (summary is null)
        {
            if (!_sessionsDirty)
                throw new InvalidOperationException($"session.list did not return imported session '{sessionID}'.");
            return;
        }

        _importDisplayNameSessionID = null;
        if (_working.Transcript.SessionID == sessionID)
            SelectSession(sessionID, summary.DisplayName, isImported: true);
    }

    private void EnsureSessionsRefreshWorker()
    {
        if (_sessionsRefreshWorkerScheduled || !CanRefreshSessions()) return;
        _sessionsRefreshWorkerScheduled = true;
        _sessionsRefreshTask = Task.Run(SessionsRefreshWorkerAsync);
    }

    // Invoked inside ListSessionsAsync's reducer admission, not before its queued work.
    // A manual list request or a visibility change can otherwise win that gap.
    private bool TryBeginSessionsRefresh()
    {
        if (!CanRefreshSessions()) return false;
        _sessionsDirty = false;
        return true;
    }

    private async Task SessionsRefreshWorkerAsync()
    {
        try
        {
            while (true)
            {
                await ListSessionsAsync(ShellPageMove.Reload, TryBeginSessionsRefresh).ConfigureAwait(false);
                var again = false;
                await Post(() => again = CanRefreshSessions()).ConfigureAwait(false);
                if (!again) return;
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
                    _sessionsRefreshWorkerScheduled = false;
                    EnsureSessionsRefreshWorker();
                }).ConfigureAwait(false);
            }
            catch (ObjectDisposedException) when (_stop.IsCancellationRequested) { }
        }
    }
}
