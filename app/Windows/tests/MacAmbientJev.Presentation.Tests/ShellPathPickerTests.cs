using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Presentation.Tests;

public sealed partial class ShellStoreTests
{
    [Theory]
    [InlineData(null)]
    [InlineData(@"C:\利用者\音声\会議 🎙.wav")]
    public async Task ImportPickedPathOrCancel(string? path)
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock); var live = new LiveViewModel(context);
        var picker = new TestPathPicker(path, null); var sent = engine.SentCount;
        live.ImportAudio.Execute(picker); var execution = live.ImportAudio.Execution!; Assert.Equal(1, picker.AudioCalls);
        if (path is null) { await execution; Assert.Equal(sent, engine.SentCount); return; }
        var request = await engine.NextRequestAsync(); await ChangedTo(store, state => state.IsPending(EngineCommandName.SessionImport));
        Assert.Equal(path, Assert.IsType<EngineCommand.SessionImport>(request.Command).Payload.InputPath); Assert.False(live.ImportAudio.CanExecute(picker));
        sent = engine.SentCount; Assert.False(await store.ImportAudioAsync(path)); Assert.Equal(sent, engine.SentCount);
        request.Complete(new EngineResult.SessionImport(new EngineSessionPayload("imported-session"))); await execution; await RenderAsync(dispatcher, clock);
        Assert.False(store.State.IsPending(EngineCommandName.SessionImport));
    }

    [Theory]
    [InlineData(@"D:\既定の書き出し先")]
    [InlineData(null)]
    public async Task ExportLabelAndTargetFollowConfirmedDestination(string? configuredPath)
    {
        var missingEngine = NewEngine(); missingEngine.SettingsGetResponse = Task.FromException<EngineResult>(new EngineRequestException(Failure(EngineErrorCode.InvalidSettings, "設定未読込", EngineRecoveryAction.Retry)));
        var missingClock = new ManualClock(); await using var missingStore = await Start(missingEngine, missingClock);
        var missingDispatcher = new TestDispatcher(); using var missingContext = new ShellUiContext(missingStore, missingDispatcher, missingClock);
        var missingVm = new SessionsViewModel(missingContext, new TestFolderRevealer()); var missingInspection = Readable("missing-settings", "session", false, false, "準備完了") with { CanExport = true };
        var missingInspect = missingStore.InspectSessionAsync(missingInspection.FolderID); var missingRequest = await missingEngine.NextRequestAsync();
        missingRequest.Complete(new EngineResult.SessionInspect(missingInspection)); await missingInspect; await RenderAsync(missingDispatcher, missingClock);
        Assert.False(missingVm.Export.CanExecute(new TestPathPicker(null, null))); Assert.Equal("設定を保存してから書き出してください。", missingVm.ExportDisabledReason);
        var engine = NewEngine();
        if (configuredPath is not null) engine.SettingsGetResponse = Response(SettingsResult(7, Settings(2, false, false, false, configuredPath)));
        var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock); var vm = new SessionsViewModel(context, new TestFolderRevealer());
        const string folder = "folder", session = "session"; var inspection = Readable(folder, session, false, false, "書き出し不可");
        var inspect = store.InspectSessionAsync(folder); var request = await engine.NextRequestAsync(); request.Complete(new EngineResult.SessionInspect(inspection)); await inspect; await RenderAsync(dispatcher, clock);
        var picker = new TestPathPicker(null, null); Assert.False(vm.Export.CanExecute(picker)); Assert.Equal(inspection.StatusText, vm.ExportDisabledReason);
        inspection = inspection with { CanExport = true }; inspect = store.InspectSessionAsync(folder); request = await engine.NextRequestAsync(); request.Complete(new EngineResult.SessionInspect(inspection)); await inspect; await RenderAsync(dispatcher, clock);
        Assert.True(vm.Export.CanExecute(picker)); Assert.Equal(configuredPath is null ? "書き出す…" : "書き出す", vm.ExportLabel);
        var confirmed = store.State.ConfirmedSettings; var sent = engine.SentCount; vm.Export.Execute(picker); var execution = vm.Export.Execution!;
        if (configuredPath is null) { await execution; await RenderAsync(dispatcher, clock); Assert.Equal(1, picker.ExportFolderCalls); Assert.Equal(sent, engine.SentCount); Assert.Equal(confirmed, store.State.ConfirmedSettings); return; }
        request = await engine.NextRequestAsync(); var payload = Assert.IsType<EngineCommand.SessionExport>(request.Command).Payload;
        Assert.Equal(session, payload.SessionID); Assert.Equal(configuredPath, payload.DestinationPath); Assert.Equal(0, picker.ExportFolderCalls);
        request.Complete(new EngineResult.SessionExport(new EngineExportResult(session, configuredPath + @"\export")));
        request = await engine.NextRequestAsync(); request.Complete(new EngineResult.SessionInspect(inspection with { ExportPath = configuredPath + @"\export" }));
        await execution; await RenderAsync(dispatcher, clock);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ExportPersistsChosenDestinationBeforeSending(bool persist)
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); var revealer = new TestFolderRevealer(); using var context = new ShellUiContext(store, dispatcher, clock); var vm = new SessionsViewModel(context, revealer);
        const string folder = "folder", session = "session", destination = @"D:\選んだ書き出し先", exportPath = @"D:\選んだ書き出し先\session";
        var inspection = Readable(folder, session, false, false, "準備完了") with { CanExport = true };
        var inspect = store.InspectSessionAsync(folder); var request = await engine.NextRequestAsync(); request.Complete(new EngineResult.SessionInspect(inspection)); await inspect; await RenderAsync(dispatcher, clock);
        var confirmed = store.State.ConfirmedSettings!; var draft = Settings(3, true, true, true, @"D:\draft"); await store.SetSettingsDraftAsync(draft);
        var picker = new TestPathPicker(null, destination); vm.Export.Execute(picker); var execution = vm.Export.Execution!; request = await engine.NextRequestAsync();
        await ChangedTo(store, state => state.IsPending(EngineCommandName.SettingsReplace));
        var replace = Assert.IsType<EngineCommand.SettingsReplace>(request.Command).Payload;
        Assert.Equal(confirmed.Revision, replace.ExpectedRevision); Assert.Equal(confirmed.Settings with { ExportDestinationPath = destination }, replace.Settings);
        Assert.Equal(draft, store.State.SettingsDraft); Assert.True(store.State.IsPending(EngineCommandName.SettingsReplace)); Assert.False(store.State.IsPending(EngineCommandName.SessionExport));
        var sent = engine.SentCount;
        if (!persist) { request.Reject(Failure(EngineErrorCode.InvalidSettings, "書き出し先の保存に失敗しました", EngineRecoveryAction.Retry)); await execution; await RenderAsync(dispatcher, clock); Assert.Equal(sent, engine.SentCount); Assert.Equal("書き出し先の保存に失敗しました", vm.LastError!.Message); return; }
        request.Complete(new EngineResult.SettingsReplace(SettingsResult(9, confirmed.Settings with { ExportDestinationPath = destination })));
        request = await engine.NextRequestAsync(); var export = Assert.IsType<EngineCommand.SessionExport>(request.Command).Payload;
        Assert.Equal(session, export.SessionID); Assert.Equal(destination, export.DestinationPath);
        request.Complete(new EngineResult.SessionExport(new EngineExportResult(session, exportPath)));
        request = await engine.NextRequestAsync(); Assert.Equal(folder, Assert.IsType<EngineCommand.SessionInspect>(request.Command).Payload.FolderID);
        request.Complete(new EngineResult.SessionInspect(inspection with { ExportPath = exportPath })); await execution; await RenderAsync(dispatcher, clock);
        Assert.Equal(destination, store.State.ConfirmedSettings!.Settings.ExportDestinationPath); Assert.Equal(draft, store.State.SettingsDraft);
        Assert.True(vm.RevealExportFolder.CanExecute(null)); vm.RevealExportFolder.Execute(null); await vm.RevealExportFolder.Execution!; Assert.Equal(exportPath, revealer.RequestedPath);
    }

    [Fact]
    public async Task DuplicateExportIsDisabledUntilTerminalReply()
    {
        const string destination = @"D:\export"; var engine = NewEngine();
        engine.SettingsGetResponse = Response(SettingsResult(7, Settings(2, false, false, false, destination)));
        var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock); var vm = new SessionsViewModel(context, new TestFolderRevealer());
        const string folder = "folder", session = "session";
        var inspection = Readable(folder, session, false, false, "準備完了") with { CanExport = true };
        var inspect = store.InspectSessionAsync(folder); var request = await engine.NextRequestAsync(); request.Complete(new EngineResult.SessionInspect(inspection)); await inspect; await RenderAsync(dispatcher, clock);
        var picker = new TestPathPicker(null, null); Assert.True(vm.Export.CanExecute(picker)); vm.Export.Execute(picker); var execution = vm.Export.Execution!; request = await engine.NextRequestAsync();
        await ChangedTo(store, state => state.IsPending(EngineCommandName.SessionExport));
        Assert.False(vm.Export.CanExecute(picker)); var sent = engine.SentCount; vm.Export.Execute(picker); Assert.Equal(sent, engine.SentCount);
        Assert.False(await store.ExportSessionAsync(folder, destination)); Assert.Equal(sent, engine.SentCount);
        request.Reject(Failure(EngineErrorCode.Busy, "書き出しに失敗しました", EngineRecoveryAction.Retry)); await execution; await RenderAsync(dispatcher, clock);
        Assert.True(vm.Export.CanExecute(picker)); Assert.Equal("書き出しに失敗しました", vm.LastError!.Message);
    }

    private sealed class TestPathPicker(string? audioPath, string? exportFolder) : IPathPicker
    {
        public int AudioCalls { get; private set; } public int ExportFolderCalls { get; private set; }
        public Task<string?> PickAudioFileAsync() { AudioCalls++; return Task.FromResult(audioPath); }
        public Task<string?> PickExportFolderAsync() { ExportFolderCalls++; return Task.FromResult(exportFolder); }
    }
}
