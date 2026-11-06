using System.Globalization;
using System.Text;
using MacAmbientJev.EngineClient;

namespace MacAmbientJev.Presentation;

public enum ShellLogLevel { Info, Warn, Error }

/// <summary>Writes one shell log file per launch and keeps the newest <see cref="RetainedFiles"/> files.</summary>
public sealed class ShellLog : IDisposable
{
    public const int RetainedFiles = 20;

    private readonly object _gate = new();
    private readonly TimeProvider _clock;
    private readonly FileStream _stream;
    private Exception? _failure;
    private bool _stopped, _disposed;

    private ShellLog(TimeProvider clock, FileStream stream, string path)
    {
        _clock = clock;
        _stream = stream;
        Path = path;
    }

    public string Path { get; }
    public string Directory => System.IO.Path.GetDirectoryName(Path)!;

    /// <summary>Gets the first write failure; after it the log writes nothing more.</summary>
    public Exception? Failure { get { lock (_gate) return _failure; } }

    /// <summary>Gets a startup log-retention failure that was written to this log.</summary>
    public Exception? StartupFailure { get; private set; }

    /// <summary>Raised once, on the writing thread, when a write fails.</summary>
    public event Action<Exception>? WriteFailed;

    public static ShellLog Open(string logsDirectory, TimeProvider clock, int processId, Action<string> deleteFile)
    {
        ArgumentException.ThrowIfNullOrEmpty(logsDirectory);
        ArgumentNullException.ThrowIfNull(clock);
        ArgumentNullException.ThrowIfNull(deleteFile);
        System.IO.Directory.CreateDirectory(logsDirectory);
        var name = $"shell-{clock.GetLocalNow().ToString("yyyy-MM-dd_HH-mm-ss", CultureInfo.InvariantCulture)}-{processId.ToString(CultureInfo.InvariantCulture)}.log";
        var path = System.IO.Path.Combine(logsDirectory, name);
        var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 1);
        var log = new ShellLog(clock, stream, path);
        try
        {
            var older = System.IO.Directory.GetFiles(logsDirectory, "shell-*.log").Where(file => file != path).OrderBy(file => file, StringComparer.Ordinal).ToArray();
            foreach (var file in older.Take(Math.Max(0, older.Length - (RetainedFiles - 1)))) deleteFile(file);
        }
        catch (Exception exception)
        {
            log.StartupFailure = exception;
            log.Error("Old shell log pruning failed: " + exception);
        }

        return log;
    }

    public void Info(string message) => Write(ShellLogLevel.Info, message);
    public void Warn(string message) => Write(ShellLogLevel.Warn, message);
    public void Error(string message) => Write(ShellLogLevel.Error, message);

    public void Write(ShellLogLevel level, string message)
    {
        ArgumentNullException.ThrowIfNull(message);
        Exception? failure = null;
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_stopped) return;
            try
            {
                var bytes = new UTF8Encoding(false).GetBytes(Format(_clock.GetLocalNow(), level, message));
                _stream.Write(bytes);
                _stream.Flush();
            }
            catch (Exception exception)
            {
                _stopped = true;
                _failure = failure = exception;
            }
        }

        if (failure is not null) WriteFailed?.Invoke(failure);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            _stream.Dispose();
        }
    }

    private static string Format(DateTimeOffset time, ShellLogLevel level, string message)
    {
        var lines = message.Replace("\r\n", "\n").Split('\n');
        var text = new StringBuilder()
            .Append(time.ToString("yyyy-MM-dd'T'HH:mm:ss.fffzzz", CultureInfo.InvariantCulture))
            .Append(' ').Append(level.ToString().ToUpperInvariant()).Append(' ').Append(lines[0]).Append('\n');
        for (var index = 1; index < lines.Length; index++) text.Append("  ").Append(lines[index]).Append('\n');
        return text.ToString();
    }
}

/// <summary>Writes engine process and stderr notifications to the shell log.</summary>
public sealed class EngineLogObserver(ShellLog log) : IEngineObserver
{
    public void EngineStarted(string enginePath, int processId) => log.Info($"engine started: path={enginePath} pid={processId}");
    public void EngineStderrLine(string line) => log.Info("engine: " + line);
    public void EngineExited(int exitCode) => log.Info($"engine exited: code={exitCode}");

    public void ClientFailed(EngineClientFailure failure) => log.Error(
        $"engine client failed: {failure.Message}\nexit code: {failure.ExitCode?.ToString() ?? "unknown"}\nlast engine error: {(failure.LastEngineError is { } error ? $"{error.Code}: {error.Message}" : "none")}");
}
