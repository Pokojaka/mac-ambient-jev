using System;
using System.Collections.Generic;
using System.Text;
using System.Threading.Tasks;
using MacAmbientJev.EngineClient;
using Xunit;

namespace MacAmbientJev.EngineClient.Tests;

public sealed class EngineObserverTests
{
    private static readonly TimeSpan Guard = TimeSpan.FromSeconds(10);

    [Fact]
    public async Task StderrIsSplitOnLineFeedAcrossReadsWithCarriageReturnsTrimmedAndTrailingTextFlushedAtEof()
    {
        var observer = new RecordingObserver();
        var child = new FakeEngineChild(false, false, false, false);
        var client = new EngineProcessClient(child, EngineClientLimits.Production, observer);
        var snowman = Encoding.UTF8.GetBytes("snow ☃ man");

        await child.WriteStderrAsync(Encoding.UTF8.GetBytes("one\r\ntw"));
        await child.WriteStderrAsync(Encoding.UTF8.GetBytes("o\n\nthree\n"));
        await child.WriteStderrAsync(snowman[..7]);
        await child.WriteStderrAsync(snowman[7..]);
        child.CompleteStderr();
        await child.StderrEofObserved.WaitAsync(Guard, TestContext.Current.CancellationToken);

        Assert.Equal(["one", "two", "", "three", "snow ☃ man"], observer.Lines);
        child.CompleteStdout();
        child.CompleteExit(0);
        await client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken);
    }

    [Fact]
    public async Task ExitAndFailureAreReported()
    {
        var observer = new RecordingObserver();
        var child = new FakeEngineChild(false, false, false, false);
        var client = new EngineProcessClient(child, EngineClientLimits.Production, observer);

        child.CompleteStdout();
        child.CompleteStderr();
        child.CompleteExit(3);
        Assert.Equal(EngineClientState.Failed, await client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken));

        Assert.Equal([3], observer.ExitCodes);
        var failure = Assert.Single(observer.Failures);
        Assert.Contains("stdout reached EOF", failure.Message);
    }

    private sealed class RecordingObserver : IEngineObserver
    {
        private readonly object _gate = new();
        private readonly List<string> _lines = new();
        private readonly List<int> _exitCodes = new();
        private readonly List<EngineClientFailure> _failures = new();

        internal string[] Lines { get { lock (_gate) return _lines.ToArray(); } }
        internal int[] ExitCodes { get { lock (_gate) return _exitCodes.ToArray(); } }
        internal EngineClientFailure[] Failures { get { lock (_gate) return _failures.ToArray(); } }

        public void EngineStarted(string enginePath, int processId) { }
        public void EngineStderrLine(string line) { lock (_gate) _lines.Add(line); }
        public void EngineExited(int exitCode) { lock (_gate) _exitCodes.Add(exitCode); }
        public void ClientFailed(EngineClientFailure failure) { lock (_gate) _failures.Add(failure); }
    }
}
