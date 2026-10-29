using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.EngineClient.Tests;

public sealed partial class EngineProcessClientTests
{
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ProviderSetupBindsCatalogDescriptorThenReturnsVerificationUnchanged(bool passes)
    {
        await using var session = new ClientSession(false, false, false, false, EngineClientLimits.Production);
        await session.CompleteHelloAsync();
        var provider = new ExecutionProviderInfo("UnverifiedVendorExecutionProvider", "device-distinct", "gpu-distinct",
            "driver-distinct", "adapter-distinct", "arm64", passes ? 123456UL : null, "package-distinct");
        var dependency = new ExecutionProviderDependency(@"C:\providers\dependency.dll", new string('b', 64));
        var ready = new ExecutionProviderReadyResult.Ready(@"C:\providers\selected.dll", new string('a', 64), new[] { dependency });
        var catalog = new FakeExecutionProviderCatalog(provider, ready);
        var chosen = Assert.Single(await catalog.FindAllProvidersAsync(TestContext.Current.CancellationToken));
        var coordinator = new ExecutionProviderSetupCoordinator(catalog, session.Client);
        var setup = coordinator.SetupAsync(chosen, 3, catalog, TestContext.Current.CancellationToken);

        var bind = await session.ReadRequestAsync(2, EngineCommandName.AcceleratorsBind);
        var descriptor = Assert.IsType<EngineCommand.AcceleratorsBind>(bind.Command).Payload.Descriptor;
        Assert.Equal(provider.Name, descriptor.ProviderName);
        Assert.Equal(provider.DeviceID, descriptor.DeviceID);
        Assert.Equal(provider.GPUName, descriptor.GPUName);
        Assert.Equal(provider.DriverVersion, descriptor.DriverVersion);
        Assert.Equal(provider.AdapterID, descriptor.AdapterID);
        Assert.Equal(provider.Architecture, descriptor.Architecture);
        Assert.Equal(provider.DedicatedVRAMBytes, descriptor.DedicatedVRAMBytes);
        Assert.Equal(provider.PackageIdentity, descriptor.PackageIdentity);
        Assert.Equal(ready.LibraryPath, descriptor.LibraryPath);
        Assert.Equal(ready.LibraryHash, descriptor.LibraryHash);
        Assert.Equal(new[] { new EngineAcceleratorDependency(dependency.Path, dependency.Hash) }, descriptor.Dependencies);
        Assert.Equal(1, catalog.Calls);
        Assert.Equal(new ExecutionProviderProgress("acquiring", 0.5), catalog.LastProgress);
        Assert.False(setup.IsCompleted);

        await session.AcceptAndCompleteAsync(bind, new EngineResult.AcceleratorsBind(new EngineAcceleratorsBindResult("binding-chosen")));
        var verify = await session.ReadRequestAsync(3, EngineCommandName.AcceleratorsVerify);
        Assert.Equal(new EngineAcceleratorsVerifyPayload("binding-chosen", EngineASRSize.Small, 3),
            Assert.IsType<EngineCommand.AcceleratorsVerify>(verify.Command).Payload);
        EngineAcceleratorsVerifyResult verification = passes
            ? new EngineAcceleratorsVerifyResult.Pass("verification-pass", 0.25)
            : new EngineAcceleratorsVerifyResult.Fail("verification-fail", "exact mismatch", "unexpected output\n");
        await session.AcceptAndCompleteAsync(verify, new EngineResult.AcceleratorsVerify(verification));
        var result = await setup.WaitAsync(Guard, TestContext.Current.CancellationToken);
        Assert.Equal(verification, Assert.IsType<ExecutionProviderSetupResult.Verified>(result).Result);
        await session.CloseAndCompleteAsync(4);
    }

    [Fact]
    public async Task ProviderAcquisitionFailureReturnsHResultAndDiagnosticWithoutEngineCommands()
    {
        await using var session = new ClientSession(false, false, false, false, EngineClientLimits.Production);
        await session.CompleteHelloAsync();
        var provider = new ExecutionProviderInfo("UnverifiedVendorExecutionProvider", "device-distinct", "gpu-distinct",
            "driver-distinct", "adapter-distinct", "arm64", 654321UL, "package-distinct");
        var failure = new ExecutionProviderReadyResult.Failure(unchecked((int)0x80070005),
            "HRESULT 0x80070005: acquisition denied");
        var catalog = new FakeExecutionProviderCatalog(provider, failure);
        var coordinator = new ExecutionProviderSetupCoordinator(catalog, session.Client);
        var result = await coordinator.SetupAsync(provider, 2, catalog, TestContext.Current.CancellationToken);
        var acquired = Assert.IsType<ExecutionProviderSetupResult.AcquisitionFailed>(result);
        Assert.Same(failure, acquired.Failure);
        Assert.Equal(unchecked((int)0x80070005), acquired.Failure.HResult);
        Assert.Equal("HRESULT 0x80070005: acquisition denied", acquired.Failure.DiagnosticText);
        Assert.Equal(1, catalog.Calls);
        await session.CloseAndCompleteAsync(2);
    }

    private sealed class FakeExecutionProviderCatalog : IExecutionProviderCatalog, IProgress<ExecutionProviderProgress>
    {
        private readonly ExecutionProviderInfo _expectedProvider;
        private readonly ExecutionProviderReadyResult _readiness;
        internal int Calls { get; private set; }
        internal ExecutionProviderProgress? LastProgress { get; private set; }

        internal FakeExecutionProviderCatalog(ExecutionProviderInfo expectedProvider, ExecutionProviderReadyResult readiness)
        {
            _expectedProvider = expectedProvider;
            _readiness = readiness;
        }

        public Task<IReadOnlyList<ExecutionProviderInfo>> FindAllProvidersAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult<IReadOnlyList<ExecutionProviderInfo>>(new[] { _expectedProvider });
        }

        public Task<ExecutionProviderReadyResult> EnsureReadyAsync(ExecutionProviderInfo provider,
            IProgress<ExecutionProviderProgress> progress, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Assert.Same(_expectedProvider, provider);
            Assert.Same(this, progress);
            Assert.Equal(TestContext.Current.CancellationToken, cancellationToken);
            Calls++;
            progress.Report(new ExecutionProviderProgress("acquiring", 0.5));
            return Task.FromResult(_readiness);
        }

        public void Report(ExecutionProviderProgress value) => LastProgress = value;
    }
}
