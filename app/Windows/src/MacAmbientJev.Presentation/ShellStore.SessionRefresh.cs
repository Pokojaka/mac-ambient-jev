using MacAmbientJev.EngineClient;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public sealed partial class ShellStore
{
    // These flags are reducer-owned. The task is also observed by disposal.
    private bool _sessionsVisible, _sessionsDirty, _sessionsRefreshWorkerScheduled;
    private bool _selectedInspectionDirty, _selectedInspectionRefreshWorkerScheduled;
    private ulong _selectedInspectionGeneration;
    private string? _importDisplayNameSessionID;
    private Task? _sessionsRefreshTask, _selectedInspectionRefreshTask;

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
        var preparationChanged = previous is not null &&
            previous.Presentation.PreparationPhase != next.Presentation.PreparationPhase;
        var stateFailuresChanged = previous is not null && !FailuresEqual(previous.Failures, next.Failures);
        var sessionListChanged = previous is null || previous.Recording != next.Recording || previous.Recovery != next.Recovery ||
            !previous.Queue.SequenceEqual(next.Queue) || stateFailuresChanged || preparationChanged;
        if (sessionListChanged) InvalidateSessions();
        if (sessionListChanged) RefreshSelectedInspection();
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

    private void RefreshSelectedInspection()
    {
        _selectedInspectionDirty = true;
        EnsureSelectedInspectionRefreshWorker();
    }

    private void CancelSelectedInspectionRefresh()
    {
        _selectedInspectionDirty = false;
        _selectedInspectionGeneration = checked(_selectedInspectionGeneration + 1);
    }

    private bool CanRefreshSelectedInspection() => !_stop.IsCancellationRequested && _selectedInspectionDirty &&
        _working.Phase == ShellPhase.Running && _working.SelectedFolderID is not null &&
        !_working.Pending.Contains(EngineCommandName.SessionInspect) && CanUseSavedSelection(_working);

    private void EnsureSelectedInspectionRefreshWorker()
    {
        if (_selectedInspectionRefreshWorkerScheduled || !CanRefreshSelectedInspection()) return;
        _selectedInspectionRefreshWorkerScheduled = true;
        _selectedInspectionRefreshTask = Task.Run(SelectedInspectionRefreshWorkerAsync);
    }

    private async Task SelectedInspectionRefreshWorkerAsync()
    {
        try
        {
            while (await StartSelectedInspectionRefreshAsync().ConfigureAwait(false))
            {
                var again = false;
                await Post(() => again = CanRefreshSelectedInspection()).ConfigureAwait(false);
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
                    _selectedInspectionRefreshWorkerScheduled = false;
                    EnsureSelectedInspectionRefreshWorker();
                }).ConfigureAwait(false);
            }
            catch (ObjectDisposedException) when (_stop.IsCancellationRequested) { }
        }
    }

    private async Task<bool> StartSelectedInspectionRefreshAsync()
    {
        string? folderID = null;
        ulong generation = 0;
        var started = false;
        await RunRequestAsync(() =>
        {
            if (!CanRefreshSelectedInspection()) return null;
            folderID = _working.SelectedFolderID;
            if (folderID is null) return null;

            generation = _selectedInspectionGeneration;
            _selectedInspectionDirty = false;
            started = true;
            _working = _working with { SessionInspection = null };
            return new EngineCommand.SessionInspect(new EngineSessionInspectPayload(folderID));
        }, (command, response) =>
        {
            if (generation != _selectedInspectionGeneration) return;
            if (response is not EngineResult.SessionInspect inspection || inspection.Result.FolderID != folderID)
                throw new InvalidOperationException("session.inspect returned an unexpected result or folder.");
            if (_working.SelectedFolderID == folderID)
            {
                _working = _working with { SessionInspection = inspection.Result };
                if (inspection.Result.SessionID is not null &&
                    inspection.Result.Metadata is EngineSessionMetadata.Readable { Audio: EngineSessionAudio.Available, HasTranscript: true } &&
                    _working.Transcript.SessionID is null &&
                    _working.Transcript.UnavailableReason is NoTranscriptReason or UnavailableAudioReason)
                    SelectInspectedTranscript(inspection.Result, clearCommandError: false);
            }
        }, (name, exception, admission) =>
        {
            if (exception is EngineRequestException && generation != _selectedInspectionGeneration)
            {
                RemovePending(name);
                return;
            }
            HandleRequestFailure(name, exception, admission);
        }, clearCommandErrorOnAdmission: false).ConfigureAwait(false);
        return started;
    }

    private void ResolveImportedDisplayName(EngineSessionListResult result)
    {
        if (_working.Phase != ShellPhase.Running) return;
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
            SelectSession(sessionID, clearCommandError: false, displayName: summary.DisplayName, isImported: true);
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
