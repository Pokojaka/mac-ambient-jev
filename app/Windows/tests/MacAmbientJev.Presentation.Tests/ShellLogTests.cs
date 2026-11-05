using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using Xunit;

namespace MacAmbientJev.Presentation.Tests;

public sealed class ShellLogTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "shell-log-tests-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    [Fact]
    public void OpenCreatesFolderAndNamesFileByLocalTimeAndProcessId()
    {
        var logs = Path.Combine(_root, "nested", "logs");
        using var log = ShellLog.Open(logs, new FixedClock(Time(2026, 11, 6, 3, 4, 5)), 4321);

        Assert.Equal(Path.Combine(logs, "shell-2026-11-06_03-04-05-4321.log"), log.Path);
        Assert.Equal(logs, log.Directory);
        Assert.True(File.Exists(log.Path));
    }

    [Fact]
    public void OpenKeepsAtMostTwentyFilesByDeletingTheOldest()
    {
        Directory.CreateDirectory(_root);
        for (var day = 1; day <= 25; day++) File.WriteAllText(Path.Combine(_root, $"shell-2026-10-{day:00}_00-00-00-1.log"), "");
        File.WriteAllText(Path.Combine(_root, "other.log"), "");

        using var log = ShellLog.Open(_root, new FixedClock(Time(2026, 11, 6, 0, 0, 0)), 2);

        var names = Directory.GetFiles(_root, "shell-*.log").Select(Path.GetFileName).Order(StringComparer.Ordinal).ToArray();
        Assert.Equal(ShellLog.RetainedFiles, names.Length);
        Assert.Equal("shell-2026-10-07_00-00-00-1.log", names[0]);
        Assert.Equal("shell-2026-11-06_00-00-00-2.log", names[^1]);
        Assert.True(File.Exists(Path.Combine(_root, "other.log")));
    }

    [Fact]
    public void OpenFailsWhenTheFileAlreadyExists()
    {
        var clock = new FixedClock(Time(2026, 11, 6, 0, 0, 0));
        using var first = ShellLog.Open(_root, clock, 7);

        Assert.Throws<IOException>(() => ShellLog.Open(_root, clock, 7));
    }

    [Fact]
    public void RecordsHaveIsoTimeWithOffsetLevelAndIndentedContinuationLines()
    {
        using var log = ShellLog.Open(_root, new FixedClock(Time(2026, 11, 6, 3, 4, 5, 678)), 1);

        log.Info("hello");
        log.Warn("two\r\nlines\nthree");
        log.Error("日本語");

        using var read = new FileStream(log.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var copy = new MemoryStream();
        read.CopyTo(copy);
        var bytes = copy.ToArray();
        Assert.False(bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF);
        Assert.Equal(
            "2026-11-06T03:04:05.678+09:00 INFO hello\n" +
            "2026-11-06T03:04:05.678+09:00 WARN two\n  lines\n  three\n" +
            "2026-11-06T03:04:05.678+09:00 ERROR 日本語\n",
            System.Text.Encoding.UTF8.GetString(bytes));
    }

    [Fact]
    public void EveryRecordIsReadableBeforeDispose()
    {
        using var log = ShellLog.Open(_root, new FixedClock(Time(2026, 11, 6, 0, 0, 0)), 1);

        log.Info("first");
        Assert.Single(ReadLines(log.Path));
        log.Info("second");
        Assert.Equal(2, ReadLines(log.Path).Length);
    }

    [Fact]
    public void WriteFailureStopsTheLogAndIsReportedOnce()
    {
        var clock = new FixedClock(Time(2026, 11, 6, 0, 0, 0));
        var log = ShellLog.Open(_root, clock, 1);
        var reported = new List<Exception>();
        log.WriteFailed += reported.Add;
        log.Info("kept");
        clock.Broken = true;

        log.Info("lost");
        log.Info("ignored");

        Assert.Single(reported);
        Assert.Same(reported[0], log.Failure);
        Assert.Equal(["2026-11-06T00:00:00.000+09:00 INFO kept"], ReadLines(log.Path));
        log.Dispose();
    }

    [Fact]
    public void EngineObserverWritesLifecycleStderrAndFailureRecords()
    {
        using var log = ShellLog.Open(_root, new FixedClock(Time(2026, 11, 6, 0, 0, 0)), 1);
        var observer = new EngineLogObserver(log);

        observer.EngineStarted(@"C:\app\engine.exe", 99);
        observer.EngineStderrLine("boom");
        observer.EngineExited(3);
        observer.ClientFailed(new EngineClientFailure("lost", 3, null, new StderrSnapshot([], 0)));

        Assert.Equal(
        [
            "2026-11-06T00:00:00.000+09:00 INFO engine started: path=C:\\app\\engine.exe pid=99",
            "2026-11-06T00:00:00.000+09:00 INFO engine: boom",
            "2026-11-06T00:00:00.000+09:00 INFO engine exited: code=3",
            "2026-11-06T00:00:00.000+09:00 ERROR engine client failed: lost",
            "  exit code: 3",
            "  last engine error: none"
        ], ReadLines(log.Path));
    }

    private static string[] ReadLines(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries);
    }

    private static DateTimeOffset Time(int year, int month, int day, int hour, int minute, int second, int millisecond = 0) =>
        new(year, month, day, hour, minute, second, millisecond, TimeSpan.FromHours(9));

    private sealed class FixedClock(DateTimeOffset now) : TimeProvider
    {
        public bool Broken { get; set; }
        public override DateTimeOffset GetUtcNow() => Broken ? throw new IOException("clock failure") : now.ToUniversalTime();
        public override TimeZoneInfo LocalTimeZone { get; } = TimeZoneInfo.CreateCustomTimeZone("test", TimeSpan.FromHours(9), "test", "test");
    }
}
