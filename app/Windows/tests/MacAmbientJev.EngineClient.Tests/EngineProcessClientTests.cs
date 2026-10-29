using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.EngineClient.Tests;

public sealed partial class EngineProcessClientTests
{
    private static readonly TimeSpan Guard = TimeSpan.FromSeconds(10);
    [Fact]
    public async Task HelloIsFirstRequestAndWaitsForBothReadersToStart()
    {
        await using var session = new ClientSession(false, false, false, false, EngineClientLimits.Production);
        var hello = await session.ReadRequestAsync(1, EngineCommandName.Hello);
        Assert.True(session.Child.ReadersStartedBeforeFirstWrite);
        await session.AcceptAndCompleteAsync(hello, Fixtures.HelloResult);
        Assert.IsType<EngineResult.Hello>(await session.Client.Hello.WaitAsync(Guard, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task CorrelatedRequestsRemainPendingAcrossUnsolicitedOutputsAndResolveByID()
    {
        await using var session = new ClientSession(false, false, false, false, EngineClientLimits.Production);
        await session.CompleteHelloAsync();
        var first = session.Client.SendAsync(new EngineCommand.StateGet(new EngineEmptyPayload()));
        var second = session.Client.SendAsync(new EngineCommand.ModelsPrepare(new EngineEmptyPayload()));
        var firstRequest = await session.ReadRequestAsync(2, EngineCommandName.StateGet);
        var secondRequest = await session.ReadRequestAsync(3, EngineCommandName.ModelsPrepare);
        await session.EmitAcceptedAsync(firstRequest);
        await session.EmitAcceptedAsync(secondRequest);
        await session.EmitAsync(Fixtures.Ready, null);
        await session.EmitAsync(Fixtures.State(101), firstRequest.RequestID);
        await session.EmitAsync(Fixtures.Progress(1), firstRequest.RequestID);
        await session.EmitAsync(Fixtures.Rows(102), firstRequest.RequestID);
        await session.EmitAsync(Fixtures.Error(null), null);
        var barrier = session.Client.SendAsync(new EngineCommand.StateGet(new EngineEmptyPayload()));
        var barrierRequest = await session.ReadRequestAsync(4, EngineCommandName.StateGet);
        await session.AcceptAndCompleteAsync(barrierRequest, Fixtures.StateGetResult);
        Assert.IsType<EngineResult.StateGet>(await barrier.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.False(first.IsCompleted);
        Assert.False(second.IsCompleted);
        await session.EmitCompletedAsync(secondRequest, Fixtures.ModelsPrepareResult);
        Assert.IsType<EngineResult.ModelsPrepare>(await second.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.False(first.IsCompleted);
        await session.EmitCompletedAsync(firstRequest, Fixtures.StateGetResult);
        Assert.IsType<EngineResult.StateGet>(await first.WaitAsync(Guard, TestContext.Current.CancellationToken));
        await session.CloseAndCompleteAsync(5);
    }

    [Fact]
    public async Task CorrelatedAdmissionErrorFailsOnlyItsRequestAndClientKeepsRunning()
    {
        await using var session = new ClientSession(false, false, false, false, EngineClientLimits.Production);
        await session.CompleteHelloAsync();
        var rejected = session.Client.SendAsync(new EngineCommand.StateGet(new EngineEmptyPayload()));
        var pending = session.Client.SendAsync(new EngineCommand.ModelsPrepare(new EngineEmptyPayload()));
        var rejectedRequest = await session.ReadRequestAsync(2, EngineCommandName.StateGet);
        var pendingRequest = await session.ReadRequestAsync(3, EngineCommandName.ModelsPrepare);
        var failure = Fixtures.Error(rejectedRequest.RequestID);
        await session.EmitAsync(failure, rejectedRequest.RequestID);
        var exception = await Assert.ThrowsAsync<EngineRequestException>(() => rejected.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.Equal(failure.Payload.Code, exception.Failure.Code);
        Assert.Equal(failure.Payload.Message, exception.Failure.Message);
        Assert.Equal(failure.Payload.RequestID, exception.Failure.RequestID);
        Assert.Equal(EngineClientState.Running, session.Client.State);
        Assert.False(pending.IsCompleted);
        await session.AcceptAndCompleteAsync(pendingRequest, Fixtures.ModelsPrepareResult);
        Assert.IsType<EngineResult.ModelsPrepare>(await pending.WaitAsync(Guard, TestContext.Current.CancellationToken));
        await session.CloseAndCompleteAsync(4);
    }

    [Theory]
    [InlineData("duplicate-completed")]
    [InlineData("result-command-mismatch")]
    [InlineData("duplicate-accepted")]
    [InlineData("completed-before-accepted")]
    [InlineData("sequence-repeated")]
    [InlineData("sequence-backwards")]
    [InlineData("first-sequence-not-one")]
    public async Task ProtocolViolationFailsPendingRequestsAndContinuesDraining(string violation)
    {
        await using var session = new ClientSession(false, false, false, false, EngineClientLimits.Production);
        if (violation == "first-sequence-not-one")
        {
            var hello = await session.ReadRequestAsync(1, EngineCommandName.Hello);
            await session.EmitAtSequenceAsync(2, new EngineEvent.Accepted(new EngineAcceptedPayload(hello.Command.Name)), hello.RequestID);
            await Assert.ThrowsAsync<EngineClientFailedException>(() => session.Client.Hello.WaitAsync(Guard, TestContext.Current.CancellationToken));
        }
        else
        {
            await session.CompleteHelloAsync();
            var first = session.Client.SendAsync(new EngineCommand.StateGet(new EngineEmptyPayload()));
            var second = session.Client.SendAsync(new EngineCommand.ModelsPrepare(new EngineEmptyPayload()));
            var firstRequest = await session.ReadRequestAsync(2, EngineCommandName.StateGet);
            var secondRequest = await session.ReadRequestAsync(3, EngineCommandName.ModelsPrepare);
            if (violation == "duplicate-completed")
            {
                await session.EmitAcceptedAsync(firstRequest);
                await session.EmitCompletedAsync(firstRequest, Fixtures.StateGetResult);
                Assert.IsType<EngineResult.StateGet>(await first.WaitAsync(Guard, TestContext.Current.CancellationToken));
                await session.EmitCompletedAsync(firstRequest, Fixtures.StateGetResult);
            }
            else if (violation == "result-command-mismatch")
            {
                await session.EmitAcceptedAsync(firstRequest);
                await session.EmitCompletedAsync(firstRequest, Fixtures.ModelsPrepareResult);
            }
            else if (violation == "duplicate-accepted")
            {
                await session.EmitAcceptedAsync(firstRequest);
                await session.EmitAcceptedAsync(firstRequest);
            }
            else if (violation == "completed-before-accepted")
            {
                await session.EmitCompletedAsync(firstRequest, Fixtures.StateGetResult);
            }
            else
            {
                await session.EmitAtSequenceAsync(3,
                    new EngineEvent.Accepted(new EngineAcceptedPayload(firstRequest.Command.Name)), firstRequest.RequestID);
                var badSequence = violation == "sequence-repeated" ? 3UL : 2UL;
                await session.EmitAtSequenceAsync(badSequence,
                    new EngineEvent.Accepted(new EngineAcceptedPayload(secondRequest.Command.Name)), secondRequest.RequestID);
            }
            if (violation != "duplicate-completed")
                await Assert.ThrowsAsync<EngineClientFailedException>(() => first.WaitAsync(Guard, TestContext.Current.CancellationToken));
            await Assert.ThrowsAsync<EngineClientFailedException>(() => second.WaitAsync(Guard, TestContext.Current.CancellationToken));
        }
        Assert.Equal(EngineClientState.Failed, session.Client.State);
        await session.Child.InputClosed.WaitAsync(Guard, TestContext.Current.CancellationToken);
        await Assert.ThrowsAsync<EngineClientFailedException>(async () =>
            await session.Client.SendAsync(new EngineCommand.StateGet(new EngineEmptyPayload())));
        Assert.Null(await session.Child.ReadRequestAsync().WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.Equal(0, session.Child.KillCalls);
        await session.Child.WriteStderrAsync(new byte[] { 0x00, 0x81, 0xFF });
        session.EndProcess(0);
        Assert.Equal(EngineClientState.Failed, await session.Client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.Equal(new byte[] { 0x00, 0x81, 0xFF }, session.Client.Failure!.Stderr.Bytes);
    }

    [Fact]
    public async Task OutputInboxCoalescesOnlyStateProgressAndRowsWhileRetainingReliableOutputs()
    {
        await using var session = new ClientSession(false, true, false, false, EngineClientLimits.Production);
        var hello = await session.ReadRequestAsync(1, EngineCommandName.Hello);
        var stateTask = session.Client.SendAsync(new EngineCommand.StateGet(new EngineEmptyPayload()));
        var barrierTask = session.Client.SendAsync(new EngineCommand.ModelsPrepare(new EngineEmptyPayload()));
        var rejectedTask = session.Client.SendAsync(new EngineCommand.StateGet(new EngineEmptyPayload()));
        var stateRequest = await session.ReadRequestAsync(2, EngineCommandName.StateGet);
        var barrierRequest = await session.ReadRequestAsync(3, EngineCommandName.ModelsPrepare);
        var rejectedRequest = await session.ReadRequestAsync(4, EngineCommandName.StateGet);
        await session.EmitAcceptedAsync(hello);
        await session.EmitCompletedAsync(hello, Fixtures.HelloResult);
        await session.EmitAsync(Fixtures.Ready, null);
        await session.EmitAcceptedAsync(stateRequest);
        const ulong burstCount = 32;
        for (ulong revision = 1; revision <= burstCount; revision++)
        {
            await session.EmitAsync(Fixtures.State(revision), null);
            await session.EmitAsync(Fixtures.Progress(revision), null);
            await session.EmitAsync(Fixtures.Rows(revision), null);
        }
        await session.EmitCompletedAsync(stateRequest, Fixtures.StateGetResult);
        await session.EmitAsync(Fixtures.Error(null), null);
        var requestError = Fixtures.Error(rejectedRequest.RequestID);
        await session.EmitAsync(requestError, rejectedRequest.RequestID);
        await session.EmitAcceptedAsync(barrierRequest);
        await session.EmitCompletedAsync(barrierRequest, Fixtures.ModelsPrepareResult);
        session.Child.ReleaseStdoutReads();
        Assert.IsType<EngineResult.Hello>(await session.Client.Hello.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.IsType<EngineResult.StateGet>(await stateTask.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.IsType<EngineResult.ModelsPrepare>(await barrierTask.WaitAsync(Guard, TestContext.Current.CancellationToken));
        var requestFailure = (await Assert.ThrowsAsync<EngineRequestException>(
            () => rejectedTask.WaitAsync(Guard, TestContext.Current.CancellationToken))).Failure;
        Assert.Equal(requestError.Payload.Code, requestFailure.Code);
        Assert.Equal(requestError.Payload.Message, requestFailure.Message);
        Assert.Equal(requestError.Payload.RequestID, requestFailure.RequestID);
        var outputs = session.Client.DrainEvents();
        Assert.Single(outputs, output => output.Event is EngineEvent.Ready);
        var states = outputs.Select(output => output.Event).OfType<EngineEvent.State>().ToArray();
        var progress = outputs.Select(output => output.Event).OfType<EngineEvent.Progress>().ToArray();
        var rows = outputs.Select(output => output.Event).OfType<EngineEvent.Rows>().ToArray();
        Assert.Single(states);
        Assert.Equal(burstCount, states[0].Payload.Revision.Value);
        Assert.Single(progress);
        Assert.Equal((ulong)burstCount, progress[0].Payload.CompletedUnits);
        Assert.Single(rows);
        Assert.Equal(burstCount, rows[0].Payload.Revision.Value);
        Assert.Equal(EngineRowsKind.ReloadRequired, rows[0].Payload.Kind);
        Assert.Empty(rows[0].Payload.Rows);
        Assert.Empty(rows[0].Payload.RemovedRowIDs);
        Assert.Null(rows[0].Payload.NextCursor);
        Assert.Equal(3, outputs.Count(output => output.Event is EngineEvent.Accepted));
        Assert.Equal(3, outputs.Count(output => output.Event is EngineEvent.Completed));
        Assert.Equal(2, outputs.Count(output => output.Event is EngineEvent.Error));
        await session.CloseAndCompleteAsync(5);
    }

    [Fact]
    public async Task PendingCapacityIncludesOneStopAndOneShutdownLane()
    {
        await using var session = new ClientSession(false, false, false, false, EngineClientLimits.Production);
        await session.CompleteHelloAsync();
        var ordinary = new List<Task<EngineResult>>();
        for (var index = 0; index < 14; index++)
            ordinary.Add(session.Client.SendAsync(new EngineCommand.StateGet(new EngineEmptyPayload())));
        for (ulong id = 2; id <= 15; id++)
            await session.ReadRequestAsync(id, EngineCommandName.StateGet);
        Assert.Throws<EngineClientOverloadedException>((Action)(() =>
        {
            _ = session.Client.SendAsync(new EngineCommand.StateGet(new EngineEmptyPayload()));
        }));
        var stop = session.Client.SendAsync(new EngineCommand.RecordingStop(new EngineSessionPayload("test-session")));
        var stopRequest = await session.ReadRequestAsync(16, EngineCommandName.RecordingStop);
        Assert.Throws<EngineClientOverloadedException>((Action)(() =>
        {
            _ = session.Client.SendAsync(new EngineCommand.RecordingStop(new EngineSessionPayload("another-session")));
        }));
        var close = session.Client.CloseAsync();
        Assert.Equal(EngineClientState.Closing, session.Client.State);
        Assert.Throws<InvalidOperationException>((Action)(() =>
        {
            _ = session.Client.SendAsync(new EngineCommand.StateGet(new EngineEmptyPayload()));
        }));
        Assert.Equal(16, session.Client.PendingCount);
        var shutdownRequest = await session.ReadRequestAsync(17, EngineCommandName.Shutdown);
        for (ulong id = 2; id <= 15; id++)
        {
            await session.EmitAcceptedAsync(new EngineRequest(1, new EngineID(id), new EngineCommand.StateGet(new EngineEmptyPayload())));
            await session.EmitCompletedAsync(new EngineRequest(1, new EngineID(id), new EngineCommand.StateGet(new EngineEmptyPayload())), Fixtures.StateGetResult);
        }
        await session.AcceptAndCompleteAsync(stopRequest, Fixtures.RecordingStopResult);
        await session.AcceptAndCompleteAsync(shutdownRequest, Fixtures.ShutdownResult);
        await Task.WhenAll(ordinary).WaitAsync(Guard, TestContext.Current.CancellationToken);
        Assert.IsType<EngineResult.RecordingStop>(await stop.WaitAsync(Guard, TestContext.Current.CancellationToken));
        await session.Child.InputClosed.WaitAsync(Guard, TestContext.Current.CancellationToken);
        session.EndProcess(0);
        await close.WaitAsync(Guard, TestContext.Current.CancellationToken);
        Assert.Equal(EngineClientState.Closed, await session.Client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task OutgoingByteLimitCountsHelloWhileItsWriteIsHeld()
    {
        var helloBytes = EngineCodec.EncodeRequest(new EngineRequest(1, new EngineID(1),
            new EngineCommand.Hello(new EngineEmptyPayload()))).Length;
        var ordinaryBytesID2 = EngineCodec.EncodeRequest(new EngineRequest(1, new EngineID(2),
            new EngineCommand.StateGet(new EngineEmptyPayload()))).Length;
        var ordinaryBytesID3 = EngineCodec.EncodeRequest(new EngineRequest(1, new EngineID(3),
            new EngineCommand.StateGet(new EngineEmptyPayload()))).Length;
        var outgoingLimit = helloBytes + Math.Min(ordinaryBytesID2, ordinaryBytesID3);
        await using var session = new ClientSession(true, false, false, false,
            new EngineClientLimits(14, outgoingLimit));
        await session.Child.FirstInputWriteStarted.WaitAsync(Guard, TestContext.Current.CancellationToken);
        Assert.Equal(helloBytes, session.Client.OutgoingByteCount);
        var accepted = session.Client.SendAsync(new EngineCommand.StateGet(new EngineEmptyPayload()));
        Assert.Equal(helloBytes + ordinaryBytesID2, session.Client.OutgoingByteCount);
        Assert.Throws<EngineClientOverloadedException>((Action)(() =>
        {
            _ = session.Client.SendAsync(new EngineCommand.StateGet(new EngineEmptyPayload()));
        }));
        Assert.Equal(EngineClientState.Running, session.Client.State);
        session.Child.ReleaseInputWrites();
        var hello = await session.ReadRequestAsync(1, EngineCommandName.Hello);
        var ordinary = await session.ReadRequestAsync(2, EngineCommandName.StateGet);
        await session.AcceptAndCompleteAsync(hello, Fixtures.HelloResult);
        await session.AcceptAndCompleteAsync(ordinary, Fixtures.StateGetResult);
        Assert.IsType<EngineResult.StateGet>(await accepted.WaitAsync(Guard, TestContext.Current.CancellationToken));
        await session.CloseAndCompleteAsync(3);
    }

    [Theory]
    [InlineData(0, EngineExitKind.RequestedShutdownOrEof)]
    [InlineData(2, EngineExitKind.Startup)]
    [InlineData(3, EngineExitKind.Protocol)]
    [InlineData(4, EngineExitKind.Input)]
    [InlineData(5, EngineExitKind.Output)]
    [InlineData(6, EngineExitKind.Shutdown)]
    [InlineData(7, EngineExitKind.FatalCapture)]
    [InlineData(23, EngineExitKind.Unknown)]
    public async Task UnexpectedExitRetainsCodeClassificationLastErrorAndStderr(int exitCode, EngineExitKind expectedKind)
    {
        await using var session = new ClientSession(false, false, false, false, EngineClientLimits.Production);
        await session.CompleteHelloAsync();
        var expectedError = Fixtures.Error(null).Payload;
        await session.EmitAsync(Fixtures.Error(null), null);
        var stderr = new byte[] { 0x00, 0x81, 0xFF };
        await session.Child.WriteStderrAsync(stderr);
        session.EndProcess(exitCode);
        Assert.Equal(EngineClientState.Failed, await session.Client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken));
        var failure = session.Client.Failure!;
        Assert.Equal(exitCode, failure.ExitCode);
        Assert.Equal(expectedKind, EngineExitCodes.Classify(exitCode));
        Assert.Equal(expectedError.Code, failure.LastEngineError!.Code);
        Assert.Equal(expectedError.Message, failure.LastEngineError.Message);
        Assert.Equal(stderr, failure.Stderr.Bytes);
        Assert.Equal(0L, failure.Stderr.DiscardedBytes);
    }

    [Fact]
    public async Task StderrFloodRetainsOnlyLatest256KiBAndCountsDiscardedBytes()
    {
        await using var session = new ClientSession(false, false, false, false, EngineClientLimits.Production);
        await session.CompleteHelloAsync();
        var stderr = Enumerable.Range(0, 256 * 1024 + 8192).Select(index => (byte)(index * 37)).ToArray();
        await session.Child.WriteStderrAsync(stderr);
        session.EndProcess(23);
        Assert.Equal(EngineClientState.Failed, await session.Client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken));
        var expectedTail = stderr[^ (256 * 1024)..];
        var expectedDiscarded = stderr.Length - expectedTail.Length;
        var clientStderr = session.Client.Stderr;
        var failureStderr = session.Client.Failure!.Stderr;
        Assert.Equal(expectedTail, clientStderr.Bytes);
        Assert.Equal(expectedDiscarded, clientStderr.DiscardedBytes);
        Assert.Equal(expectedTail, failureStderr.Bytes);
        Assert.Equal(expectedDiscarded, failureStderr.DiscardedBytes);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task BufferedShutdownSucceedsWhenExitAndOutputEofRace(bool exitBeforeDrainingOutput)
    {
        await using var session = new ClientSession(false, true, false, false, EngineClientLimits.Production);
        var hello = await session.ReadRequestAsync(1, EngineCommandName.Hello);
        var close = session.Client.CloseAsync();
        var shutdown = await session.ReadRequestAsync(2, EngineCommandName.Shutdown);
        await session.AcceptAndCompleteAsync(hello, Fixtures.HelloResult);
        await session.AcceptAndCompleteAsync(shutdown, Fixtures.ShutdownResult);
        session.Child.CompleteStdout();
        session.Child.CompleteStderr();
        if (exitBeforeDrainingOutput)
        {
            session.Child.CompleteExit(0);
            Assert.True(session.Client.IsStillWaiting);
            session.Child.ReleaseStdoutReads();
        }
        else
        {
            session.Child.ReleaseStdoutReads();
            await session.Child.StdoutEofObserved.WaitAsync(Guard, TestContext.Current.CancellationToken);
            await session.Child.StderrEofObserved.WaitAsync(Guard, TestContext.Current.CancellationToken);
            Assert.True(session.Client.IsStillWaiting);
            session.Child.CompleteExit(0);
        }
        await close.WaitAsync(Guard, TestContext.Current.CancellationToken);
        Assert.IsType<EngineResult.Hello>(await session.Client.Hello.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.Equal(EngineClientState.Closed, await session.Client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.Equal(0, session.Child.KillCalls);
    }

    [Fact]
    public async Task GracefulShutdownWaitsForStdinCloseBothOutputEofsAndProcessExit()
    {
        await using var session = new ClientSession(false, false, false, false, EngineClientLimits.Production);
        await session.CompleteHelloAsync();
        var close = session.Client.CloseAsync();
        var shutdown = await session.ReadRequestAsync(2, EngineCommandName.Shutdown);
        await session.AcceptAndCompleteAsync(shutdown, Fixtures.ShutdownResult);
        await session.Child.InputClosed.WaitAsync(Guard, TestContext.Current.CancellationToken);
        Assert.Equal(EngineClientState.Closing, session.Client.State);
        Assert.True(session.Client.IsStillWaiting);
        Assert.False(close.IsCompleted);
        session.Child.CompleteStdout();
        await session.Child.StdoutEofObserved.WaitAsync(Guard, TestContext.Current.CancellationToken);
        Assert.False(close.IsCompleted);
        session.Child.CompleteStderr();
        await session.Child.StderrEofObserved.WaitAsync(Guard, TestContext.Current.CancellationToken);
        Assert.True(session.Client.IsStillWaiting);
        Assert.False(close.IsCompleted);
        session.Child.CompleteExit(0);
        await close.WaitAsync(Guard, TestContext.Current.CancellationToken);
        Assert.Equal(EngineClientState.Closed, await session.Client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.Equal(0, session.Child.KillCalls);
    }

    [Fact]
    public async Task ForceKillOccursOnlyAfterExplicitCallAndFailsStalledClose()
    {
        await using var session = new ClientSession(false, false, false, false, EngineClientLimits.Production);
        await session.CompleteHelloAsync();
        var close = session.Client.CloseAsync();
        var shutdown = await session.ReadRequestAsync(2, EngineCommandName.Shutdown);
        await session.EmitAcceptedAsync(shutdown);
        Assert.Equal(0, session.Child.KillCalls);
        Assert.True(session.Client.IsStillWaiting);
        Assert.False(close.IsCompleted);
        session.Client.ForceKill();
        Assert.Equal(1, session.Child.KillCalls);
        Assert.Equal(EngineClientState.Failed, session.Client.State);
        session.EndProcess(7);
        Assert.Equal(EngineClientState.Failed, await session.Client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<EngineClientFailedException>(() => close.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.Equal(1, session.Child.KillCalls);
    }

    [Theory]
    [InlineData("write")]
    [InlineData("flush")]
    [InlineData("ndjson")]
    public async Task TransportFaultFailsFastAndStillDrainsBothOutputStreams(string fault)
    {
        await using var session = new ClientSession(false, false,
            fault == "write", fault == "flush", EngineClientLimits.Production);
        if (fault == "ndjson")
        {
            await session.ReadRequestAsync(1, EngineCommandName.Hello);
            await session.Child.WriteRawStdoutAsync(Encoding.UTF8.GetBytes("not-json\n"));
        }
        else
        {
            await session.Child.FirstInputWriteStarted.WaitAsync(Guard, TestContext.Current.CancellationToken);
            await Assert.ThrowsAsync<EngineClientFailedException>(() => session.Client.Hello.WaitAsync(Guard, TestContext.Current.CancellationToken));
            await session.Child.InputClosed.WaitAsync(Guard, TestContext.Current.CancellationToken);
            await session.Child.WriteRawStdoutAsync(Encoding.UTF8.GetBytes("not-json\n"));
        }
        if (fault == "ndjson")
            await Assert.ThrowsAsync<EngineClientFailedException>(() => session.Client.Hello.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.Equal(EngineClientState.Failed, session.Client.State);
        await session.Child.InputClosed.WaitAsync(Guard, TestContext.Current.CancellationToken);
        await session.Child.WriteRawStdoutAsync(new byte[] { 0x00, 0xFF, 0x81 });
        var stderr = new byte[] { 0xFF, 0x00, 0x82, 0x7F };
        await session.Child.WriteStderrAsync(stderr);
        session.EndProcess(0);
        Assert.Equal(EngineClientState.Failed, await session.Client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken));
        await session.Child.StdoutEofObserved.WaitAsync(Guard, TestContext.Current.CancellationToken);
        await session.Child.StderrEofObserved.WaitAsync(Guard, TestContext.Current.CancellationToken);
        Assert.Equal(stderr, session.Client.Failure!.Stderr.Bytes);
        Assert.Equal(0, session.Child.KillCalls);
    }

    private sealed class ClientSession : IAsyncDisposable
    {
        private ulong _sequence;
        internal FakeEngineChild Child { get; }
        internal EngineProcessClient Client { get; }
        internal ClientSession(bool holdInputWrites, bool holdStdoutReads, bool failWrite, bool failFlush, EngineClientLimits limits) {
            Child = new FakeEngineChild(holdInputWrites, holdStdoutReads, failWrite, failFlush);
            Client = new EngineProcessClient(Child, limits);
        }
        internal async Task<EngineRequest> ReadRequestAsync(ulong expectedID, EngineCommandName expectedCommand)
        {
            var request = await Child.ReadRequestAsync().WaitAsync(Guard, TestContext.Current.CancellationToken);
            Assert.NotNull(request);
            Assert.Equal(expectedID, request.RequestID.Value);
            Assert.Equal(expectedCommand, request.Command.Name);
            return request;
        }
        internal async Task CompleteHelloAsync() {
            var request = await ReadRequestAsync(1, EngineCommandName.Hello);
            await AcceptAndCompleteAsync(request, Fixtures.HelloResult);
            Assert.IsType<EngineResult.Hello>(await Client.Hello.WaitAsync(Guard, TestContext.Current.CancellationToken));
        }
        internal async Task CloseAndCompleteAsync(ulong shutdownID) {
            var close = Client.CloseAsync();
            var shutdown = await ReadRequestAsync(shutdownID, EngineCommandName.Shutdown);
            await AcceptAndCompleteAsync(shutdown, Fixtures.ShutdownResult);
            await Child.InputClosed.WaitAsync(Guard, TestContext.Current.CancellationToken);
            EndProcess(0);
            await close.WaitAsync(Guard, TestContext.Current.CancellationToken);
            Assert.Equal(EngineClientState.Closed, await Client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken));
        }
        internal void EndProcess(int exitCode) { Child.CompleteStdout(); Child.CompleteStderr(); Child.CompleteExit(exitCode); }
        internal Task EmitAcceptedAsync(EngineRequest request) =>
            EmitAsync(new EngineEvent.Accepted(new EngineAcceptedPayload(request.Command.Name)), request.RequestID);
        internal Task EmitCompletedAsync(EngineRequest request, EngineResult result) =>
            EmitAsync(new EngineEvent.Completed(result), request.RequestID);
        internal async Task AcceptAndCompleteAsync(EngineRequest request, EngineResult result) { await EmitAcceptedAsync(request); await EmitCompletedAsync(request, result); }
        internal Task EmitAsync(EngineEvent outputEvent, EngineID? requestID) =>
            EmitAtSequenceAsync(++_sequence, outputEvent, requestID);
        internal Task EmitAtSequenceAsync(ulong sequence, EngineEvent outputEvent, EngineID? requestID) =>
            Child.EmitAsync(new EngineOutput(1, new EngineID(sequence), requestID, outputEvent));
        public async ValueTask DisposeAsync() {
            if (Client.Completion.IsCompleted) return;
            Child.ReleaseInputWrites(); Child.ReleaseStdoutReads(); EndProcess(0);
            await Client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken);
        }
    }

    private static class Fixtures
    {
        private static readonly Lazy<EngineOutput[]> Outputs = new(LoadOutputs);
        internal static EngineEvent.Ready Ready => Event<EngineEvent.Ready>();
        internal static EngineEvent State(ulong revision) => new EngineEvent.State(Event<EngineEvent.State>().Payload with { Revision = new EngineID(revision) });
        internal static EngineEvent Progress(ulong units) =>
            new EngineEvent.Progress(Event<EngineEvent.Progress>().Payload with { CompletedUnits = units, TotalUnits = null });
        internal static EngineEvent Rows(ulong revision) => new EngineEvent.Rows(Event<EngineEvent.Rows>().Payload with { Revision = new EngineID(revision) });
        internal static EngineEvent.Error Error(EngineID? requestID) => new EngineEvent.Error(Event<EngineEvent.Error>().Payload with { RequestID = requestID });
        internal static EngineResult.Hello HelloResult => Result<EngineResult.Hello>(EngineCommandName.Hello);
        internal static EngineResult.StateGet StateGetResult => Result<EngineResult.StateGet>(EngineCommandName.StateGet);
        internal static EngineResult.ModelsPrepare ModelsPrepareResult => Result<EngineResult.ModelsPrepare>(EngineCommandName.ModelsPrepare);
        internal static EngineResult.RecordingStop RecordingStopResult => Result<EngineResult.RecordingStop>(EngineCommandName.RecordingStop);
        internal static EngineResult.Shutdown ShutdownResult => Result<EngineResult.Shutdown>(EngineCommandName.Shutdown);
        private static T Event<T>() where T : EngineEvent =>
            Outputs.Value.Select(output => output.Event).OfType<T>().First();
        private static T Result<T>(EngineCommandName command) where T : EngineResult =>
            (T)Outputs.Value.Select(output => output.Event).OfType<EngineEvent.Completed>()
                .Select(completed => completed.Payload).First(result => result.Command == command);
        private static EngineOutput[] LoadOutputs()
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "wire-v1.ndjson");
            var outputs = new List<EngineOutput>();
            foreach (var line in File.ReadLines(path))
            {
                using var document = JsonDocument.Parse(line);
                if (document.RootElement.TryGetProperty("event", out _))
                    outputs.Add(EngineCodec.DecodeOutput(Encoding.UTF8.GetBytes(line)));
            }
            return outputs.ToArray();
        }
    }
}
