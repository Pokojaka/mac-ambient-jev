using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Presentation.Tests;

public sealed partial class ShellStoreTests
{
    [Fact]
    public async Task RowTopSpacingSeparatesTurnsAndResetsWhenFirstRowIsRemoved()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var live = new LiveViewModel(context);
        var first = Row("first", 0, "最初") with { Headings = [EngineSpeakerLabel.Speaker1] };
        var continuing = Row("continuing", 1000, "続き") with { Headings = [EngineSpeakerLabel.Speaker1] };
        var heading = Row("heading", 2000, "別の話者") with { Headings = [EngineSpeakerLabel.Speaker2] };
        await SelectReady(store, engine, "A", Page("A", 1, "", null, null) with { Rows = [first, continuing, heading] });
        await RenderAsync(dispatcher, clock);
        Assert.Equal(new double[] { 0, 4, 12 }, live.Rows.Select(row => row.TopSpacing));
        Assert.Equal(string.Empty, live.Rows[1].HeadingText);

        await store.ReturnToLatestAsync(); await clock.WaitForTimerAsync(); clock.Advance(TimeSpan.FromMilliseconds(250));
        (await engine.NextRequestAsync()).Complete(new EngineResult.TranscriptWatch(
            Page("A", 2, "", null, null) with { Rows = [continuing, heading] }));
        await ChangedTo(store, state => state.Transcript.Tail?.Revision == new EngineID(2));
        await RenderAsync(dispatcher, clock);
        Assert.Equal(new[] { "continuing", "heading" }, live.Rows.Select(row => row.RowID));
        Assert.Equal(new double[] { 0, 12 }, live.Rows.Select(row => row.TopSpacing));
        Assert.Equal("Speaker 1", live.Rows[0].HeadingText);
    }

    [Fact]
    public async Task TranscriptHeaderTracksUpdatesAndReturnToLatestWithoutBadgeOrDisplayName()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var live = new LiveViewModel(context);
        Assert.False(live.HasTranscriptHeader);
        await SelectReady(store, engine, "A", Page("A", 1, "本文", null, null));
        await RenderAsync(dispatcher, clock);
        Assert.False(live.HasTranscriptHeader);
        await live.UserScrolledAsync(); await RenderAsync(dispatcher, clock);
        Assert.False(live.IsFollowing); Assert.True(live.HasTranscriptHeader);
        engine.EmitBatch(Rows("A", EngineRowsKind.Changes));
        await ChangedTo(store, state => state.Transcript.NewUpdatesAvailable);
        await RenderAsync(dispatcher, clock);
        Assert.True(live.HasNewUpdates); Assert.True(live.HasTranscriptHeader);
        await store.ReturnToLatestAsync(); await RenderAsync(dispatcher, clock);
        Assert.True(live.IsFollowing); Assert.False(live.HasNewUpdates); Assert.False(live.HasTranscriptHeader);
    }

    [Fact]
    public async Task ToggleStopsAuthoritativeCaptureWhileStartResponseIsPending()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var live = new LiveViewModel(context);
        Assert.Equal(ShellRecordingAction.Start, live.RecordingAction);
        Assert.Equal(ShellRecordingGlyph.Record, live.RecordingGlyph);
        Assert.Equal("録音を開始", live.RecordingLabel);
        Assert.Contains("マイク", live.RecordingHelp);
        Assert.Equal("音声ファイルを読み込んで文字起こし", live.ImportHelp);
        Assert.Equal("録音する音声をマイクかシステム音声から選択", live.SourceHelp);
        Assert.Null(live.RecordingDisabledReason);
        Assert.False(live.ToggleRecording.CanExecute("unexpected parameter"));

        live.ToggleRecording.Execute(null); var startExecution = live.ToggleRecording.Execution!;
        var start = await engine.NextRequestAsync(); Assert.IsType<EngineCommand.RecordingStart>(start.Command);
        await ChangedTo(store, state => state.IsPending(EngineCommandName.RecordingStart));
        await RenderAsync(dispatcher, clock);
        Assert.Equal(ShellRecordingAction.Stop, live.RecordingAction);
        Assert.Equal(ShellRecordingGlyph.Stop, live.RecordingGlyph);
        Assert.Equal("録音を停止", live.RecordingLabel);
        Assert.True(live.IsRecordingStarting); Assert.True(live.IsBusy);
        Assert.False(live.ToggleRecording.CanExecute(null));
        Assert.Contains("開始が完了すると停止できます", live.RecordingHelp);

        async Task CapturePhase(EngineRecordingPhase phase, ulong revision)
        {
            engine.EmitBatch(new EngineOutput(1, new EngineID(revision), null, new EngineEvent.State(
                State(EngineSetupStatus.Ready, revision) with
                {
                    Recording = new EngineRecordingState("authoritative", EngineSource.Microphone, new EngineDevice.Default(), phase)
                })));
            await ChangedTo(store, state => state.Engine?.Revision == new EngineID(revision));
            await RenderAsync(dispatcher, clock);
        }
        await CapturePhase(EngineRecordingPhase.Starting, 2);
        var sent = engine.SentCount;
        live.ToggleRecording.Execute(null);
        Assert.Equal(sent, engine.SentCount); // Engine rejects stopping Starting; do not send an invalid request.
        await CapturePhase(EngineRecordingPhase.Recording, 3);
        Assert.False(startExecution.IsCompleted);
        Assert.True(live.ToggleRecording.CanExecute(null));
        Assert.Null(live.RecordingDisabledReason);
        Assert.Equal("録音を終えて文字起こしを確定", live.RecordingHelp);
        live.ToggleRecording.Execute(null); var stopExecution = live.ToggleRecording.Execution!;
        live.ToggleRecording.Execute(null);
        var stop = await engine.NextRequestAsync();
        Assert.Equal("authoritative", Assert.IsType<EngineCommand.RecordingStop>(stop.Command).Payload.SessionID);
        await ChangedTo(store, state => state.IsPending(EngineCommandName.RecordingStop));
        await RenderAsync(dispatcher, clock);
        Assert.False(live.ToggleRecording.CanExecute(null)); Assert.True(live.IsRecordingStopping);
        Assert.Equal("録音を保存しています", live.RecordingHelp);
        await CapturePhase(EngineRecordingPhase.Stopping, 4);
        Assert.False(live.ToggleRecording.CanExecute(null));
        stop.Complete(new EngineResult.RecordingStop(new EngineSessionPayload("authoritative")));
        await stopExecution;
        // A failed start must not schedule an automatic stop or retry after the user's explicit stop.
        start.Reject(Failure(EngineErrorCode.Cancelled, "cancelled", EngineRecoveryAction.Retry));
        await startExecution;
        Assert.False(store.State.IsPending(EngineCommandName.RecordingStart));
        Assert.False(store.State.IsPending(EngineCommandName.RecordingStop));
    }

    [Theory]
    [InlineData(EngineRecordingPhase.Starting, false, true, false)]
    [InlineData(EngineRecordingPhase.Recording, true, false, false)]
    [InlineData(EngineRecordingPhase.WaitingForDevice, true, false, false)]
    [InlineData(EngineRecordingPhase.Stopping, false, false, true)]
    public async Task ToggleReflectsAuthoritativePhaseWithoutNeedingAStartRequest(
        EngineRecordingPhase phase, bool canStop, bool starting, bool stopping)
    {
        var initial = State(EngineSetupStatus.Ready, 1) with
        {
            Recording = new EngineRecordingState("existing", EngineSource.Microphone, new EngineDevice.Default(), phase)
        };
        var engine = new Fake(initial, Response(SettingsResult(1, Settings(2, false, false, false, null))));
        var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var live = new LiveViewModel(context);
        Assert.Equal(ShellRecordingAction.Stop, live.RecordingAction);
        Assert.Equal(ShellRecordingGlyph.Stop, live.RecordingGlyph);
        Assert.Equal(canStop, live.ToggleRecording.CanExecute(null));
        Assert.Equal(starting, live.IsRecordingStarting); Assert.Equal(stopping, live.IsRecordingStopping);
        Assert.Equal(starting || stopping, live.IsBusy);
        Assert.False(live.CanChangeRecordingSelection);
        Assert.Equal("録音中は切り替え不可", live.SourceHelp);
    }

    [Fact]
    public async Task TypedStatusPropertiesUseAuthoritativePresentationNotLocalizedText()
    {
        var engine = NewEngine(); var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var live = new LiveViewModel(context);
        ulong revision = 1;
        foreach (var tone in Enum.GetValues<EngineRecordingTone>())
        foreach (var indicator in Enum.GetValues<EngineProcessingIndicator>())
        foreach (var preparation in Enum.GetValues<EnginePreparationPhase>())
        {
            var presentation = new EnginePresentationState("同じ録音テキスト", tone, preparation,
                preparation is EnginePreparationPhase.Preparing or EnginePreparationPhase.Failed ? "同じ準備テキスト" : null,
                "復旧", "同じ処理テキスト", ["ライブの警告"], true, "無音", 2, "音声の欠落", indicator);
            var state = State(EngineSetupStatus.Ready, ++revision) with { Presentation = presentation };
            engine.EmitBatch(new EngineOutput(1, state.Revision, null, new EngineEvent.State(state)));
            await ChangedTo(store, current => current.Engine?.Revision == state.Revision);
            await RenderAsync(dispatcher, clock);
            Assert.Equal(tone, live.RecordingTone); Assert.Equal(indicator, live.ProcessingIndicator);
            Assert.Equal(preparation, live.PreparationPhase);
            Assert.Equal(presentation.PreparationStatusText, live.PreparationStatusText);
            Assert.Equal("同じ処理テキスト", live.ProcessingStatusText); Assert.Equal("復旧", live.RecoveryStatusText);
            Assert.Equal(indicator is EngineProcessingIndicator.Running or EngineProcessingIndicator.Backlogged, live.IsProcessing);
            Assert.Equal(preparation == EnginePreparationPhase.Preparing, live.IsPreparingModels);
            Assert.Equal(preparation == EnginePreparationPhase.Failed, live.IsPreparationFailed);
            Assert.True(live.HasLiveFailureNotices);
            Assert.False(live.IsBusy); // Model/transcript processing does not block capture operations.
        }
        var cleared = State(EngineSetupStatus.Ready, ++revision);
        engine.EmitBatch(new EngineOutput(1, cleared.Revision, null, new EngineEvent.State(cleared)));
        await ChangedTo(store, current => current.Engine?.Revision == cleared.Revision);
        await RenderAsync(dispatcher, clock);
        Assert.False(live.HasLiveFailureNotices);
    }

    [Theory]
    [InlineData(EngineScreen.Idle, null, null)]
    [InlineData(EngineScreen.Live, ShellTranscriptBadgeKind.Live, "ライブ（暫定）")]
    [InlineData(EngineScreen.Finalizing, ShellTranscriptBadgeKind.Finalizing, "確定処理中")]
    [InlineData(EngineScreen.Finalized, ShellTranscriptBadgeKind.Finalized, "確定済み")]
    public async Task TranscriptBadgeHasTypedKindAndText(EngineScreen screen, ShellTranscriptBadgeKind? kind, string? text)
    {
        var initial = State(EngineSetupStatus.Ready, 1) with { Screen = screen };
        var engine = new Fake(initial, Response(SettingsResult(1, Settings(2, false, false, false, null))));
        var clock = new ManualClock(); await using var store = await Start(engine, clock);
        var dispatcher = new TestDispatcher(); using var context = new ShellUiContext(store, dispatcher, clock);
        var live = new LiveViewModel(context);
        Assert.Equal(kind, live.TranscriptBadge?.Kind); Assert.Equal(text, live.TranscriptBadge?.Text);
        Assert.Equal(kind is not null, live.HasTranscriptHeader);
    }
}
