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

    private Task<bool> InspectSavedSessionAsync(string folderID, bool refreshOnly) => RunRequestAsync(() =>
    {
        if (refreshOnly && _working.SelectedFolderID != folderID) return null;
        if (!CanUseSavedSelection(_working)) { _working = _working with { CommandError = "録音中または処理中は録音を選択できません。" }; return null; }
        _working = _working with { SelectedFolderID = folderID, SessionInspection = null };
        return new EngineCommand.SessionInspect(new EngineSessionInspectPayload(folderID));
    }, (command, result) =>
    {
        if (result is not EngineResult.SessionInspect inspection || inspection.Result.FolderID != folderID)
            throw new InvalidOperationException("session.inspect returned an unexpected result or folder.");
        _working = _working with { SessionInspection = inspection.Result, CommandError = null };
    }, HandleRequestFailure);

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
