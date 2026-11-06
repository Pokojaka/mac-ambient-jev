using System;
using System.Collections.Generic;
using System.IO;
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
    public async Task LongStderrLinesAreCappedAtExactly64KiB()
    {
        var observer = new RecordingObserver();
        var child = new FakeEngineChild(false, false, false, false);
        var client = new EngineProcessClient(child, EngineClientLimits.Production, observer);
        var text = new string('x', StderrLineSplitter.MaxLineBytes * 2 + 1);

        await child.WriteStderrAsync(Encoding.UTF8.GetBytes(text));
        child.CompleteStderr();
        child.CompleteStdout();
        child.CompleteExit(3);

        Assert.Equal(EngineClientState.Failed, await client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken));
        var lines = observer.Lines;
        Assert.Equal([StderrLineSplitter.MaxLineBytes, StderrLineSplitter.MaxLineBytes, 1], lines.Select(Encoding.UTF8.GetByteCount));
        Assert.Equal(text, string.Concat(lines));
    }

    [Fact]
    public async Task LongStderrLinesSplitOnUtf8Boundaries()
    {
        var observer = new RecordingObserver();
        var child = new FakeEngineChild(false, false, false, false);
        var client = new EngineProcessClient(child, EngineClientLimits.Production, observer);
        var text = new string('x', StderrLineSplitter.MaxLineBytes - 1) + "☃" + new string('z', StderrLineSplitter.MaxLineBytes);

        await child.WriteStderrAsync(Encoding.UTF8.GetBytes(text));
        child.CompleteStderr();
        child.CompleteStdout();
        child.CompleteExit(3);

        Assert.Equal(EngineClientState.Failed, await client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken));
        var lines = observer.Lines;
        Assert.Equal(text, string.Concat(lines));
        Assert.Equal(StderrLineSplitter.MaxLineBytes - 1, Encoding.UTF8.GetByteCount(lines[0]));
        Assert.StartsWith("☃", lines[1]);
        Assert.DoesNotContain(lines, line => line.Contains('\uFFFD'));
        Assert.All(lines, line => Assert.InRange(Encoding.UTF8.GetByteCount(line), 0, StderrLineSplitter.MaxLineBytes));
    }

    [Fact]
    public async Task StderrReadFailureFlushesTheTrailingPartialLine()
    {
        var observer = new RecordingObserver();
        var child = new FakeEngineChild(false, false, false, false);
        var client = new EngineProcessClient(child, EngineClientLimits.Production, observer);
        var stderr = Encoding.UTF8.GetBytes("partial stderr at read failure");

        await child.WriteStderrThenFailAsync(stderr, new IOException("fake stderr read failure"));
        child.CompleteStdout();
        child.CompleteExit(3);

        Assert.Equal(EngineClientState.Failed, await client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.Equal(["partial stderr at read failure"], observer.Lines);
        Assert.Equal(stderr, client.Failure!.Stderr.Bytes);
    }

    [Fact]
    public async Task ThrowingFailureObserverDoesNotStopCompletionOrStderrDraining()
    {
        var observer = new RecordingObserver { ThrowOnFailure = true };
        var child = new FakeEngineChild(false, false, false, false);
        var client = new EngineProcessClient(child, EngineClientLimits.Production, observer);

        child.CompleteStdout();
        await observer.FailureNotification.WaitAsync(Guard, TestContext.Current.CancellationToken);
        var stderr = Encoding.UTF8.GetBytes("drained after observer failure");
        await child.WriteStderrAsync(stderr);
        child.CompleteStderr();
        child.CompleteExit(3);

        Assert.Equal(EngineClientState.Failed, await client.Completion.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.True(observer.ThrowOnFailure);
        Assert.Equal(["drained after observer failure"], observer.Lines);
        Assert.Equal(stderr, client.Failure!.Stderr.Bytes);
        Assert.Contains("ClientFailed callback failed", client.Failure.Message);
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
        private readonly TaskCompletionSource _failureNotification = new(TaskCreationOptions.RunContinuationsAsynchronously);

        internal bool ThrowOnFailure { get; init; }
        internal Task FailureNotification => _failureNotification.Task;
        internal string[] Lines { get { lock (_gate) return _lines.ToArray(); } }
        internal int[] ExitCodes { get { lock (_gate) return _exitCodes.ToArray(); } }
        internal EngineClientFailure[] Failures { get { lock (_gate) return _failures.ToArray(); } }

        public void EngineStarted(string enginePath, int processId) { }
        public void EngineStderrLine(string line) { lock (_gate) _lines.Add(line); }
        public void EngineExited(int exitCode) { lock (_gate) _exitCodes.Add(exitCode); }
        public void ClientFailed(EngineClientFailure failure)
        {
            lock (_gate) _failures.Add(failure);
            _failureNotification.TrySetResult();
            if (ThrowOnFailure) throw new IOException("fake observer failure");
        }
    }
}
