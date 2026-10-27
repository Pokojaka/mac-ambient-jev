using MacAmbientJev.Protocol;

namespace MacAmbientJev.EngineClient;

/// <summary>Represents the redirected standard streams and lifetime of an engine child process.</summary>
public interface IEngineChild : IDisposable
{
    Stream StandardInput { get; }
    Stream StandardOutput { get; }
    Stream StandardError { get; }
    Task<int> Exit { get; }
    void Kill();
}

public enum EngineClientState
{
    Running,
    Closing,
    Closed,
    Failed
}

public enum EngineExitKind
{
    RequestedShutdownOrEof,
    Startup,
    Protocol,
    Input,
    Output,
    Shutdown,
    FatalCapture,
    Unknown
}

public static class EngineExitCodes
{
    public static EngineExitKind Classify(int exitCode) => exitCode switch
    {
        0 => EngineExitKind.RequestedShutdownOrEof,
        2 => EngineExitKind.Startup,
        3 => EngineExitKind.Protocol,
        4 => EngineExitKind.Input,
        5 => EngineExitKind.Output,
        6 => EngineExitKind.Shutdown,
        7 => EngineExitKind.FatalCapture,
        _ => EngineExitKind.Unknown
    };
}

/// <summary>Bounds ordinary pending requests and queued outbound bytes; one stop and one shutdown control may be pending separately, for a total pending capacity of <see cref="OrdinaryPending"/> + 2.</summary>
public sealed record EngineClientLimits(int OrdinaryPending, int OutgoingBytes)
{
    public static EngineClientLimits Production { get; } = new(14, 4 * 1024 * 1024);

    internal void Validate()
    {
        if (OrdinaryPending is < 1 or > 14)
        {
            throw new ArgumentOutOfRangeException(nameof(OrdinaryPending));
        }

        if (OutgoingBytes is < 1 or > 4 * 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(nameof(OutgoingBytes));
        }
    }
}

public sealed record StderrSnapshot(byte[] Bytes, long DiscardedBytes);

public sealed record EngineClientFailure(
    string Message,
    int? ExitCode,
    EngineFailure? LastEngineError,
    StderrSnapshot Stderr);

public sealed class EngineClientFailedException : Exception
{
    public EngineClientFailure Failure { get; }

    public EngineClientFailedException(EngineClientFailure failure) : base(failure.Message)
    {
        Failure = failure;
    }
}

public sealed class EngineRequestException : Exception
{
    public EngineFailure Failure { get; }

    public EngineRequestException(EngineFailure failure) : base(failure.Message)
    {
        Failure = failure;
    }
}

public sealed class EngineClientOverloadedException : InvalidOperationException
{
    public EngineClientOverloadedException(string message) : base(message) { }
}
