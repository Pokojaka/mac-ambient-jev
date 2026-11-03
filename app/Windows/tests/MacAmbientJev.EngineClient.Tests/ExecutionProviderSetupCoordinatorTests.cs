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

        var verificationTask = coordinator.VerifyAsync(bound.Result.BindingID, bound.Result.Devices[1].DeviceKey, EngineASRSize.Large, 3,
            TestContext.Current.CancellationToken);
        var verify = await session.ReadRequestAsync(3, EngineCommandName.AcceleratorsVerify);
        Assert.Equal(new EngineAcceleratorsVerifyPayload("binding-chosen", "npu:8086:1234", EngineASRSize.Large, 3),
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

    [Fact]
    public async Task RebindSavedBindsExactNamedProviderAmongSeveralAndConfirmsDevice()
    {
        await using var session = new ClientSession(false, false, false, false, EngineClientLimits.Production);
        await session.CompleteHelloAsync();
        var other = Provider("OtherProvider", "package-other");
        var saved = Provider("SavedProvider", "package-saved");
        var catalog = new ListCatalog([other, saved], new ExecutionProviderReadyResult.Ready(@"C:\p\saved.dll", new string('a', 64), []));
        var coordinator = new ExecutionProviderSetupCoordinator(catalog, session.Client);
        var rebind = coordinator.RebindSavedAsync("SavedProvider", "npu:8086:1234", new Progress<ExecutionProviderProgress>(), TestContext.Current.CancellationToken);

        var bind = await session.ReadRequestAsync(2, EngineCommandName.AcceleratorsBind);
        Assert.Equal("package-saved", Assert.IsType<EngineCommand.AcceleratorsBind>(bind.Command).Payload.Descriptor.PackageFullName);
        Assert.Same(saved, Assert.Single(catalog.Acquired));
        var devices = new[] { new EngineAcceleratorDeviceInfo("gpu:10de:2684", "gpu", "GPU", "d1", 1UL), new EngineAcceleratorDeviceInfo("npu:8086:1234", "npu", "NPU", "d2", null) };
        var result = new EngineAcceleratorsBindResult("binding-1", devices);
        await session.AcceptAndCompleteAsync(bind, new EngineResult.AcceleratorsBind(result));
        var bound = Assert.IsType<ExecutionProviderRebindResult.Bound>(await rebind.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.Equal("binding-1", bound.Result.BindingID); Assert.Equal(devices, bound.Result.Devices);

        var missing = coordinator.RebindSavedAsync("SavedProvider", "gpu:dead:beef", new Progress<ExecutionProviderProgress>(), TestContext.Current.CancellationToken);
        var second = await session.ReadRequestAsync(3, EngineCommandName.AcceleratorsBind);
        await session.AcceptAndCompleteAsync(second, new EngineResult.AcceleratorsBind(result));
        var absent = Assert.IsType<ExecutionProviderRebindResult.DeviceMissing>(await missing.WaitAsync(Guard, TestContext.Current.CancellationToken));
        Assert.Equal("gpu:dead:beef", absent.DeviceKey);
        Assert.Equal(new[] { "gpu:10de:2684", "npu:8086:1234" }, absent.AvailableDeviceKeys);
        await session.CloseAndCompleteAsync(4);
    }

    [Fact]
    public async Task RebindSavedReturnsTypedFailuresWithoutBindCommands()
    {
        await using var session = new ClientSession(false, false, false, false, EngineClientLimits.Production);
        await session.CompleteHelloAsync();
        var ready = new ExecutionProviderReadyResult.Ready(@"C:\p\saved.dll", new string('a', 64), []);
        var progress = new Progress<ExecutionProviderProgress>();
        var token = TestContext.Current.CancellationToken;

        var none = new ExecutionProviderSetupCoordinator(new ListCatalog([Provider("Other", "p1")], ready), session.Client);
        Assert.Equal(new ExecutionProviderRebindResult.ProviderMissing("Saved"), await none.RebindSavedAsync("Saved", "k", progress, token));
        var twice = new ExecutionProviderSetupCoordinator(new ListCatalog([Provider("Saved", "p1"), Provider("Saved", "p2")], ready), session.Client);
        Assert.Equal(new ExecutionProviderRebindResult.ProviderAmbiguous("Saved", 2), await twice.RebindSavedAsync("Saved", "k", progress, token));
        var failure = new ExecutionProviderReadyResult.Failure(unchecked((int)0x80070005), "denied");
        var failing = new ExecutionProviderSetupCoordinator(new ListCatalog([Provider("Saved", "p1")], failure), session.Client);
        Assert.Same(failure, Assert.IsType<ExecutionProviderRebindResult.AcquisitionFailed>(await failing.RebindSavedAsync("Saved", "k", progress, token)).Failure);
        await session.CloseAndCompleteAsync(2);
    }

    private static ExecutionProviderInfo Provider(string name, string package) =>
        new(name, package, "arm64", ExecutionProviderReadyState.NotPresent, ExecutionProviderCertification.Uncertified);

    private sealed class ListCatalog(IReadOnlyList<ExecutionProviderInfo> providers, ExecutionProviderReadyResult readiness) : IExecutionProviderCatalog
    {
        internal List<ExecutionProviderInfo> Acquired { get; } = [];
        public Task<IReadOnlyList<ExecutionProviderInfo>> FindAllProvidersAsync(CancellationToken cancellationToken) => Task.FromResult(providers);
        public Task<ExecutionProviderReadyResult> EnsureReadyAsync(ExecutionProviderInfo provider, IProgress<ExecutionProviderProgress> progress, CancellationToken cancellationToken)
        {
            Acquired.Add(provider);
            return Task.FromResult(readiness);
        }
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
