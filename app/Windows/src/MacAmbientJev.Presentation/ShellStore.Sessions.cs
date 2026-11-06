using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public sealed partial class ShellStore
{
    internal static bool CanUseSavedSelection(ShellState state) => state.Phase == ShellPhase.Running && state.Engine is { Recording: null } &&
        !state.Pending.Contains(EngineCommandName.RecordingStart) && !state.Pending.Contains(EngineCommandName.RecordingStop) &&
        !state.Pending.Contains(EngineCommandName.SessionInspect) && !state.Pending.Contains(EngineCommandName.SessionReprocess) &&
        !state.Pending.Contains(EngineCommandName.SessionRetryDecisions) && !state.Pending.Contains(EngineCommandName.SessionExport);

    public Task<bool> InspectSessionAsync(string folderID)
    {
        ArgumentException.ThrowIfNullOrEmpty(folderID);
        return InspectSavedSessionAsync(folderID, false);
    }

    public Task<bool> SelectSavedSessionAsync(EngineSessionSummary session)
    {
        ArgumentNullException.ThrowIfNull(session);
        return InspectSavedSessionAsync(session.FolderID, false, session.DisplayName);
    }

    private Task<bool> InspectSavedSessionAsync(string folderID, bool refreshOnly, string? displayName = null)
    {
        long generation = 0;
        return RunRequestAsync(() =>
        {
            if (refreshOnly && _working.SelectedFolderID != folderID) return null;
            if (!CanUseSavedSelection(_working)) { _working = _working with { CommandError = "録音中または処理中は録音を選択できません。" }; return null; }
            _working = _working with { SelectedFolderID = folderID, SessionInspection = null };
            if (displayName is not null)
            {
                SelectSession(null, displayName, "保存済みの文字起こしを読み込んでいます");
                generation = _selectionGeneration;
            }
            return new EngineCommand.SessionInspect(new EngineSessionInspectPayload(folderID));
        }, (command, result) =>
        {
            if (result is not EngineResult.SessionInspect inspection || inspection.Result.FolderID != folderID)
                throw new InvalidOperationException("session.inspect returned an unexpected result or folder.");
            if (_working.SelectedFolderID != folderID) return;
            _working = _working with { SessionInspection = inspection.Result, CommandError = null };
            if (displayName is null || generation != _selectionGeneration) return;
            var summary = inspection.Result;
            if (summary.SessionID is null || summary.Metadata is not EngineSessionMetadata.Readable { Audio: EngineSessionAudio.Available } metadata)
                SelectSession(null, summary.DisplayName, "保存済み音声を使えないため、文字起こしを表示できません");
            else if (!metadata.HasTranscript)
                SelectSession(null, summary.DisplayName, "この録音には確定文字起こしがありません");
            else SelectSession(summary.SessionID, summary.DisplayName, isImported: metadata.Source is EngineSessionSource.Imported);
        }, (name, exception, admission) =>
        {
            if (displayName is not null && generation == _selectionGeneration)
                SelectSession(null, displayName, "保存済み文字起こしを読み込めませんでした");
            HandleRequestFailure(name, exception, admission);
        });
    }

    public Task<bool> ReprocessSessionAsync() => RunSavedSessionActionAsync(false);
    public Task<bool> RetrySessionDecisionsAsync() => RunSavedSessionActionAsync(true);

    public async Task<bool> ExportSessionAsync(string folderID, string destinationPath)
    {
        ArgumentException.ThrowIfNullOrEmpty(folderID); ArgumentException.ThrowIfNullOrEmpty(destinationPath);
        string? sessionID = null;
        var completed = await RunRequestAsync(() =>
        {
            var inspection = _working.SessionInspection;
            var inspectedSessionID = inspection?.SessionID;
            if (!CanUseSavedSelection(_working) || _working.ConfirmedSettings is null || _working.SelectedFolderID != folderID ||
                inspection is null || inspection.FolderID != folderID || inspectedSessionID is null || !inspection.CanExport)
            { _working = _working with { CommandError = "この録音を書き出せません。" }; return null; }
            sessionID = inspectedSessionID;
            return new EngineCommand.SessionExport(new EngineExportPayload(inspectedSessionID, destinationPath));
        }, (command, result) =>
        {
            if (result is not EngineResult.SessionExport exported || exported.Result.SessionID != sessionID)
                throw new InvalidOperationException("session.export returned an unexpected result or session.");
            _working = _working with { CommandError = null };
        }, HandleRequestFailure).ConfigureAwait(false);
        return completed && await InspectSavedSessionAsync(folderID, true).ConfigureAwait(false);
    }

    private async Task<bool> RunSavedSessionActionAsync(bool retry)
    {
        string? folderID = null, sessionID = null;
        var completed = await RunRequestAsync(() =>
        {
            var selectedFolderID = _working.SelectedFolderID;
            var inspection = _working.SessionInspection;
            var inspectedSessionID = inspection?.SessionID;
            if (!CanUseSavedSelection(_working) || selectedFolderID is null || inspectedSessionID is null ||
                inspection!.FolderID != selectedFolderID || (retry ? !inspection.CanRetryDecisions : !inspection.CanReprocess))
            { _working = _working with { CommandError = "この録音では操作できません。" }; return null; }
            folderID = selectedFolderID;
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
        }, HandleRequestFailure).ConfigureAwait(false);
        return completed && await InspectSavedSessionAsync(folderID!, true).ConfigureAwait(false);
    }

    public Task ReportCommandErrorAsync(string message)
    {
        ArgumentException.ThrowIfNullOrEmpty(message);
        return Post(() => _working = _working with { CommandError = message });
    }
}
