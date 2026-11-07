using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Presentation.Tests;

public sealed partial class ShellStoreTests
{
    [Fact]
    public async Task SelectingSavedRecordingShowsItsTranscriptAndRecordingNameInMainView()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var sessions = new SessionsViewModel(context, new TestFolderRevealer()); var live = new LiveViewModel(context);
        var summary = Readable("saved-folder", "saved-session", false, false, "確定済み") with { DisplayName = "講義 録音.wav" };
        sessions.Select.Execute(summary);
        var inspect = await engine.NextRequestAsync(); Assert.Equal(summary.FolderID, Assert.IsType<EngineCommand.SessionInspect>(inspect.Command).Payload.FolderID);
        inspect.Complete(new EngineResult.SessionInspect(summary)); await sessions.Select.Execution!;
        var watch = await engine.NextRequestAsync(); Assert.Equal(summary.SessionID, Assert.IsType<EngineCommand.TranscriptWatch>(watch.Command).Payload.SessionID);
        watch.Complete(new EngineResult.TranscriptWatch(Page("saved-session", 1, "保存した講義の本文", null, null)));
        await ChangedTo(store, state => state.Transcript.Tail is not null); await RenderAsync(dispatcher, clock);
        Assert.Equal("保存した講義の本文", Assert.Single(live.Rows).Text);
        Assert.Equal("表示中の録音: 講義 録音.wav", live.TranscriptDisplayText);
        Assert.Equal(new ShellTranscriptBadge(ShellTranscriptBadgeKind.Saved, "保存済み文字起こしを表示中"), live.TranscriptBadge);
        Assert.Same(summary, sessions.Inspection); Assert.Null(store.State.LastError);
    }

    [Theory]
    [InlineData("no-transcript", "この録音には確定文字起こしがありません")]
    [InlineData("missing-audio", "保存済み音声を使えないため、文字起こしを表示できません")]
    [InlineData("unreadable", "保存済み音声を使えないため、文字起こしを表示できません")]
    public async Task SavedRecordingWithoutReadableTranscriptClearsPreviousRowsAndExplains(string kind, string reason)
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        await SelectReady(store, engine, "previous", Page("previous", 1, "別の録音の本文", null, null));
        var summary = Readable("unavailable-folder", "unavailable-session", false, false, "利用できません");
        summary = kind switch
        {
            "no-transcript" => summary with { Metadata = ((EngineSessionMetadata.Readable)summary.Metadata) with { HasTranscript = false } },
            "missing-audio" => summary with { Metadata = ((EngineSessionMetadata.Readable)summary.Metadata) with { Audio = new EngineSessionAudio.Missing() } },
            "unreadable" => summary with { SessionID = null, Status = EngineSessionStatus.Unreadable, Metadata = new EngineSessionMetadata.Unreadable("破損") },
            _ => throw new InvalidOperationException("Unknown test case.")
        };
        var select = store.SelectSavedSessionAsync(summary); var inspect = await engine.NextRequestAsync();
        Assert.Null(store.State.Transcript.Tail); Assert.Null(store.State.Transcript.SessionID);
        inspect.Complete(new EngineResult.SessionInspect(summary)); Assert.True(await select);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock); var live = new LiveViewModel(context);
        Assert.Empty(live.Rows); Assert.True(live.IsEmpty); Assert.Equal(reason, live.EmptyDescription);
        Assert.Equal("表示中の録音: " + summary.DisplayName, live.TranscriptDisplayText);
        Assert.Null(live.TranscriptBadge); Assert.True(live.HasTranscriptHeader);
        Assert.Null(store.State.Transcript.SessionID); Assert.Null(store.State.LastError);
    }

    [Fact]
    public async Task AcceptedImportUsesEngineNameAndShowsProcessingBadgeUntilComplete()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock); var live = new LiveViewModel(context);
        await SelectReady(store, engine, "previous", Page("previous", 1, "前の本文", null, null));
        var import = store.ImportAudioAsync(@"C:\音声\講義 録音.wav"); var accepted = await engine.NextRequestAsync();
        accepted.Complete(new EngineResult.SessionImport(new EngineSessionPayload("imported"))); Assert.True(await import);
        Assert.Equal("imported", store.State.Transcript.SessionID); Assert.Null(store.State.Transcript.DisplayName);
        Assert.Null(store.State.Transcript.Tail); Assert.Null(store.State.SelectedFolderID);
        var nextState = store.State.Engine! with
        {
            Revision = new EngineID(store.State.Engine!.Revision.Value + 1),
            Queue = [new EngineQueuedOperation("imported", EngineStage.Asr)]
        };
        engine.EmitBatch(new EngineOutput(1, nextState.Revision, null, new EngineEvent.State(nextState)));
        await ChangedTo(store, state => state.Engine?.Queue.Any(operation => operation.SessionID == "imported") == true);
        var sessions = await engine.NextRequestAsync(); Assert.Equal(EngineCommandName.SessionList, sessions.Command.Name);
        var summary = Readable("imported-folder", "imported", false, false, "処理中") with
        {
            DisplayName = "エンジン表示名",
            Metadata = ((EngineSessionMetadata.Readable)Readable("imported-folder", "imported", false, false, "処理中").Metadata) with
            {
                Source = new EngineSessionSource.Imported("講義 録音.wav"), HasTranscript = false
            }
        };
        sessions.Complete(new EngineResult.SessionList(new EngineSessionListResult([summary], null, null)));
        await ChangedTo(store, state => state.Transcript.DisplayName == summary.DisplayName);
        await RenderAsync(dispatcher, clock);
        Assert.Equal("表示中の録音: エンジン表示名", live.TranscriptDisplayText);
        Assert.Equal(summary.DisplayName, store.State.Sessions.Current!.Sessions[0].DisplayName);
        Assert.Equal(new ShellTranscriptBadge(ShellTranscriptBadgeKind.ImportedProcessing, "読み込んだ音声を処理中"), live.TranscriptBadge);
        await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(250));
        var initialWatch = await engine.NextRequestAsync();
        var tailStart = clock.GetTimestamp();
        Assert.Equal("imported", Assert.IsType<EngineCommand.TranscriptWatch>(initialWatch.Command).Payload.SessionID);
        initialWatch.Complete(new EngineResult.TranscriptWatch(Page("imported", 1, "", null, null) with { Rows = [] }));
        await ChangedTo(store, state => state.Transcript.Tail is { Rows.Length: 0 });
        await RenderAsync(dispatcher, clock);
        Assert.True(live.IsEmpty); Assert.Equal(new ShellTranscriptBadge(ShellTranscriptBadgeKind.ImportedProcessing, "読み込んだ音声を処理中"), live.TranscriptBadge);
        Assert.Contains("処理中の場合は、作成された行がここに表示されます", live.EmptyDescription);
        Assert.DoesNotContain("録音を開始するか", live.EmptyDescription);
        engine.EmitBatch(Rows("imported", EngineRowsKind.Changes));
        var tailDue = tailStart + TimeSpan.FromMilliseconds(250).Ticks;
        await clock.WaitForTimerDueAtAsync(tailDue);
        clock.Advance(TimeSpan.FromTicks(tailDue - clock.GetTimestamp()));
        var updatedWatch = await engine.NextRequestAsync(); updatedWatch.Complete(new EngineResult.TranscriptWatch(Page("imported", 2, "読み込んだ音声の本文", null, null)));
        await ChangedTo(store, state => state.Transcript.Tail?.Revision == new EngineID(2));
        var finished = store.State.Engine! with
        {
            Revision = new EngineID(store.State.Engine!.Revision.Value + 1), Queue = [], Screen = EngineScreen.Finalized
        };
        engine.EmitBatch(new EngineOutput(1, finished.Revision, null, new EngineEvent.State(finished)));
        await ChangedTo(store, state => state.Engine?.Revision == finished.Revision);
        await RenderAsync(dispatcher, clock);
        Assert.Equal("読み込んだ音声の本文", Assert.Single(live.Rows).Text);
        Assert.Equal("表示中の録音: エンジン表示名", live.TranscriptDisplayText);
        Assert.Equal(new ShellTranscriptBadge(ShellTranscriptBadgeKind.Saved, "保存済み文字起こしを表示中"), live.TranscriptBadge);
    }

    [Fact]
    public async Task NewRecordingTakesOverSavedTranscriptAndClearsSavedSelection()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var summary = Readable("saved-folder", "saved", false, false, "確定済み");
        var select = store.SelectSavedSessionAsync(summary); var inspect = await engine.NextRequestAsync();
        inspect.Complete(new EngineResult.SessionInspect(summary)); Assert.True(await select);
        var savedWatch = await engine.NextRequestAsync(); savedWatch.Complete(new EngineResult.TranscriptWatch(Page("saved", 1, "保存した本文", null, null)));
        await ChangedTo(store, state => state.Transcript.Tail is not null);
        var start = store.ExecuteAsync(new EngineCommand.RecordingStart(new EngineRecordingStartPayload(EngineSource.Microphone, new EngineDevice.Default())));
        var starting = await engine.NextRequestAsync();
        Assert.False(await store.SelectSavedSessionAsync(summary)); Assert.Equal("saved", store.State.Transcript.SessionID);
        starting.Complete(new EngineResult.RecordingStart(new EngineSessionPayload("live"))); Assert.True(await start);
        Assert.Equal("live", store.State.Transcript.SessionID); Assert.Null(store.State.Transcript.DisplayName);
        Assert.Null(store.State.Transcript.Tail); Assert.Null(store.State.SelectedFolderID); Assert.Null(store.State.SessionInspection);
        await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(250));
        var liveWatch = await engine.NextRequestAsync(); Assert.Equal("live", Assert.IsType<EngineCommand.TranscriptWatch>(liveWatch.Command).Payload.SessionID);
        liveWatch.Complete(new EngineResult.TranscriptWatch(Page("live", 1, "新しい録音の本文", null, null)));
        await ChangedTo(store, state => state.Transcript.Tail is not null);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock); var live = new LiveViewModel(context);
        Assert.Equal("新しい録音の本文", Assert.Single(live.Rows).Text); Assert.Null(live.TranscriptDisplayText);
    }

    [Fact]
    public async Task LateSavedInspectionCannotReplaceNewRecording()
    {
        var engine = NewEngine(); await using var store = await Start(engine, TimeProvider.System);
        var summary = Readable("saved-folder", "saved", false, false, "確定済み");
        var select = store.SelectSavedSessionAsync(summary); var inspect = await engine.NextRequestAsync();
        var start = store.ExecuteAsync(new EngineCommand.RecordingStart(new EngineRecordingStartPayload(EngineSource.Microphone, new EngineDevice.Default())));
        var starting = await engine.NextRequestAsync(); starting.Complete(new EngineResult.RecordingStart(new EngineSessionPayload("live"))); Assert.True(await start);
        var watch = await engine.NextRequestAsync(); watch.Complete(new EngineResult.TranscriptWatch(Page("live", 1, "ライブ本文", null, null)));
        inspect.Complete(new EngineResult.SessionInspect(summary)); Assert.True(await select);
        await ChangedTo(store, state => state.Transcript.Tail is not null);
        Assert.Equal("live", store.State.Transcript.SessionID); Assert.Null(store.State.Transcript.DisplayName);
        Assert.Null(store.State.SelectedFolderID); Assert.Null(store.State.SessionInspection);
    }

    [Fact]
    public async Task SavedInspectionDuringProvisionalRecordingStartSurvivesStartFailure()
    {
        var engine = NewEngine(); await using var store = await Start(engine, TimeProvider.System);
        var summary = Readable("saved-folder", "saved", false, false, "確定済み");
        var select = store.SelectSavedSessionAsync(summary); var inspect = await engine.NextRequestAsync();
        var start = store.ExecuteAsync(new EngineCommand.RecordingStart(new EngineRecordingStartPayload(EngineSource.Microphone, new EngineDevice.Default())));
        var starting = await engine.NextRequestAsync();
        EmitSessionState(engine, State(EngineSetupStatus.Ready, 2) with
        { Recording = new EngineRecordingState("attempt", EngineSource.Microphone, new EngineDevice.Default(), EngineRecordingPhase.Starting) });
        await ChangedTo(store, state => state.Engine?.Recording?.Phase == EngineRecordingPhase.Starting);
        inspect.Complete(new EngineResult.SessionInspect(summary)); Assert.True(await select);
        var watch = await engine.NextRequestAsync(); Assert.Equal("saved", Assert.IsType<EngineCommand.TranscriptWatch>(watch.Command).Payload.SessionID);
        watch.Complete(new EngineResult.TranscriptWatch(Page("saved", 1, "保存した本文", null, null)));
        await ChangedTo(store, state => state.Transcript.Tail is not null);
        starting.Reject(Failure(EngineErrorCode.Busy, "録音を開始できませんでした", EngineRecoveryAction.Retry)); Assert.False(await start);
        Assert.Equal("saved", store.State.Transcript.SessionID); Assert.Equal(summary.DisplayName, store.State.Transcript.DisplayName);
        Assert.Null(store.State.Transcript.UnavailableReason); Assert.Equal("保存した本文", Assert.Single(store.State.Transcript.Tail!.Rows).Text);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AcceptedImportSurvivesFailedRecordingStartButCannotReplaceSuccessfulStart(bool startCompletesFirst)
    {
        var engine = NewEngine(); await using var store = await Start(engine, TimeProvider.System);
        var import = store.ImportAudioAsync(@"C:\音声\講義.wav"); var importing = await engine.NextRequestAsync();
        var start = store.ExecuteAsync(new EngineCommand.RecordingStart(new EngineRecordingStartPayload(EngineSource.Microphone, new EngineDevice.Default())));
        var starting = await engine.NextRequestAsync();
        EmitSessionState(engine, State(EngineSetupStatus.Ready, 2) with
        { Recording = new EngineRecordingState("attempt", EngineSource.Microphone, new EngineDevice.Default(), EngineRecordingPhase.Starting) });
        await ChangedTo(store, state => state.Engine?.Recording?.Phase == EngineRecordingPhase.Starting);
        if (startCompletesFirst)
        {
            starting.Complete(new EngineResult.RecordingStart(new EngineSessionPayload("live"))); Assert.True(await start);
        }
        importing.Complete(new EngineResult.SessionImport(new EngineSessionPayload("imported"))); Assert.True(await import);
        var expectedSession = startCompletesFirst ? "live" : "imported";
        Assert.Equal(expectedSession, store.State.Transcript.SessionID);
        if (!startCompletesFirst)
        {
            var sessions = await engine.NextRequestAsync(); Assert.Equal(EngineCommandName.SessionList, sessions.Command.Name);
            sessions.Complete(new EngineResult.SessionList(new EngineSessionListResult(
                [Readable("imported-folder", "imported", false, false, "処理中")], null, null)));
        }
        var watch = await engine.NextRequestAsync(); Assert.Equal(expectedSession, Assert.IsType<EngineCommand.TranscriptWatch>(watch.Command).Payload.SessionID);
        watch.Complete(new EngineResult.TranscriptWatch(Page(expectedSession, 1, "表示する本文", null, null)));
        await ChangedTo(store, state => state.Transcript.Tail is not null);
        if (!startCompletesFirst)
        {
            starting.Reject(Failure(EngineErrorCode.Busy, "録音を開始できませんでした", EngineRecoveryAction.Retry)); Assert.False(await start);
            Assert.Equal("Engine display", store.State.Transcript.DisplayName);
        }
        else Assert.Null(store.State.Transcript.DisplayName);
        Assert.Equal(expectedSession, store.State.Transcript.SessionID); Assert.Equal("表示する本文", Assert.Single(store.State.Transcript.Tail!.Rows).Text);
    }

    [Fact]
    public async Task FailedImportKeepsPreviouslyDisplayedTranscript()
    {
        var engine = NewEngine(); await using var store = await Start(engine, TimeProvider.System);
        var page = Page("saved", 1, "保存した本文", null, null); await SelectReady(store, engine, "saved", page);
        var import = store.ImportAudioAsync(@"C:\音声\壊れた.wav"); var request = await engine.NextRequestAsync();
        request.Reject(Failure(EngineErrorCode.Busy, "読み込めませんでした", EngineRecoveryAction.Retry)); Assert.False(await import);
        Assert.Equal("saved", store.State.Transcript.SessionID); Assert.Same(page, store.State.Transcript.Tail);
        Assert.Equal("読み込めませんでした", store.State.LastError!.Message); Assert.Equal(ShellPhase.Running, store.State.Phase);
    }
}
