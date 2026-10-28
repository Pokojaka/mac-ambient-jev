using System;
using System.IO;
using System.Threading.Tasks;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Protocol;
using Xunit;
namespace MacAmbientJev.Engine.Tests;

public sealed class EngineSmokeTests
{
    private static readonly TimeSpan Guard = TimeSpan.FromSeconds(30);
    [Fact]
    public async Task ProductionEngineEnforcesSingleProcessPerLocalDataDirectory()
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("The production engine smoke test requires Windows.");
        const string enginePathVariable = "MAC_AMBIENT_JEV_TEST_ENGINE_PATH";
        var enginePath = Environment.GetEnvironmentVariable(enginePathVariable);
        if (string.IsNullOrWhiteSpace(enginePath))
            throw new InvalidOperationException($"Required environment variable {enginePathVariable} must contain an absolute engine executable path.");
        if (!Path.IsPathFullyQualified(enginePath))
            throw new InvalidOperationException($"Environment variable {enginePathVariable} must contain an absolute path; received '{enginePath}'.");
        var root = Path.Combine(Path.GetTempPath(), $"MacAmbientJev.Engine.Tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            using var child1 = ProcessEngineChild.Start(enginePath, ["--local-app-data", root]);
            var client1 = new EngineProcessClient(child1, EngineClientLimits.Production);
            try
            {
                var cancellationToken = TestContext.Current.CancellationToken;
                var firstHello = Assert.IsType<EngineResult.Hello>(await client1.Hello.WaitAsync(Guard, cancellationToken));
                Assert.Equal(EngineSetupStatus.SettingsRequired, firstHello.Result.State.Setup);
                using var child2 = ProcessEngineChild.Start(enginePath, ["--local-app-data", root]);
                var client2 = new EngineProcessClient(child2, EngineClientLimits.Production);
                try
                {
                    await Assert.ThrowsAsync<EngineClientFailedException>(() => client2.Hello.WaitAsync(Guard, cancellationToken));
                    Assert.Equal(EngineClientState.Failed, await client2.Completion.WaitAsync(Guard, cancellationToken));
                    Assert.Equal(2, await child2.Exit.WaitAsync(Guard, cancellationToken));
                }
                finally { await CleanupClientAsync(client2, child2); }
                await client1.CloseAsync().WaitAsync(Guard, cancellationToken);
                Assert.Equal(EngineClientState.Closed, await client1.Completion.WaitAsync(Guard, cancellationToken));
                Assert.Equal(0, await child1.Exit.WaitAsync(Guard, cancellationToken));
            }
            finally { await CleanupClientAsync(client1, child1); }
        }
        finally { Directory.Delete(root, recursive: true); }
    }
    private static async Task CleanupClientAsync(EngineProcessClient client, ProcessEngineChild child)
    {
        if (!client.Completion.IsCompleted) client.ForceKill();
        await client.Completion.WaitAsync(Guard);
        try { await client.DisposeAsync().AsTask().WaitAsync(Guard); }
        catch (EngineClientFailedException) { }
        await child.Exit.WaitAsync(Guard);
    }
}
