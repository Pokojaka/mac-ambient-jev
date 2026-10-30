using System.Collections.Concurrent;
using MacAmbientJev.EngineClient;
using WindowsMLCatalog = Microsoft.Windows.AI.MachineLearning.ExecutionProviderCatalog;
using WindowsMLProvider = Microsoft.Windows.AI.MachineLearning.ExecutionProvider;
using WindowsMLReadyResult = Microsoft.Windows.AI.MachineLearning.ExecutionProviderReadyResult;
using WindowsMLReadyResultState = Microsoft.Windows.AI.MachineLearning.ExecutionProviderReadyResultState;

namespace MacAmbientJev.WinUI;

internal sealed class WindowsMLExecutionProviderCatalog : IExecutionProviderCatalog
{
    private static readonly ConcurrentBag<object> RetainedResources = new();
    private readonly ConcurrentDictionary<ExecutionProviderInfo, WindowsMLProvider> providers = new();

    public Task<IReadOnlyList<ExecutionProviderInfo>> FindAllProvidersAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var catalog = WindowsMLCatalog.GetDefault() ?? throw new InvalidOperationException("Windows ML ExecutionProviderCatalog.GetDefault() returned null.");
        // CsWinRT MarshalInterfaceHelper<T>.FromAbiArray projects a null ABI data pointer as null: https://raw.githubusercontent.com/microsoft/CsWinRT/master/src/WinRT.Runtime/Marshalers.cs
        var nativeProviders = catalog.FindAllProviders() ?? [];
        List<ExecutionProviderInfo> found = new();
        foreach (var native in nativeProviders) {
            cancellationToken.ThrowIfCancellationRequested();
            // Design §3: DirectML is never a candidate; these two ORT naming variants are excluded, not aliases.
            if (string.Equals(native.Name, "DmlExecutionProvider", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(native.Name, "DirectMLExecutionProvider", StringComparison.OrdinalIgnoreCase)) continue;
            var info = new ExecutionProviderInfo(native.Name, native.PackageId.FullName,
                native.PackageId.Architecture.ToString().ToLowerInvariant(), (ExecutionProviderReadyState)native.ReadyState,
                (ExecutionProviderCertification)native.Certification);
            providers[info] = native;
            RetainedResources.Add(native);
            found.Add(info);
        }
        return Task.FromResult<IReadOnlyList<ExecutionProviderInfo>>(found);
    }

    public async Task<ExecutionProviderReadyResult> EnsureReadyAsync(ExecutionProviderInfo provider,
        IProgress<ExecutionProviderProgress> progress, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(provider);
        ArgumentNullException.ThrowIfNull(progress);
        cancellationToken.ThrowIfCancellationRequested();
        if (!providers.TryGetValue(provider, out var native))
            throw new InvalidOperationException("The selected execution provider is unknown; rediscover providers before acquisition.");
        WindowsMLReadyResult result;
        try {
            var operation = native.EnsureReadyAsync();
            RetainedResources.Add(operation);
            result = await operation.AsTask(cancellationToken,
                new Progress<double>(value => progress.Report(new(native.Name, value / 100.0)))).ConfigureAwait(false);
            RetainedResources.Add(result);
        } catch (OperationCanceledException) { throw; }
        catch (Exception exception) { return new ExecutionProviderReadyResult.Failure(exception.HResult, exception.Message); }
        if (result.Status != WindowsMLReadyResultState.Success) {
            var error = result.ExtendedError ?? throw new InvalidOperationException($"Windows ML acquisition returned {result.Status} without an ExtendedError.");
            return new ExecutionProviderReadyResult.Failure(error.HResult, result.DiagnosticText);
        }
        if (native.PackageId.FullName != provider.PackageFullName ||
            native.PackageId.Architecture.ToString().ToLowerInvariant() != provider.PackageArchitecture)
            throw new InvalidOperationException("The Windows ML provider identity changed during acquisition; rediscover providers before using its library path.");
        try { return ExecutionProviderPackageClosure.Resolve(provider.PackageFullName, native.LibraryPath, cancellationToken); }
        catch (OperationCanceledException) { throw; }
        catch (Exception exception) { return new ExecutionProviderReadyResult.Failure(exception.HResult, exception.Message); }
    }
}
