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
        var provider = new ExecutionProviderInfo("UnverifiedVendorExecutionProvider", "package-distinct", "arm64",
            ExecutionProviderReadyState.NotPresent, ExecutionProviderCertification.Uncertified);
        var dependency = new ExecutionProviderDependency(@"C:\providers\dependency.dll", new string('b', 64));
        var ready = new ExecutionProviderReadyResult.Ready(@"C:\providers\selected.dll", new string('a', 64), new[] { dependency });
        var catalog = new FakeExecutionProviderCatalog(provider, ready);
        var coordinator = new ExecutionProviderSetupCoordinator(catalog, session.Client);
        var binding = coordinator.BindAsync(provider, catalog, TestContext.Current.CancellationToken);

        var bind = await session.ReadRequestAsync(2, EngineCommandName.AcceleratorsBind);
        var descriptor = Assert.IsType<EngineCommand.AcceleratorsBind>(bind.Command).Payload.Descriptor;
        Assert.Equal(provider.Name, descriptor.ProviderName);
        Assert.Equal(provider.PackageFullName, descriptor.PackageFullName);
        Assert.Equal(provider.PackageArchitecture, descriptor.PackageArchitecture);
        Assert.Equal(ready.LibraryPath, descriptor.LibraryPath);
        Assert.Equal(ready.LibraryHash, descriptor.LibraryHash);
        Assert.Equal(new[] { new EngineAcceleratorDependency(dependency.Path, dependency.Hash) }, descriptor.Dependencies);
        Assert.Equal(1, catalog.Calls);
        Assert.Equal(new ExecutionProviderProgress("acquiring", 0.5), catalog.LastProgress);
        Assert.False(binding.IsCompleted);

        var devices = new[]
        {
            new EngineAcceleratorDeviceInfo("gpu:10de:2684", "gpu", "Engine GPU", "engine-driver", 123UL),
            new EngineAcceleratorDeviceInfo("npu:8086:1234", "npu", "Engine NPU", "npu-driver", null),
        };
        var bindingResult = new EngineAcceleratorsBindResult("binding-chosen", devices);
        await session.AcceptAndCompleteAsync(bind, new EngineResult.AcceleratorsBind(bindingResult));
        var bound = Assert.IsType<ExecutionProviderBindResult.Bound>(await binding.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.Equal(bindingResult.BindingID, bound.Result.BindingID);
        Assert.Equal(devices, bound.Result.Devices);

        var verificationTask = coordinator.VerifyAsync(bound.Result.BindingID, bound.Result.Devices[1].DeviceKey, 3,
            TestContext.Current.CancellationToken);
        var verify = await session.ReadRequestAsync(3, EngineCommandName.AcceleratorsVerify);
        Assert.Equal(new EngineAcceleratorsVerifyPayload("binding-chosen", "npu:8086:1234", EngineASRSize.Small, 3),
            Assert.IsType<EngineCommand.AcceleratorsVerify>(verify.Command).Payload);
        EngineAcceleratorsVerifyResult verification = passes
            ? new EngineAcceleratorsVerifyResult.Pass("verification-pass", 0.25)
            : new EngineAcceleratorsVerifyResult.Fail("verification-fail", "exact mismatch", "unexpected output\n");
        await session.AcceptAndCompleteAsync(verify, new EngineResult.AcceleratorsVerify(verification));
        Assert.Equal(verification, await verificationTask.WaitAsync(Guard, TestContext.Current.CancellationToken));
        await session.CloseAndCompleteAsync(4);
    }

    [Fact]
    public async Task ProviderAcquisitionFailureReturnsHResultAndDiagnosticWithoutEngineCommands()
    {
        await using var session = new ClientSession(false, false, false, false, EngineClientLimits.Production);
        await session.CompleteHelloAsync();
        var provider = new ExecutionProviderInfo("UnverifiedVendorExecutionProvider", "package-distinct", "arm64",
            ExecutionProviderReadyState.NotPresent, ExecutionProviderCertification.Uncertified);
        var failure = new ExecutionProviderReadyResult.Failure(unchecked((int)0x80070005),
            "HRESULT 0x80070005: acquisition denied");
        var catalog = new FakeExecutionProviderCatalog(provider, failure);
        var coordinator = new ExecutionProviderSetupCoordinator(catalog, session.Client);
        var result = await coordinator.BindAsync(provider, catalog, TestContext.Current.CancellationToken);
        var acquired = Assert.IsType<ExecutionProviderBindResult.AcquisitionFailed>(result);
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
