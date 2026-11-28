using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public sealed partial class ShellStore
{
    internal static bool CanUseSavedSelection(ShellState state) => state.Phase == ShellPhase.Running && state.Engine is { Recording: null } &&
        !state.Pending.Contains(EngineCommandName.RecordingStart) && !state.Pending.Contains(EngineCommandName.RecordingStop) &&
        !state.Pending.Contains(EngineCommandName.SessionInspect) && !state.Pending.Contains(EngineCommandName.SessionReprocess) &&
        !state.Pending.Contains(EngineCommandName.SessionRetryDecisions) && !state.Pending.Contains(EngineCommandName.SessionExport);

    public Task<bool> SelectSavedSessionAsync(EngineSessionSummary session)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentException.ThrowIfNullOrEmpty(session.FolderID);
        var folderID = session.FolderID;
        var displayName = session.DisplayName;
        long generation = 0;
        return RunRequestAsync(() =>
        {
            if (!CanUseSavedSelection(_working)) { _working = _working with { CommandError = "録音中または処理中は録音を選択できません。" }; return null; }
            CancelSelectedInspectionRefresh();
            _working = _working with { SelectedFolderID = folderID, SessionInspection = null };
            SelectSession(null, clearCommandError: true, displayName: displayName, unavailableReason: "保存済みの文字起こしを読み込んでいます");
            generation = _selectionGeneration;
            return new EngineCommand.SessionInspect(new EngineSessionInspectPayload(folderID));
        }, (command, result) =>
        {
            if (result is not EngineResult.SessionInspect inspection || inspection.Result.FolderID != folderID)
                throw new InvalidOperationException("session.inspect returned an unexpected result or folder.");
            if (_working.SelectedFolderID != folderID) return;
            _working = _working with { SessionInspection = inspection.Result, CommandError = null };
            if (generation != _selectionGeneration) return;
            SelectInspectedTranscript(inspection.Result, clearCommandError: true);
        }, (name, exception, admission) =>
        {
            if (generation == _selectionGeneration)
                SelectSession(null, clearCommandError: true, displayName: displayName,
                    unavailableReason: "保存済み文字起こしを読み込めませんでした");
            HandleRequestFailure(name, exception, admission);
        });
    }

    private const string NoTranscriptReason = "この録音には確定文字起こしがありません";
    private const string UnavailableAudioReason = "保存済み音声を使えないため、文字起こしを表示できません";

    private void SelectInspectedTranscript(EngineSessionSummary summary, bool clearCommandError)
    {
        if (summary.SessionID is null || summary.Metadata is not EngineSessionMetadata.Readable { Audio: EngineSessionAudio.Available } metadata)
            SelectSession(null, clearCommandError, displayName: summary.DisplayName, unavailableReason: UnavailableAudioReason);
        else if (!metadata.HasTranscript)
            SelectSession(null, clearCommandError, displayName: summary.DisplayName, unavailableReason: NoTranscriptReason);
        else
            SelectSession(summary.SessionID, clearCommandError, displayName: summary.DisplayName,
                isImported: metadata.Source is EngineSessionSource.Imported);
    }

    public Task<bool> ReprocessSessionAsync() => RunSavedSessionActionAsync(false);
    public Task<bool> RetrySessionDecisionsAsync() => RunSavedSessionActionAsync(true);

    public async Task<bool> ExportSessionAsync(string folderID, string destinationPath)
    {
        ArgumentException.ThrowIfNullOrEmpty(folderID); ArgumentException.ThrowIfNullOrEmpty(destinationPath);
        string? sessionID = null;
        await Post(() =>
        {
            var inspection = _working.SessionInspection;
            var inspectedSessionID = inspection?.SessionID;
            if (!CanUseSavedSelection(_working) || _working.ConfirmedSettings is null || _working.SelectedFolderID != folderID ||
                inspection is null || inspection.FolderID != folderID || inspectedSessionID is null || !inspection.CanExport)
            { _working = _working with { CommandError = "この録音を書き出せません。" }; return; }
            sessionID = inspectedSessionID;
        }).ConfigureAwait(false);
        if (sessionID is null) return false;
        return await ExportSessionCoreAsync(folderID, sessionID, destinationPath).ConfigureAwait(false);
    }

    private async Task<bool> ExportSessionCoreAsync(string folderID, string sessionID, string destinationPath)
    {
        var completed = await RunRequestAsync(() =>
        {
            if (_working.SelectedFolderID != folderID || _working.Engine is not { Recording: null } ||
                _working.Pending.Contains(EngineCommandName.RecordingStart) ||
                _working.Pending.Contains(EngineCommandName.RecordingStop) ||
                _working.Pending.Contains(EngineCommandName.SessionReprocess) ||
                _working.Pending.Contains(EngineCommandName.SessionRetryDecisions) ||
                _working.Pending.Contains(EngineCommandName.SessionExport))
            { _working = _working with { CommandError = "この録音を書き出せません。" }; return null; }
            return new EngineCommand.SessionExport(new EngineExportPayload(sessionID, destinationPath));
        }, (command, result) =>
        {
            if (result is not EngineResult.SessionExport exported || exported.Result.SessionID != sessionID)
                throw new InvalidOperationException("session.export returned an unexpected result or session.");
            _working = _working with { CommandError = null };
            RefreshSelectedInspection();
        }, HandleRequestFailure).ConfigureAwait(false);
        return completed;
    }

    private async Task<bool> RunSavedSessionActionAsync(bool retry)
    {
        string? sessionID = null;
        var completed = await RunRequestAsync(() =>
        {
            var selectedFolderID = _working.SelectedFolderID;
            var inspection = _working.SessionInspection;
            var inspectedSessionID = inspection?.SessionID;
            if (!CanUseSavedSelection(_working) || selectedFolderID is null || inspectedSessionID is null ||
                inspection!.FolderID != selectedFolderID || (retry ? !inspection.CanRetryDecisions : !inspection.CanReprocess))
            { _working = _working with { CommandError = "この録音では操作できません。" }; return null; }
            sessionID = inspectedSessionID;
            var payload = new EngineSessionPayload(inspectedSessionID);
            return retry ? new EngineCommand.SessionRetryDecisions(payload) : new EngineCommand.SessionReprocess(payload);
        }, (command, result) =>
        {
            if (retry)
            {
                if (result is not EngineResult.SessionRetryDecisions retried || retried.Result.SessionID != sessionID)
                    throw new InvalidOperationException("session.retry_decisions returned an unexpected result or session.");
            }
            else if (result is not EngineResult.SessionReprocess reprocessed || reprocessed.Result.SessionID != sessionID)
                throw new InvalidOperationException("session.reprocess returned an unexpected result or session.");
            _working = _working with { CommandError = null };
            RefreshSelectedInspection();
        }, HandleRequestFailure).ConfigureAwait(false);
        return completed;
    }

    public Task ReportCommandErrorAsync(string message)
    {
        ArgumentException.ThrowIfNullOrEmpty(message);
        return Post(() => _working = _working with { CommandError = message });
    }
}
