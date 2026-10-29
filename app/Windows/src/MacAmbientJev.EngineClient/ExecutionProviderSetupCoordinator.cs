using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.EngineClient;

public abstract record ExecutionProviderSetupResult
{
    private ExecutionProviderSetupResult() { }

    public sealed record AcquisitionFailed(ExecutionProviderReadyResult.Failure Failure) : ExecutionProviderSetupResult;

    /// <summary>Verification completed; Result may represent either a pass or a fail.</summary>
    public sealed record Verified(EngineAcceleratorsVerifyResult Result) : ExecutionProviderSetupResult;
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

    /// <summary>Acquires, binds, and verifies one explicitly supplied provider.</summary>
    /// <remarks>Cancellation is observed during acquisition and between commands, not by abandoning an issued engine command.</remarks>
    public async Task<ExecutionProviderSetupResult> SetupAsync(
        ExecutionProviderInfo provider,
        long threads,
        IProgress<ExecutionProviderProgress> progress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(provider);
        ArgumentNullException.ThrowIfNull(progress);
        if (threads is < 1 or > 4) throw new ArgumentOutOfRangeException(nameof(threads));
        cancellationToken.ThrowIfCancellationRequested();

        var readiness = await _catalog.EnsureReadyAsync(provider, progress, cancellationToken).ConfigureAwait(false);
        if (readiness is ExecutionProviderReadyResult.Failure failure)
            return new ExecutionProviderSetupResult.AcquisitionFailed(failure);
        if (readiness is not ExecutionProviderReadyResult.Ready ready)
            throw new InvalidOperationException("Provider catalog returned an unexpected readiness result.");
        cancellationToken.ThrowIfCancellationRequested();

        var dependencies = ready.Dependencies
            .Select(dependency => new EngineAcceleratorDependency(dependency.Path, dependency.Hash))
            .ToArray();
        var descriptor = new EngineAcceleratorDescriptor(
            provider.Name, provider.DeviceID, provider.GPUName, provider.DriverVersion, provider.AdapterID,
            provider.Architecture, provider.DedicatedVRAMBytes, provider.PackageIdentity,
            ready.LibraryPath, ready.LibraryHash, dependencies);
        var bindingResult = await _engineClient.SendAsync(new EngineCommand.AcceleratorsBind(
            new EngineAcceleratorsBindPayload(descriptor))).ConfigureAwait(false);
        if (bindingResult is not EngineResult.AcceleratorsBind binding)
            throw new InvalidOperationException("Engine returned an unexpected accelerator bind result.");

        cancellationToken.ThrowIfCancellationRequested();
        var verifyResult = await _engineClient.SendAsync(new EngineCommand.AcceleratorsVerify(
            new EngineAcceleratorsVerifyPayload(binding.Result.BindingID, EngineASRSize.Small, threads))).ConfigureAwait(false);
        if (verifyResult is not EngineResult.AcceleratorsVerify verification)
            throw new InvalidOperationException("Engine returned an unexpected accelerator verify result.");
        return new ExecutionProviderSetupResult.Verified(verification.Result);
    }
}
