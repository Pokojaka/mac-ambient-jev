using System.Reflection;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Presentation.Tests;

public sealed partial class ShellStoreTests
{
    [Fact]
    public async Task OpeningSavedListReloadsOnlyListAndPreservesSelectionAndLiveTranscript()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var inspection = WithoutTranscript(Readable("saved-folder", "saved-session", false, false, "saved inspection"));
        var inspect = store.SelectSavedSessionAsync(inspection); var inspectionRequest = await engine.NextRequestAsync();
        inspectionRequest.Complete(new EngineResult.SessionInspect(inspection)); Assert.True(await inspect);
        await SelectReady(store, engine, "live-session", Page("live-session", 1, "live-tail", null, null));
        var transcript = store.State.Transcript;
        var timers = 0; clock.TimerScheduled += () => Interlocked.Increment(ref timers);

        await store.SetSessionsVisibleAsync(true);
        var refresh = await engine.NextRequestAsync(); AssertReload(refresh);
        refresh.Complete(new EngineResult.SessionList(SessionPage("saved-row", null, null)));
        await SessionsRefreshIdle(store);

        Assert.Equal("saved-row", store.State.Sessions.Current!.Sessions[0].FolderID);
        Assert.Equal("saved-folder", store.State.SelectedFolderID); Assert.Same(inspection, store.State.SessionInspection);
        Assert.Same(transcript, store.State.Transcript);
        var sent = engine.SentCount;
        await store.SetSessionsVisibleAsync(true); await SessionsRefreshIdle(store);
        Assert.Equal(sent, engine.SentCount); Assert.Equal(0, Volatile.Read(ref timers));
    }

    [Fact]
    public async Task SavedListOpenedBeforeHelloRefreshesWhenEngineBecomesRunning()
    {
        var engine = NewEngine(); var client = new DelayedSessionsHello(engine); var clock = new ManualClock();
        await using var store = new ShellStore(client, clock);
        await store.SetSessionsVisibleAsync(true); Assert.Equal(0, engine.SentCount);
        client.HelloCompletion.SetResult(await engine.Hello);
        await store.Initialization.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        var refresh = await engine.NextRequestAsync(); AssertReload(refresh);
        refresh.Complete(new EngineResult.SessionList(SessionPage("opened-during-startup", null, null)));
        await SessionsRefreshIdle(store);
        Assert.Equal("opened-during-startup", store.State.Sessions.Current!.Sessions[0].FolderID);
    }

    [Fact]
    public async Task StructuralStateChangesRefreshOpenListIncludingQueueProcessingAndRecovery()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await OpenAndCompleteSessions(store, engine);
        var transitions = new Func<EngineState, EngineState>[]
        {
            state => state with { Recording = new EngineRecordingState("live", EngineSource.Microphone, new EngineDevice.Default(), EngineRecordingPhase.Recording) },
            state => state with { Recording = state.Recording! with { Phase = EngineRecordingPhase.Stopping } },
            state => state with { Recording = null },
            state => state with { Queue = [new EngineQueuedOperation("imported", EngineStage.Import)] },
            state => state with { Queue = [new EngineQueuedOperation("imported", EngineStage.Asr)] },
            state => state with { Queue = [] },
            state => state with { Failures = [Failure(EngineErrorCode.ProcessingFailure, "failed processing", EngineRecoveryAction.Reprocess)] },
            state => state with { Failures = [] },
            state => state with { Recovery = EngineRecoveryStatus.Running },
            state => state with { Recovery = EngineRecoveryStatus.Completed }
        };
        var next = store.State.Engine!;
        foreach (var transition in transitions)
        {
            next = transition(next) with { Revision = new EngineID(next.Revision.Value + 1) };
            EmitSessionState(engine, next);
            var refresh = await engine.NextRequestAsync(); AssertReload(refresh);
            refresh.Complete(new EngineResult.SessionList(SessionPage($"revision-{next.Revision.Value}", null, null)));
            await SessionsRefreshIdle(store);
            Assert.Equal($"revision-{next.Revision.Value}", store.State.Sessions.Current!.Sessions[0].FolderID);
        }
        Assert.Null(store.State.SelectedFolderID); Assert.Null(store.State.Transcript.SessionID);
    }

    [Fact]
    public async Task SuccessfulSettingsReplaceRefreshesSelectedInspection()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        const string folderID = "settings-refresh-folder";
        var session = WithoutTranscript(Readable(folderID, "settings-refresh-session", false, false, "設定更新前"));
        var selection = store.SelectSavedSessionAsync(session);
        var initialInspection = await engine.NextRequestAsync();
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(initialInspection.Command).Payload.FolderID);
        initialInspection.Complete(new EngineResult.SessionInspect(session));
        Assert.True(await selection);
        var inspectionsBefore = engine.SessionInspectSentCount;

        var replacement = Settings(2, true, false, false, null);
        await store.SetSettingsDraftAsync(replacement);
        var commit = store.CommitSettingsAsync();
        var replaceRequest = await engine.NextRequestAsync();
        Assert.Equal(EngineCommandName.SettingsReplace, replaceRequest.Command.Name);
        replaceRequest.Complete(new EngineResult.SettingsReplace(SettingsResult(2, replacement)));
        Assert.True(await commit);

        var refreshed = await engine.NextRequestAsync();
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(refreshed.Command).Payload.FolderID);
        Assert.Equal(inspectionsBefore + 1, engine.SessionInspectSentCount);
        refreshed.Complete(new EngineResult.SessionInspect(session with { StatusText = "設定更新後" }));
        await SelectedInspectionRefreshIdle(store);

        Assert.Equal(inspectionsBefore + 1, engine.SessionInspectSentCount);
        Assert.Equal("設定更新後", store.State.SessionInspection!.StatusText);
    }

    [Fact]
    public async Task SelectedInspectionRefreshesAfterFailedPreparationRecoversThroughPreparing()
    {
        var initial = State(EngineSetupStatus.Ready, 1) with
        {
            Presentation = State(EngineSetupStatus.Ready, 1).Presentation with
            {
                PreparationPhase = EnginePreparationPhase.Failed,
                PreparationStatusText = "モデルを準備できませんでした"
            }
        };
        var engine = new Fake(initial, Response(SettingsResult(1, Settings(2, false, false, false, null))));
        var clock = new ManualClock(); await using var store = await Start(engine, clock);

        const string folderID = "selected-idle-folder";
        var session = Readable(folderID, "selected-idle-session", false, false, "準備失敗中") with
        {
            Metadata = new EngineSessionMetadata.Readable(
                1, new EngineSessionSource.Microphone(), new EngineSessionAudio.Available(), false)
        };
        var selection = store.SelectSavedSessionAsync(session);
        var initialInspection = await engine.NextRequestAsync();
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(initialInspection.Command).Payload.FolderID);
        initialInspection.Complete(new EngineResult.SessionInspect(session));
        Assert.True(await selection);
        Assert.False(store.State.SessionInspection!.CanReprocess);
        var sent = engine.SentCount;

        var preparingState = initial with
        {
            Revision = new EngineID(2),
            Presentation = initial.Presentation with
            {
                PreparationPhase = EnginePreparationPhase.Preparing,
                PreparationStatusText = "モデルを準備しています"
            }
        };
        EmitSessionState(engine, preparingState);
        await ChangedTo(store, state => state.Engine?.Revision == preparingState.Revision);
        var preparingInspection = await engine.NextRequestAsync();
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(preparingInspection.Command).Payload.FolderID);
        preparingInspection.Complete(new EngineResult.SessionInspect(session));
        await SelectedInspectionRefreshIdle(store);
        Assert.Equal(sent + 1, engine.SentCount);
        Assert.Null(store.State.CommandError);

        var recoveredState = preparingState with
        {
            Revision = new EngineID(3),
            Presentation = preparingState.Presentation with
            {
                PreparationPhase = EnginePreparationPhase.Ready,
                PreparationStatusText = null
            }
        };
        EmitSessionState(engine, recoveredState);
        await ChangedTo(store, state => state.Engine?.Revision == recoveredState.Revision);
        var refreshedInspection = await engine.NextRequestAsync();
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(refreshedInspection.Command).Payload.FolderID);
        refreshedInspection.Complete(new EngineResult.SessionInspect(session with { CanReprocess = true }));
        await ChangedTo(store, state => state.SessionInspection?.CanReprocess == true);
        await SelectedInspectionRefreshIdle(store);
        Assert.True(store.State.SessionInspection!.CanReprocess);
    }

    [Fact]
    public async Task SuccessfulPreparationReplyRefreshesSelectionWithoutReadyState()
    {
        var initial = State(EngineSetupStatus.Ready, 1) with
        {
            Presentation = State(EngineSetupStatus.Ready, 1).Presentation with
            {
                PreparationPhase = EnginePreparationPhase.Failed,
                PreparationStatusText = "モデルを準備できませんでした"
            }
        };
        var engine = new Fake(initial, Response(SettingsResult(1, Settings(2, false, false, false, null))));
        var clock = new ManualClock(); await using var store = await Start(engine, clock);
        const string folderID = "preparation-failure-folder";
        var session = WithoutTranscript(Readable(folderID, "preparation-failure-session", false, false, "準備失敗中"));
        var selection = store.SelectSavedSessionAsync(session);
        (await engine.NextRequestAsync()).Complete(new EngineResult.SessionInspect(session));
        Assert.True(await selection);

        var prepare = store.ExecuteAsync(new EngineCommand.ModelsPrepare(new EngineEmptyPayload()));
        var prepareRequest = await engine.NextRequestAsync();
        Assert.Equal(EngineCommandName.ModelsPrepare, prepareRequest.Command.Name);
        prepareRequest.Complete(new EngineResult.ModelsPrepare(new EngineEmptyPayload()));
        Assert.True(await prepare);

        // The successful reply itself must refresh; no Ready state is published.
        var firstRefresh = await engine.NextRequestAsync();
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(firstRefresh.Command).Payload.FolderID);
        var idle = initial with
        {
            Revision = new EngineID(2),
            Presentation = initial.Presentation with { PreparationPhase = EnginePreparationPhase.Idle, PreparationStatusText = null }
        };
        EmitSessionState(engine, idle);
        await ChangedTo(store, state => state.Engine?.Revision == idle.Revision);
        firstRefresh.Complete(new EngineResult.SessionInspect(session with { CanReprocess = true }));
        var followup = await engine.NextRequestAsync();
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(followup.Command).Payload.FolderID);
        followup.Complete(new EngineResult.SessionInspect(session with { CanReprocess = true }));
        await SelectedInspectionRefreshIdle(store);
        Assert.True(store.State.SessionInspection!.CanReprocess);
        Assert.Equal(EnginePreparationPhase.Idle, store.State.Engine!.Presentation.PreparationPhase);
    }

    [Fact]
    public async Task BackgroundRefreshDuringExportJoinsSinglePostActionInspection()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        const string folderID = "export-refresh-folder", sessionID = "export-refresh-session";
        var summary = WithoutTranscript(Readable(folderID, sessionID, false, false, "書き出し可能") with { CanExport = true });
        var selection = store.SelectSavedSessionAsync(summary);
        (await engine.NextRequestAsync()).Complete(new EngineResult.SessionInspect(summary));
        Assert.True(await selection);
        var inspectionsBefore = engine.SessionInspectSentCount;

        var export = store.ExportSessionAsync(folderID, "/exports");
        var exportRequest = await engine.NextRequestAsync();
        Assert.Equal(EngineCommandName.SessionExport, exportRequest.Command.Name);
        var failureState = store.State.Engine! with
        {
            Revision = new EngineID(store.State.Engine!.Revision.Value + 1),
            Failures = [Failure(EngineErrorCode.ProcessingFailure, "monitor refresh", EngineRecoveryAction.Retry)]
        };
        EmitSessionState(engine, failureState);
        await ChangedTo(store, state => state.Engine?.Revision == failureState.Revision);

        exportRequest.Complete(new EngineResult.SessionExport(new EngineExportResult(sessionID, "/exports/session")));
        Assert.True(await export.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken));
        var postExportInspection = await engine.NextRequestAsync();
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(postExportInspection.Command).Payload.FolderID);
        postExportInspection.Complete(new EngineResult.SessionInspect(summary with { ExportPath = "/exports/session" }));
        await SelectedInspectionRefreshIdle(store);

        Assert.Equal(inspectionsBefore + 1, engine.SessionInspectSentCount);
        Assert.Null(store.State.CommandError);
        Assert.Equal(ShellPhase.Running, store.State.Phase);
    }

    [Fact]
    public async Task ReprocessAfterSuccessfulExportCompletesBeforeQueuedInspection()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        const string folderID = "export-then-reprocess-folder", sessionID = "export-then-reprocess-session";
        var summary = WithoutTranscript(Readable(folderID, sessionID, true, false, "操作可能") with { CanExport = true });
        var selection = store.SelectSavedSessionAsync(summary);
        (await engine.NextRequestAsync()).Complete(new EngineResult.SessionInspect(summary));
        Assert.True(await selection);
        var inspectionsBefore = engine.SessionInspectSentCount;

        var export = store.ExportSessionAsync(folderID, "/exports");
        var exportRequest = await engine.NextRequestAsync();
        Assert.Equal(EngineCommandName.SessionExport, exportRequest.Command.Name);
        exportRequest.Complete(new EngineResult.SessionExport(new EngineExportResult(sessionID, "/exports/session")));
        Assert.True(await export.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken));
        Assert.False(store.State.IsPending(EngineCommandName.SessionExport));

        var postExportInspection = await engine.NextRequestAsync();
        Assert.Equal(EngineCommandName.SessionInspect, postExportInspection.Command.Name);
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(postExportInspection.Command).Payload.FolderID);
        postExportInspection.Complete(new EngineResult.SessionInspect(summary with { ExportPath = "/exports/session" }));
        await SelectedInspectionRefreshIdle(store);
        Assert.Equal(inspectionsBefore + 1, engine.SessionInspectSentCount);

        var reprocess = store.ReprocessSessionAsync();
        var reprocessRequest = await engine.NextRequestAsync();
        Assert.Equal(EngineCommandName.SessionReprocess, reprocessRequest.Command.Name);
        await ChangedTo(store, state => state.IsPending(EngineCommandName.SessionReprocess));
        Assert.False(reprocess.IsCompleted);

        reprocessRequest.Complete(new EngineResult.SessionReprocess(new EngineSessionPayload(sessionID)));
        Assert.True(await reprocess.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken));
        var postReprocessInspection = await engine.NextRequestAsync();
        Assert.Equal(EngineCommandName.SessionInspect, postReprocessInspection.Command.Name);
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(postReprocessInspection.Command).Payload.FolderID);
        postReprocessInspection.Complete(new EngineResult.SessionInspect(summary with { ExportPath = "/exports/session" }));
        await SelectedInspectionRefreshIdle(store);

        Assert.Equal(inspectionsBefore + 2, engine.SessionInspectSentCount);
    }

    [Fact]
    public async Task ClientFailureAfterExportDoesNotChangeItsSuccessfulResult()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        const string folderID = "queued-export-folder", sessionID = "queued-export-session";
        var summary = WithoutTranscript(Readable(folderID, sessionID, false, false, "書き出し可能") with { CanExport = true });
        var selection = store.SelectSavedSessionAsync(summary);
        (await engine.NextRequestAsync()).Complete(new EngineResult.SessionInspect(summary));
        Assert.True(await selection);

        var export = store.ExportSessionAsync(folderID, "/exports");
        var exportRequest = await engine.NextRequestAsync();
        var recordingStart = store.ExecuteAsync(new EngineCommand.RecordingStart(new EngineRecordingStartPayload(EngineSource.Microphone, new EngineDevice.Default())));
        var recordingStartRequest = await engine.NextRequestAsync();
        exportRequest.Complete(new EngineResult.SessionExport(new EngineExportResult(sessionID, "/exports/session")));
        await ChangedTo(store, state => !state.IsPending(EngineCommandName.SessionExport));
        Assert.True(await export);

        var failure = new EngineClientFailure("engine disconnected", 7, Failure(EngineErrorCode.DeviceFailure, "engine disconnected", EngineRecoveryAction.Retry), new StderrSnapshot([], 0));
        engine.SignalFailure(failure);
        await ChangedTo(store, state => state.Phase == ShellPhase.EngineFailed);
        recordingStartRequest.Fail(new EngineClientFailedException(failure));
        Assert.False(await recordingStart);
        engine.CompleteFailure(failure);

        await SelectedInspectionRefreshIdle(store);
        Assert.False(store.State.IsPending(EngineCommandName.SessionInspect));
    }

    [Fact]
    public async Task PresentationFailureDiscardsLateExportInspectionReply()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        const string folderID = "presentation-failure-folder", sessionID = "presentation-failure-session";
        var summary = WithoutTranscript(Readable(folderID, sessionID, false, false, "書き出し可能") with { CanExport = true });
        var selection = store.SelectSavedSessionAsync(summary);
        (await engine.NextRequestAsync()).Complete(new EngineResult.SessionInspect(summary));
        Assert.True(await selection);

        var export = store.ExportSessionAsync(folderID, "/exports");
        var exportRequest = await engine.NextRequestAsync();
        Assert.Equal(EngineCommandName.SessionExport, exportRequest.Command.Name);
        exportRequest.Complete(new EngineResult.SessionExport(new EngineExportResult(sessionID, "/exports/session")));
        var inspectionRequest = await engine.NextRequestAsync();
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(inspectionRequest.Command).Payload.FolderID);

        await store.ReportPresentationFailureAsync(new InvalidOperationException("presentation failed"));
        var inspectionAtFailure = store.State.SessionInspection;
        Assert.True(await export.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken));
        Assert.Equal(ShellPhase.EngineFailed, store.State.Phase);

        inspectionRequest.Complete(new EngineResult.SessionInspect(summary with { ExportPath = "/exports/session" }));
        await SelectedInspectionRefreshIdle(store);
        Assert.Same(inspectionAtFailure, store.State.SessionInspection);
        Assert.Equal(ShellPhase.EngineFailed, store.State.Phase);
    }

    [Fact]
    public async Task ImportedDisplayNameReplyAfterTerminalFailureLeavesCommandErrorUnchanged()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var import = store.ImportAudioAsync(@"C:\音声\講義.wav");
        var importRequest = await engine.NextRequestAsync();
        importRequest.Complete(new EngineResult.SessionImport(new EngineSessionPayload("imported-session")));
        Assert.True(await import);

        var listRequest = await engine.NextRequestAsync();
        Assert.Equal(EngineCommandName.SessionList, listRequest.Command.Name);
        var failure = new EngineClientFailure("engine disconnected", 7,
            Failure(EngineErrorCode.DeviceFailure, "engine disconnected", EngineRecoveryAction.Retry), new StderrSnapshot([], 0));
        engine.SignalFailure(failure);
        await ChangedTo(store, state => state.Phase == ShellPhase.EngineFailed);
        var commandError = store.State.CommandError;
        engine.CompleteFailure(failure);

        var summary = Readable("imported-folder", "imported-session", false, false, "処理中") with
        {
            DisplayName = "エンジン表示名",
            Metadata = new EngineSessionMetadata.Readable(1, new EngineSessionSource.Imported("講義.wav"),
                new EngineSessionAudio.Available(), false)
        };
        listRequest.Complete(new EngineResult.SessionList(new EngineSessionListResult([summary], null, null)));
        await ChangedTo(store, state => state.Sessions.Current?.Sessions.SingleOrDefault()?.FolderID == summary.FolderID);

        Assert.Equal(commandError, store.State.CommandError);
        Assert.Null(store.State.Transcript.DisplayName);
    }

    [Fact]
    public async Task CancelledInspectionRequestFailureDoesNotReplaceLastError()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        const string folderID = "settled-inspection-folder", sessionID = "settled-inspection-session";
        var summary = WithoutTranscript(Readable(folderID, sessionID, false, false, "検査済み"));
        var selection = store.SelectSavedSessionAsync(summary);
        (await engine.NextRequestAsync()).Complete(new EngineResult.SessionInspect(summary));
        Assert.True(await selection);

        var previousError = Failure(EngineErrorCode.Filesystem, "previous engine error", EngineRecoveryAction.Retry);
        engine.EmitBatch(new EngineOutput(1, new EngineID(1), null, new EngineEvent.Error(previousError)));
        await ChangedTo(store, state => state.LastError == previousError);

        var current = store.State.Engine!;
        var changed = current with
        {
            Revision = new EngineID(current.Revision.Value + 1),
            Queue = [new EngineQueuedOperation("unrelated-session", EngineStage.Asr)]
        };
        EmitSessionState(engine, changed);
        await ChangedTo(store, state => state.Engine?.Revision == changed.Revision);
        var inspectionRequest = await engine.NextRequestAsync();
        Assert.Equal(EngineCommandName.SessionInspect, inspectionRequest.Command.Name);

        var start = store.ExecuteAsync(new EngineCommand.RecordingStart(
            new EngineRecordingStartPayload(EngineSource.Microphone, new EngineDevice.Default())));
        var startRequest = await engine.NextRequestAsync();
        startRequest.Complete(new EngineResult.RecordingStart(new EngineSessionPayload("live-session")));
        Assert.True(await start);
        Assert.Null(store.State.SelectedFolderID);
        Assert.Null(store.State.SessionInspection);

        inspectionRequest.Reject(Failure(EngineErrorCode.SessionNotFound, "session no longer exists", EngineRecoveryAction.Retry));
        await ChangedTo(store, state => !state.IsPending(EngineCommandName.SessionInspect));
        await SelectedInspectionRefreshIdle(store);
        Assert.Equal(previousError, store.State.LastError);
    }

    [Fact]
    public async Task ReloadCompletesWhileReprocessIsPendingAndRefreshesAfterwardOnce()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        const string folderID = "reload-pending-folder", sessionID = "reload-pending-session";
        var originalSummary = WithoutTranscript(Readable(folderID, sessionID, true, false, "old inspection"));
        var original = store.SelectSavedSessionAsync(originalSummary);
        var originalRequest = await engine.NextRequestAsync();
        originalRequest.Complete(new EngineResult.SessionInspect(originalSummary));
        Assert.True(await original);
        var inspectionsBefore = engine.SessionInspectSentCount;

        var reprocess = store.ReprocessSessionAsync();
        var reprocessRequest = await engine.NextRequestAsync();
        Assert.Equal(EngineCommandName.SessionReprocess, reprocessRequest.Command.Name);
        await ChangedTo(store, state => state.IsPending(EngineCommandName.SessionReprocess));
        Assert.False(store.State.IsPending(EngineCommandName.SessionInspect));
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var viewModel = new SessionsViewModel(context, new TestFolderRevealer());

        viewModel.List.Execute(ShellPageMove.Reload);
        var listRequest = await engine.NextRequestAsync(); AssertReload(listRequest);
        listRequest.Complete(new EngineResult.SessionList(SessionPage("reload-result", "next-cursor", null)));
        await viewModel.List.Execution!.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.Equal("reload-result", store.State.Sessions.Current!.Sessions.Single().FolderID);
        Assert.True(viewModel.List.CanExecute(ShellPageMove.Next));
        Assert.Equal(inspectionsBefore, engine.SessionInspectSentCount);

        reprocessRequest.Complete(new EngineResult.SessionReprocess(new EngineSessionPayload(sessionID)));
        Assert.True(await reprocess);
        var followup = await engine.NextRequestAsync();
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(followup.Command).Payload.FolderID);
        Assert.Equal(inspectionsBefore + 1, engine.SessionInspectSentCount);
        followup.Complete(new EngineResult.SessionInspect(originalSummary with { StatusText = "refreshed after reload" }));
        await SelectedInspectionRefreshIdle(store);

        Assert.Equal(inspectionsBefore + 1, engine.SessionInspectSentCount);
        Assert.Equal("refreshed after reload", store.State.SessionInspection!.StatusText);
        Assert.DoesNotContain("選択できません", store.State.CommandError ?? string.Empty, StringComparison.Ordinal);
    }

    [Fact]
    public async Task SelectedInspectionRefreshesWhenSessionLeavesQueueWithoutFailureChange()
    {
        const string folderID = "queue-exit-folder", sessionID = "queue-exit-session";
        var initial = State(EngineSetupStatus.Ready, 1) with
        {
            Queue = [new EngineQueuedOperation(sessionID, EngineStage.Asr)]
        };
        var engine = new Fake(initial, Response(SettingsResult(1, Settings(2, false, false, false, null))));
        var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var session = WithoutTranscript(Readable(folderID, sessionID, false, false, "処理中"));
        var selection = store.SelectSavedSessionAsync(session);
        (await engine.NextRequestAsync()).Complete(new EngineResult.SessionInspect(session));
        Assert.True(await selection);
        var inspectionsBefore = engine.SessionInspectSentCount;
        var failures = store.State.Engine!.Failures;

        EmitSessionState(engine, store.State.Engine! with { Revision = new EngineID(2), Queue = [] });
        await ChangedTo(store, state => state.Engine?.Revision == new EngineID(2));
        var refreshed = await engine.NextRequestAsync();
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(refreshed.Command).Payload.FolderID);
        refreshed.Complete(new EngineResult.SessionInspect(session with { CanReprocess = true }));
        await SelectedInspectionRefreshIdle(store);

        Assert.Equal(inspectionsBefore + 1, engine.SessionInspectSentCount);
        Assert.Equal(failures, store.State.Engine!.Failures);
        Assert.True(store.State.SessionInspection!.CanReprocess);
    }

    [Fact]
    public async Task FailureChangesDuringInspectionCoalesceAfterPendingInspectionWithoutUserError()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        const string folderID = "selected-pending-folder", sessionID = "selected-pending-session";
        var session = Readable(folderID, sessionID, false, false, "選択済み");
        var selection = store.SelectSavedSessionAsync(session);
        var initialInspection = await engine.NextRequestAsync();
        initialInspection.Complete(new EngineResult.SessionInspect(session));
        Assert.True(await selection);

        var initialWatch = await engine.NextRequestAsync();
        Assert.Equal(sessionID, Assert.IsType<EngineCommand.TranscriptWatch>(initialWatch.Command).Payload.SessionID);
        initialWatch.Complete(new EngineResult.TranscriptWatch(Page(sessionID, 1, "initial-tail", null, null)));

        var pendingSelection = store.SelectSavedSessionAsync(session);
        var pendingInspection = await engine.NextRequestAsync();
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(pendingInspection.Command).Payload.FolderID);
        var sentInspections = engine.SessionInspectSentCount;

        var firstFailureState = store.State.Engine! with
        {
            Revision = new EngineID(2),
            Failures = [Failure(EngineErrorCode.ProcessingFailure, "first state failure", EngineRecoveryAction.Reprocess)]
        };
        EmitSessionState(engine, firstFailureState);
        await ChangedTo(store, state => state.Engine?.Revision == firstFailureState.Revision);
        var secondFailureState = firstFailureState with
        {
            Revision = new EngineID(3),
            Failures = [
                .. firstFailureState.Failures,
                Failure(EngineErrorCode.Filesystem, "second state failure", EngineRecoveryAction.Retry)
            ]
        };
        EmitSessionState(engine, secondFailureState);
        await ChangedTo(store, state => state.Engine?.Revision == secondFailureState.Revision);
        await SelectedInspectionRefreshIdle(store);
        Assert.Equal(sentInspections, engine.SessionInspectSentCount);
        Assert.Null(store.State.CommandError);

        pendingInspection.Complete(new EngineResult.SessionInspect(session));
        Assert.True(await pendingSelection);
        var followup = await engine.NextRequestAsync();
        Assert.Equal(folderID, Assert.IsType<EngineCommand.SessionInspect>(followup.Command).Payload.FolderID);
        followup.Complete(new EngineResult.SessionInspect(session));
        await SelectedInspectionRefreshIdle(store);
        Assert.Equal(sentInspections + 1, engine.SessionInspectSentCount);
        Assert.Null(store.State.CommandError);
    }

    [Fact]
    public async Task ScreenPresentationAndEquivalentArraySnapshotsDoNotInvalidateSavedList()
    {
        var initial = State(EngineSetupStatus.Ready, 1) with
        {
            Queue = [new EngineQueuedOperation("queued", EngineStage.Asr)],
            Failures = [Failure(EngineErrorCode.ProcessingFailure, "retained failure", EngineRecoveryAction.Reprocess) with
            {
                Details = [new EngineErrorDetail("engine", "processing", "retained detail", null, null)],
                CleanupErrors = [new EngineErrorDetail("filesystem", "cleanup", "retained cleanup", null, null)]
            }]
        };
        var engine = new Fake(initial, Response(SettingsResult(1, Settings(2, false, false, false, null))));
        var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await OpenAndCompleteSessions(store, engine);
        var sent = engine.SentCount;
        var unchanged = initial with
        {
            Revision = new EngineID(2), Screen = EngineScreen.Finalized,
            Queue = initial.Queue.Select(item => item with { }).ToArray(),
            Failures = initial.Failures.Select(item => item with
            {
                Details = item.Details.Select(detail => detail with { }).ToArray(),
                CleanupErrors = item.CleanupErrors.Select(detail => detail with { }).ToArray()
            }).ToArray(),
            Presentation = initial.Presentation with { ProcessingStatusText = "presentation-only update" }
        };
        engine.EmitBatch(new EngineOutput(1, new EngineID(2), null, new EngineEvent.State(unchanged)),
            Rows("unselected", EngineRowsKind.ReloadRequired),
            new EngineOutput(1, new EngineID(3), null, new EngineEvent.Progress(new EngineProgressPayload(EngineStage.Asr, 1, 2, "queued"))));
        await ChangedTo(store, state => state.Engine?.Revision == new EngineID(2) && state.Progress is not null);
        await SessionsRefreshIdle(store);
        Assert.Equal(sent, engine.SentCount);
    }

    [Fact]
    public async Task InvalidationsWaitForManualListAndCoalesceWithOneFollowupPerInflightRequest()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var manual = store.ListSessionsAsync(ShellPageMove.Reload); var manualRequest = await engine.NextRequestAsync();
        await store.SetSessionsVisibleAsync(true);
        EmitQueuedSessionChanges(engine, 2, 21);
        await ChangedTo(store, state => state.Engine?.Revision == new EngineID(21));
        Assert.Equal(2, engine.SentCount); Assert.Null(store.State.CommandError);
        manualRequest.Complete(new EngineResult.SessionList(SessionPage("manual", null, null))); Assert.True(await manual);

        var refresh = await engine.NextRequestAsync(); AssertReload(refresh);
        EmitQueuedSessionChanges(engine, 22, 41);
        await ChangedTo(store, state => state.Engine?.Revision == new EngineID(41));
        Assert.Equal(3, engine.SentCount); Assert.Null(store.State.CommandError);
        refresh.Complete(new EngineResult.SessionList(SessionPage("first-refresh", null, null)));
        var followup = await engine.NextRequestAsync(); AssertReload(followup);
        followup.Complete(new EngineResult.SessionList(SessionPage("coalesced", null, null)));
        await SessionsRefreshIdle(store);
        Assert.Equal(4, engine.SentCount); Assert.Single(store.State.Sessions.Pages);
        Assert.Equal("coalesced", store.State.Sessions.Current!.Sessions[0].FolderID);
    }

    [Fact]
    public async Task ClosingSavedListDropsQueuedRefreshesAndReopeningReloads()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await store.SetSessionsVisibleAsync(true); var refresh = await engine.NextRequestAsync();
        EmitQueuedSessionChanges(engine, 2, 3);
        await ChangedTo(store, state => state.Engine?.Revision == new EngineID(3));
        await store.SetSessionsVisibleAsync(false);
        refresh.Complete(new EngineResult.SessionList(SessionPage("last-open-result", null, null)));
        await SessionsRefreshIdle(store); var sent = engine.SentCount;
        EmitQueuedSessionChanges(engine, 4, 5);
        await ChangedTo(store, state => state.Engine?.Revision == new EngineID(5));
        await SessionsRefreshIdle(store); Assert.Equal(sent, engine.SentCount);
        clock.Advance(TimeSpan.FromDays(1)); Assert.Equal(sent, engine.SentCount);

        await store.SetSessionsVisibleAsync(true); var reopened = await engine.NextRequestAsync(); AssertReload(reopened);
        reopened.Complete(new EngineResult.SessionList(SessionPage("reopened", null, null)));
        await SessionsRefreshIdle(store); Assert.Equal(sent + 1, engine.SentCount);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SuccessfulImportAndStopCompletionRefreshOpenList(bool stop)
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await SelectReady(store, engine, "current-view", Page("current-view", 1, "kept", null, null));
        await OpenAndCompleteSessions(store, engine);
        var transcript = store.State.Transcript;
        var action = stop
            ? store.ExecuteAsync(new EngineCommand.RecordingStop(new EngineSessionPayload("current-view")))
            : store.ImportAudioAsync("/input/audio.wav");
        var request = await engine.NextRequestAsync();
        Assert.Equal(stop ? EngineCommandName.RecordingStop : EngineCommandName.SessionImport, request.Command.Name);
        request.Complete(stop
            ? new EngineResult.RecordingStop(new EngineSessionPayload("completed-session"))
            : new EngineResult.SessionImport(new EngineSessionPayload("completed-session")));
        Assert.True(await action);
        var refresh = await engine.NextRequestAsync(); AssertReload(refresh);
        refresh.Complete(stop
            ? new EngineResult.SessionList(SessionPage("completed-session", null, null))
            : new EngineResult.SessionList(new EngineSessionListResult(
                [Readable("completed-folder", "completed-session", false, false, "処理中") with { DisplayName = "engine import name" }], null, null)));
        await SessionsRefreshIdle(store);
        if (stop) Assert.Same(transcript, store.State.Transcript);
        else { Assert.Equal("completed-session", store.State.Transcript.SessionID); Assert.Null(store.State.Transcript.Tail); }
        Assert.Null(store.State.SelectedFolderID); Assert.Null(store.State.SessionInspection);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FailedAutomaticListSurfacesErrorAndDoesNotRetryWithoutNewInvalidation(bool admissionFailure)
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var timers = 0; clock.TimerScheduled += () => Interlocked.Increment(ref timers);
        if (admissionFailure) engine.AutoResponse = _ => throw new EngineClientOverloadedException("list capacity exhausted");
        await store.SetSessionsVisibleAsync(true);
        if (!admissionFailure)
        {
            var request = await engine.NextRequestAsync();
            request.Reject(Failure(EngineErrorCode.Filesystem, "list failed", EngineRecoveryAction.Retry));
        }
        await ChangedTo(store, state => admissionFailure ? state.CommandError == "list capacity exhausted" : state.LastError?.Message == "list failed");
        await SessionsRefreshIdle(store);
        Assert.Equal(ShellPhase.Running, store.State.Phase); Assert.False(store.State.IsPending(EngineCommandName.SessionList));
        Assert.Equal(2, engine.SentCount); Assert.Equal(0, Volatile.Read(ref timers));
        EmitSessionState(engine, store.State.Engine! with { Revision = new EngineID(2), Screen = EngineScreen.Finalized });
        await ChangedTo(store, state => state.Engine?.Revision == new EngineID(2));
        clock.Advance(TimeSpan.FromDays(1)); await SessionsRefreshIdle(store); Assert.Equal(2, engine.SentCount);

        engine.AutoResponse = null;
        EmitSessionState(engine, store.State.Engine! with { Revision = new EngineID(3), Queue = [new EngineQueuedOperation("new", EngineStage.Asr)] });
        var retry = await engine.NextRequestAsync(); AssertReload(retry);
        retry.Complete(new EngineResult.SessionList(SessionPage("after-new-invalidation", null, null)));
        await SessionsRefreshIdle(store); Assert.Equal(3, engine.SentCount);
    }

    [Fact]
    public async Task DisposingWhileAutomaticListIsPendingStopsWorkerWithoutClosingClient()
    {
        var engine = NewEngine(); var clock = new ManualClock(); var store = await Start(engine, clock);
        await store.SetSessionsVisibleAsync(true); var request = await engine.NextRequestAsync();
        await store.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
        Assert.Equal(ShellPhase.Disposed, store.State.Phase); Assert.Equal(EngineClientState.Running, engine.State);
        Assert.Empty(store.State.Pending);
        request.Complete(new EngineResult.SessionList(SessionPage("too-late", null, null)));
        Assert.Empty(store.State.Sessions.Pages);
    }

    private sealed class DelayedSessionsHello(Fake inner) : IEngineClient
    {
        public TaskCompletionSource<EngineResult> HelloCompletion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task<EngineResult> Hello => HelloCompletion.Task;
        public Task<EngineResult> SendAsync(EngineCommand command) => inner.SendAsync(command);
        public IReadOnlyList<EngineOutput> DrainEvents() => inner.DrainEvents();
        public Task WaitForEventsAsync(CancellationToken token) => inner.WaitForEventsAsync(token);
        public Task<EngineClientState> Completion => inner.Completion;
        public EngineClientState State => inner.State;
        public EngineClientFailure? Failure => inner.Failure;
    }

    private static void AssertReload(Request request)
    {
        var payload = Assert.IsType<EngineCommand.SessionList>(request.Command).Payload;
        Assert.Null(payload.Cursor); Assert.Equal(100, payload.Limit);
    }

    private static async Task OpenAndCompleteSessions(ShellStore store, Fake engine)
    {
        await store.SetSessionsVisibleAsync(true); var request = await engine.NextRequestAsync(); AssertReload(request);
        request.Complete(new EngineResult.SessionList(SessionPage("initial", null, null)));
        await SessionsRefreshIdle(store);
    }

    private static void EmitSessionState(Fake engine, EngineState state) =>
        engine.EmitBatch(new EngineOutput(1, state.Revision, null, new EngineEvent.State(state)));

    private static void EmitQueuedSessionChanges(Fake engine, ulong first, ulong last) => engine.EmitBatch(
        Enumerable.Range(0, checked((int)(last - first + 1))).Select(index =>
        {
            var revision = first + (ulong)index;
            return new EngineOutput(1, new EngineID(revision), null, new EngineEvent.State(State(EngineSetupStatus.Ready, revision) with
            { Queue = [new EngineQueuedOperation($"session-{revision}", EngineStage.Asr)] }));
        }).ToArray());

    // Only the quiescence barrier uses implementation access: externally observed requests,
    // snapshots and errors are asserted above. Awaiting the actual worker makes no-spin and
    // negative assertions deterministic without sleeps or extra production test APIs.
    private static async Task SessionsRefreshIdle(ShellStore store)
    {
        var field = typeof(ShellStore).GetField("_sessionsRefreshTask", BindingFlags.Instance | BindingFlags.NonPublic)!;
        while (field.GetValue(store) is Task worker)
        {
            await worker.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
            if (ReferenceEquals(worker, field.GetValue(store))) return;
        }
    }

    private static async Task SelectedInspectionRefreshIdle(ShellStore store)
    {
        var field = typeof(ShellStore).GetField("_selectedInspectionRefreshTask", BindingFlags.Instance | BindingFlags.NonPublic)!;
        while (field.GetValue(store) is Task worker)
        {
            await worker.WaitAsync(TimeSpan.FromSeconds(10), TestContext.Current.CancellationToken);
            if (ReferenceEquals(worker, field.GetValue(store))) return;
        }
    }
}
