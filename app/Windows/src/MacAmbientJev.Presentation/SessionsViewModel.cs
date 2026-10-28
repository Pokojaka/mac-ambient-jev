using System.Globalization;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public interface IFolderRevealer { Task RevealAsync(string path); }
public interface IPathPicker { Task<string?> PickAudioFileAsync(); Task<string?> PickExportFolderAsync(); }

public sealed class SessionsViewModel : ScreenViewModel
{
    private readonly IFolderRevealer _folderRevealer;

    public SessionsViewModel(ShellUiContext context, IFolderRevealer folderRevealer) : base(context)
    {
        _folderRevealer = folderRevealer ?? throw new ArgumentNullException(nameof(folderRevealer));
        List = Command(CanList, parameter => ListAsync((ShellPageMove)parameter!));
        Select = Command(CanSelect, parameter => Context.Store.InspectSessionAsync(((EngineSessionSummary)parameter!).FolderID));
        Reprocess = Command(parameter => CanRunAction(parameter, true), _ => Context.Store.ReprocessSessionAsync());
        RetryDecisions = Command(parameter => CanRunAction(parameter, false), _ => Context.Store.RetrySessionDecisionsAsync());
        RevealFolder = Command(CanRevealFolder, _ => RevealAsync(false));
        Export = Command(CanExport, ExportAsync);
        RevealExportFolder = Command(CanRevealExportFolder, _ => RevealAsync(true));
    }

    public ShellPageWindow<EngineSessionListResult> Pages => Snapshot.Sessions;
    public EngineSessionSummary? Inspection => Snapshot.SessionInspection;
    public string? SelectedFolderID => Snapshot.SelectedFolderID;
    public bool HasInspection => Inspection is not null;
    public bool CanSelectSession => ShellStore.CanUseSavedSelection(Context.Store.State);
    public bool IsBusy => Snapshot.IsPending(EngineCommandName.SessionList) || Snapshot.IsPending(EngineCommandName.SessionInspect) || Snapshot.IsPending(EngineCommandName.SessionReprocess) || Snapshot.IsPending(EngineCommandName.SessionRetryDecisions) || Snapshot.IsPending(EngineCommandName.SessionExport);
    public string? SelectionDisabledReason => CanSelectSession ? null : "録音中または処理中は録音を選択できません。";
    public string? ActionDisabledReason => ShellStore.CanUseSavedSelection(Context.Store.State) ? Inspection?.StatusText : "録音中または処理中は録音を選択できません。";
    public string? ExportDisabledReason
    {
        get
        {
            var state = Snapshot; var inspection = state.SessionInspection;
            return state.ConfirmedSettings is null ? "設定を保存してから書き出してください。" :
                state.Phase != ShellPhase.Running ? "エンジンの起動後に書き出してください。" :
                state.IsPending(EngineCommandName.SettingsGet) || state.IsPending(EngineCommandName.SettingsReplace) ? "設定の読み込みまたは保存中は書き出せません。" :
                Export.Execution is { IsCompleted: false } ? "書き出し中です。" :
                !ShellStore.CanUseSavedSelection(state) ? "録音中または処理中は録音を書き出せません。" :
                state.SelectedFolderID is not { } folderID || inspection is null || inspection.FolderID != folderID ? "書き出す録音を選択してください。" :
                inspection.SessionID is null || !inspection.CanExport ? inspection.StatusText : null;
        }
    }
    public string? MetadataText => Inspection is null ? null : FormatMetadata(Inspection.Metadata);
    public string Title => "保存済み録音"; public string RefreshLabel => "更新";
    public string ExportLabel => Snapshot.ConfirmedSettings?.Settings.ExportDestinationPath is null ? "書き出す…" : "書き出す";
    public string RevealExportFolderLabel => "書き出し先をエクスプローラーで表示";
    public string EmptyTitle => "録音を選択してください"; public string EmptyDescription => "選んだ録音の処理状態を確認できます。";
    public string ReprocessLabel => "再処理"; public string RetryDecisionsLabel => "保留中の判定を再試行";
    public string RevealFolderLabel => "録音データをエクスプローラーで表示";
    public ShellCommand List { get; } public ShellCommand Select { get; } public ShellCommand Reprocess { get; } public ShellCommand RetryDecisions { get; } public ShellCommand RevealFolder { get; }
    public ShellCommand Export { get; } public ShellCommand RevealExportFolder { get; }

