using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Presentation.Tests;

public sealed partial class ShellStoreTests
{
    [Fact]
    public async Task UnsolicitedDeviceLostWarningPublishesDismissibleNoticeWithoutStopping()
    {
        var engine = new Fake(State(EngineSetupStatus.Ready, 1), Response(SettingsResult(1, Settings(2, false, false, false, null))));
        await using var store = await Start(engine);
        var failure = Failure(EngineErrorCode.DeviceLost, "選択したデバイスが切断されました。", EngineRecoveryAction.SelectDevice) with { Stage = EngineStage.Capture, SessionID = "lost-session", Severity = EngineSeverity.Warning };
        var changed = ChangedTo(store, state => state.LastError == failure && state.DeviceLostNotice is not null);
        engine.EmitBatch(new EngineOutput(1, new EngineID(1), null, new EngineEvent.Error(failure)));
        var state = await changed;
        var notice = Assert.IsType<DeviceLostNotice>(state.DeviceLostNotice);
        Assert.Equal(failure.Message, notice.Message); Assert.Equal(failure.SessionID, notice.SessionID); Assert.Equal(ShellPhase.Running, state.Phase);
        await store.DismissDeviceLostNoticeAsync(notice);
        var dismissed = await ChangedTo(store, current => current.DeviceLostNotice is null);
        Assert.Null(dismissed.DeviceLostNotice); Assert.Equal(failure, dismissed.LastError);
    }

    [Theory]
    [InlineData(EngineErrorCode.CaptureFailure, EngineSeverity.Fatal)]
    [InlineData(EngineErrorCode.DeviceFailure, EngineSeverity.Error)]
    [InlineData(EngineErrorCode.DeviceLost, EngineSeverity.Error)]
    public async Task OtherUnsolicitedErrorsUpdateLastErrorWithoutNotice(EngineErrorCode code, EngineSeverity severity)
    {
        var engine = new Fake(State(EngineSetupStatus.Ready, 1), Response(SettingsResult(1, Settings(2, false, false, false, null))));
        await using var store = await Start(engine);
        var failure = Failure(code, "engine error", EngineRecoveryAction.Retry) with { SessionID = "error-session", Severity = severity };
        var changed = ChangedTo(store, state => state.LastError == failure);
        engine.EmitBatch(new EngineOutput(1, new EngineID(1), null, new EngineEvent.Error(failure)));
        var state = await changed;
        Assert.Equal(failure, state.LastError); Assert.Null(state.DeviceLostNotice);
    }
}
