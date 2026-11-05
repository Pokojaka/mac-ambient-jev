using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public sealed partial class ShellStore
{
    // These flags are reducer-owned. The task is also observed by disposal.
    private bool _sessionsVisible, _sessionsDirty, _sessionsRefreshWorkerScheduled;
    private Task? _sessionsRefreshTask;

    public Task SetSessionsVisibleAsync(bool visible) => Post(() =>
    {
        if (_sessionsVisible == visible) return;
        _sessionsVisible = visible;
        if (visible) InvalidateSessions();
        else _sessionsDirty = false;
    });

    private void InvalidateSessions()
    {
        if (!_sessionsVisible) return;
        _sessionsDirty = true;
        EnsureSessionsRefreshWorker();
    }

    private void ObserveSessionChanges(EngineState? previous, EngineState next)
    {
        if (previous is null || previous.Recording != next.Recording || previous.Recovery != next.Recovery ||
            !previous.Queue.SequenceEqual(next.Queue) || !previous.Failures.SequenceEqual(next.Failures))
            InvalidateSessions();
    }

    private bool CanRefreshSessions() => !_stop.IsCancellationRequested && _sessionsVisible && _sessionsDirty &&
        _working.Phase == ShellPhase.Running && !_working.Pending.Contains(EngineCommandName.SessionList);

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
