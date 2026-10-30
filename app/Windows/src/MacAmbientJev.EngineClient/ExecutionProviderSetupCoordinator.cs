using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.EngineClient;

public abstract record ExecutionProviderBindResult
{
    private ExecutionProviderBindResult() { }

    public sealed record AcquisitionFailed(ExecutionProviderReadyResult.Failure Failure) : ExecutionProviderBindResult;
    public sealed record Bound(EngineAcceleratorsBindResult Result) : ExecutionProviderBindResult;
}

public sealed class ExecutionProviderSetupCoordinator
{
    private readonly IExecutionProviderCatalog _catalog;
    private readonly IEngineClient _engineClient;

    public ExecutionProviderSetupCoordinator(IExecutionProviderCatalog catalog, IEngineClient engineClient)
    {
        ArgumentNullException.ThrowIfNull(catalog);
        ArgumentNullException.ThrowIfNull(engineClient);
        _catalog = catalog;
        _engineClient = engineClient;
    }

    /// <summary>Acquires and binds one explicitly supplied provider.</summary>
    public async Task<ExecutionProviderBindResult> BindAsync(
        ExecutionProviderInfo provider,
        IProgress<ExecutionProviderProgress> progress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(provider);
        ArgumentNullException.ThrowIfNull(progress);
        cancellationToken.ThrowIfCancellationRequested();

        var readiness = await _catalog.EnsureReadyAsync(provider, progress, cancellationToken).ConfigureAwait(false);
        if (readiness is ExecutionProviderReadyResult.Failure failure)
            return new ExecutionProviderBindResult.AcquisitionFailed(failure);
        if (readiness is not ExecutionProviderReadyResult.Ready ready)
            throw new InvalidOperationException("Provider catalog returned an unexpected readiness result.");
        cancellationToken.ThrowIfCancellationRequested();

        var dependencies = ready.Dependencies
            .Select(dependency => new EngineAcceleratorDependency(dependency.Path, dependency.Hash))
            .ToArray();
        var descriptor = new EngineAcceleratorDescriptor(
            provider.Name, provider.PackageFullName, provider.PackageArchitecture,
            ready.LibraryPath, ready.LibraryHash, dependencies);
        var bindingResult = await _engineClient.SendAsync(new EngineCommand.AcceleratorsBind(
            new EngineAcceleratorsBindPayload(descriptor))).ConfigureAwait(false);
        if (bindingResult is not EngineResult.AcceleratorsBind binding)
            throw new InvalidOperationException("Engine returned an unexpected accelerator bind result.");

        cancellationToken.ThrowIfCancellationRequested();
        return new ExecutionProviderBindResult.Bound(binding.Result);
    }

    /// <summary>Verifies the explicitly supplied binding and device.</summary>
    public async Task<EngineAcceleratorsVerifyResult> VerifyAsync(
        string bindingID,
        string deviceKey,
        long threads,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrEmpty(bindingID);
        ArgumentException.ThrowIfNullOrEmpty(deviceKey);
        if (threads is < 1 or > 4) throw new ArgumentOutOfRangeException(nameof(threads));
        cancellationToken.ThrowIfCancellationRequested();

        var verifyResult = await _engineClient.SendAsync(new EngineCommand.AcceleratorsVerify(
            new EngineAcceleratorsVerifyPayload(bindingID, deviceKey, EngineASRSize.Small, threads))).ConfigureAwait(false);
        if (verifyResult is not EngineResult.AcceleratorsVerify verification)
            throw new InvalidOperationException("Engine returned an unexpected accelerator verify result.");
        return verification.Result;
    }
}
