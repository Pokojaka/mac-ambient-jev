using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace MacAmbientJev.EngineClient;

/// <summary>Discovers and acquires execution providers for explicit setup.</summary>
/// <remarks>
/// Discovery returns all providers without preference or vendor filtering. Ready means acquisition succeeded only,
/// not that compatibility was verified. Implementations retain acquired resources until engine exit, discover fresh
/// paths for each launch, and do not persist library paths.
/// </remarks>
public interface IExecutionProviderCatalog
{
    Task<IReadOnlyList<ExecutionProviderInfo>> FindAllProvidersAsync(CancellationToken cancellationToken);
    Task<ExecutionProviderReadyResult> EnsureReadyAsync(
        ExecutionProviderInfo provider,
        IProgress<ExecutionProviderProgress> progress,
        CancellationToken cancellationToken);
}

public sealed record ExecutionProviderInfo(
    string Name,
    string DeviceID,
    string GPUName,
    string DriverVersion,
    string AdapterID,
    string Architecture,
    ulong? DedicatedVRAMBytes,
    string PackageIdentity);

public sealed record ExecutionProviderDependency(string Path, string Hash);

/// <param name="Fraction">Null indicates indeterminate progress; otherwise the value is between 0 and 1.</param>
public sealed record ExecutionProviderProgress(string Message, double? Fraction);

public abstract record ExecutionProviderReadyResult
{
    private ExecutionProviderReadyResult() { }

    public sealed record Ready(
        string LibraryPath,
        string LibraryHash,
        IReadOnlyList<ExecutionProviderDependency> Dependencies) : ExecutionProviderReadyResult;

    public sealed record Failure(int HResult, string DiagnosticText) : ExecutionProviderReadyResult;
}