    private bool CanList(object? parameter)
    {
        if (parameter is not ShellPageMove move) return false;
        var state = Context.Store.State;
        if (state.IsPending(EngineCommandName.SessionList)) return false;
        if (move == ShellPageMove.Reload) return true;
        var page = state.Sessions.Current;
        return move switch
        {
            ShellPageMove.Next => page?.NextCursor is not null,
            ShellPageMove.Previous => page?.PreviousCursor is not null,
            _ => false
        };
    }

    private async Task ListAsync(ShellPageMove move)
    {
        if (await Context.Store.ListSessionsAsync(move) && move == ShellPageMove.Reload)
        {
            var state = Context.Store.State;
            if (state.SelectedFolderID is { } folderID && ShellStore.CanUseSavedSelection(state))
                await Context.Store.InspectSessionAsync(folderID);
        }
    }

    private bool CanSelect(object? parameter) => parameter is EngineSessionSummary && ShellStore.CanUseSavedSelection(Context.Store.State);

    private bool CanRunAction(object? parameter, bool reprocess)
    {
        if (parameter is not null) return false;
        var state = Context.Store.State;
        var inspection = state.SessionInspection;
        return ShellStore.CanUseSavedSelection(state) && state.SelectedFolderID is { } folderID &&
            inspection is { SessionID: not null } && inspection.FolderID == folderID &&
            (reprocess ? inspection.CanReprocess : inspection.CanRetryDecisions);
    }

    private bool CanExport(object? parameter) => parameter is IPathPicker && ExportDisabledReason is null;

    private async Task ExportAsync(object? parameter)
    {
        var picker = (IPathPicker)parameter!;
        var state = Context.Store.State;
        var folderID = state.SelectedFolderID!;
        var path = state.ConfirmedSettings!.Settings.ExportDestinationPath;
        if (path is not null) { await Context.Store.ExportSessionAsync(folderID, path); return; }
        try { path = await picker.PickExportFolderAsync(); }
        catch (Exception exception) { await Context.Store.ReportCommandErrorAsync(exception.Message); return; }
        if (path is null || !await Context.Store.SetExportDestinationAsync(path)) return;
        await Context.Store.ExportSessionAsync(folderID, path);
    }

    private bool CanRevealFolder(object? parameter) => parameter is null && Context.Store.State.SessionInspection is not null;
    private bool CanRevealExportFolder(object? parameter) => parameter is null && Context.Store.State.SessionInspection?.ExportPath is not null;

    private async Task RevealAsync(bool export)
    {
        try
        {
            var inspection = Context.Store.State.SessionInspection ?? throw new InvalidOperationException("There is no inspected session folder to reveal.");
            await _folderRevealer.RevealAsync(export ? inspection.ExportPath ?? throw new InvalidOperationException("There is no inspected session export folder to reveal.") : inspection.FolderPath);
        }
        catch (Exception exception) { await Context.Store.ReportCommandErrorAsync(exception.Message); }
    }

    private static string FormatMetadata(EngineSessionMetadata metadata) => metadata switch
    {
        EngineSessionMetadata.Unreadable unreadable => unreadable.Reason,
        EngineSessionMetadata.Readable readable => string.Join("\n",
            $"作成日時: {DateTimeOffset.UnixEpoch.AddSeconds(readable.CreatedAt).ToLocalTime().ToString("g", CultureInfo.CurrentCulture)}",
            $"種類: {FormatSource(readable.Source)}",
            $"保存済み音声: {FormatAudio(readable.Audio)}",
            $"文字起こし: {(readable.HasTranscript ? "あり" : "なし")}"),
        _ => throw new InvalidOperationException("Unknown session metadata.")
    };

    private static string FormatSource(EngineSessionSource source) => source switch
    {
        EngineSessionSource.Microphone => "マイク",
        EngineSessionSource.SystemAudio => "システム音声",
        EngineSessionSource.Imported imported => "読み込み: " + imported.OriginalFilename,
        _ => throw new InvalidOperationException("Unknown session source.")
    };

    private static string FormatAudio(EngineSessionAudio audio) => audio switch
    {
        EngineSessionAudio.Available => "あり",
        EngineSessionAudio.Missing => "なし",
        EngineSessionAudio.Unreadable unreadable => unreadable.Reason,
        _ => throw new InvalidOperationException("Unknown session audio state.")
    };
}
