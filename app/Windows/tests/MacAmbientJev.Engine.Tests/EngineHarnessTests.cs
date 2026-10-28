using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Protocol;
using Xunit;
namespace MacAmbientJev.Engine.Tests;
public sealed class EngineHarnessTests
{
    private static readonly TimeSpan Guard = TimeSpan.FromSeconds(30), Publication = TimeSpan.FromSeconds(180);
    private const string Transcript = "エンジンの受け入れテストです。";
    [Fact]
    public async Task RecordingFinalizesPagesAndExportsIdenticalBundles()
    {
        var token = TestContext.Current.CancellationToken; var harness = HarnessPath();
        await using var test = TestWorkspace.Create();
        var (child, client) = test.Start(harness);
        await PrepareFreshAsync(client, token);
        var session = await StartRecordingAsync(client, token);
        var watch = Assert.IsType<EngineResult.TranscriptWatch>(await SendAsync(client,
            new EngineCommand.TranscriptWatch(new EngineSessionPayload(session)), token));
        Assert.Equal(session, watch.Result.SessionID);
        var stop = Assert.IsType<EngineResult.RecordingStop>(await SendAsync(client,
            new EngineCommand.RecordingStop(new EngineSessionPayload(session)), token));
        Assert.Equal(session, stop.Result.SessionID);
        await WaitFinalizedAsync(client, session, token); await AssertTranscriptAsync(client, session, token);
        var first = await ExportAsync(test, client, session, token); var second = await ExportAsync(test, client, session, token);
        Assert.Equal(first.DestinationPath, second.DestinationPath);
        foreach (var name in first.Names) Assert.Equal(first.Files[name], second.Files[name]);
        await ShutdownAsync(child, client, token);
    }
    [Fact]
    public async Task EofDurablyStopsAndNewProcessRecoversSession()
    {
        var token = TestContext.Current.CancellationToken; var harness = HarnessPath();
        await using var test = TestWorkspace.Create();
        var (child, client) = test.Start(harness);
        await PrepareFreshAsync(client, token);
        var session = await StartRecordingAsync(client, token);
        child.StandardInput.Dispose();
        Assert.Equal(0, await AwaitEventsAsync(client, child.Exit, token));
        Assert.Equal(EngineClientState.Failed, await AwaitEventsAsync(client, client.Completion, token));
        await RecoverAsync(test, harness, session, token);
    }
    [Fact]
    public async Task KilledRecordingIsRecoveredByTestStartedProcess()
    {
        var token = TestContext.Current.CancellationToken; var harness = HarnessPath();
        await using var test = TestWorkspace.Create();
        var (child, client) = test.Start(harness);
        await PrepareFreshAsync(client, token);
        var session = await StartRecordingAsync(client, token);
        child.Kill();
        Assert.NotEqual(0, await AwaitEventsAsync(client, child.Exit, token));
        Assert.Equal(EngineClientState.Failed, await AwaitEventsAsync(client, client.Completion, token));
        await RecoverAsync(test, harness, session, token);
    }
    private static string HarnessPath()
    {
        const string variable = "MAC_AMBIENT_JEV_TEST_HARNESS_PATH"; var path = Environment.GetEnvironmentVariable(variable);
        if (string.IsNullOrWhiteSpace(path)) throw new InvalidOperationException($"Required environment variable {variable} must contain an absolute harness executable path.");
        if (!Path.IsPathFullyQualified(path)) throw new InvalidOperationException($"Environment variable {variable} must contain an absolute path; received '{path}'.");
        return path;
    }
    private static EngineSettings ExpectedSettings() => new(SchemaVersion: 1, Source: EngineSource.Microphone,
        Device: new EngineDevice.Default(), AsrSize: EngineASRSize.Small, ExecutionProvider: EngineExecutionProvider.Cpu,
        Threads: 1, LowHeat: false, DecisionsEnabled: false, AutomaticExport: false, ExportDestinationPath: null);
    private static async Task<string> StartRecordingAsync(EngineProcessClient client, CancellationToken token)
    {
        var start = Assert.IsType<EngineResult.RecordingStart>(await SendAsync(client,
            new EngineCommand.RecordingStart(new EngineRecordingStartPayload(
                EngineSource.Microphone, new EngineDevice.Default())), token));
        var session = start.Result.SessionID;
        var state = await StateAsync(client, token);
        Assert.Equal(EngineScreen.Live, state.Screen);
        Assert.Equal(session, state.Recording?.SessionID);
        Assert.Equal(EngineRecordingPhase.Recording, state.Recording?.Phase);
        return session;
    }
    private static async Task PrepareFreshAsync(EngineProcessClient client, CancellationToken token)
    {
        var hello = Assert.IsType<EngineResult.Hello>(await AwaitEventsAsync(client, client.Hello, token));
        Assert.Equal(EngineSetupStatus.SettingsRequired, hello.Result.State.Setup);
        var result = Assert.IsType<EngineResult.SettingsReplace>(await SendAsync(client,
            new EngineCommand.SettingsReplace(new EngineSettingsReplacePayload(null, ExpectedSettings())), token));
        Assert.Equal(ExpectedSettings(), result.Result.Settings);
        _ = Assert.IsType<EngineResult.ModelsPrepare>(await SendAsync(client, new EngineCommand.ModelsPrepare(new EngineEmptyPayload()), token));
        await WaitRecoveryAsync(client, token);
    }
    private static async Task RecoverAsync(TestWorkspace test, string harness, string session, CancellationToken token)
    {
        var (child, client) = test.Start(harness);
        _ = Assert.IsType<EngineResult.Hello>(await AwaitEventsAsync(client, client.Hello, token));
        var settings = Assert.IsType<EngineResult.SettingsGet>(await SendAsync(client, new EngineCommand.SettingsGet(new EngineEmptyPayload()), token));
        Assert.Equal(ExpectedSettings(), settings.Result.Settings);
        _ = Assert.IsType<EngineResult.ModelsPrepare>(await SendAsync(client, new EngineCommand.ModelsPrepare(new EngineEmptyPayload()), token));
        await WaitRecoveryAsync(client, token);
        await WaitFinalizedAsync(client, session, token);
        var catalog = await CatalogAsync(client, token);
        Assert.Equal(session, Assert.Single(catalog).SessionID);
        await AssertTranscriptAsync(client, session, token); await ShutdownAsync(child, client, token);
    }
    private static async Task<EngineState> StateAsync(EngineProcessClient client, CancellationToken token) =>
        Assert.IsType<EngineResult.StateGet>(await SendAsync(client, new EngineCommand.StateGet(new EngineEmptyPayload()), token)).Result;
    private static Task WaitRecoveryAsync(EngineProcessClient client, CancellationToken token) => PollUntilAsync(async cancellationToken =>
    {
        var state = await StateAsync(client, cancellationToken);
        if (state.Recovery == EngineRecoveryStatus.Failed) Assert.Fail("Engine recovery failed.");
        return state.Recovery == EngineRecoveryStatus.Completed && state.Queue.Length == 0;
    }, token);
    private static Task WaitFinalizedAsync(EngineProcessClient client, string session, CancellationToken token) => PollUntilAsync(async cancellationToken =>
    {
        var catalog = await CatalogAsync(client, cancellationToken);
        Assert.True(catalog.Length <= 1, "The scenario catalog contains more than one session.");
        var match = catalog.SingleOrDefault();
        if (match is not null) Assert.Equal(session, match.SessionID);
        var state = await StateAsync(client, cancellationToken);
        if (state.Recovery == EngineRecoveryStatus.Failed) Assert.Fail("Engine recovery failed while waiting for finalization.");
        if (match?.Status == EngineSessionStatus.Failed) Assert.Fail($"Session finalization failed: {match.Error}");
        return match?.Status == EngineSessionStatus.Finalized && state.Queue.Length == 0;
    }, token);
    private static async Task PollUntilAsync(Func<CancellationToken, Task<bool>> condition, CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(Publication);
        while (!await condition(deadline.Token)) await Task.Delay(250, deadline.Token);
    }
    private static async Task<EngineSessionSummary[]> CatalogAsync(EngineProcessClient client, CancellationToken token)
    {
        var page = Assert.IsType<EngineResult.SessionList>(await SendAsync(client,
            new EngineCommand.SessionList(new EngineSessionListPayload(null, 100)), token)).Result;
        return page.Sessions;
    }
    private static async Task AssertTranscriptAsync(EngineProcessClient client, string session, CancellationToken token)
    {
        var page = Assert.IsType<EngineResult.TranscriptRead>(await SendAsync(client,
            new EngineCommand.TranscriptRead(new EngineTranscriptReadPayload(session, null, null, 1)), token)).Result;
        Assert.Equal(session, page.SessionID);
        Assert.Collection(page.Rows, row =>
        {
            Assert.Equal(Transcript, row.Text);
            Assert.Equal(new[] { EngineSpeakerLabel.Speaker1 }, row.Headings);
        });
    }
    private static async Task<ExportSnapshot> ExportAsync(TestWorkspace test, EngineProcessClient client, string session, CancellationToken token) {
        var result = Assert.IsType<EngineResult.SessionExport>(await SendAsync(client,
            new EngineCommand.SessionExport(new EngineExportPayload(session, test.ExportDirectory)), token)).Result;
        Assert.Equal(session, result.SessionID);
        var destination = Path.GetFullPath(result.DestinationPath);
        var entries = Directory.GetFileSystemEntries(destination);
        var names = entries.Select(path => Path.GetFileName(path)!).OrderBy(name => name, StringComparer.Ordinal).ToArray();
        Assert.Equal(new[] { "audio.flac", "transcript.txt" }, names);
        var files = names.ToDictionary(name => name, name => File.ReadAllBytes(Path.Combine(destination, name)), StringComparer.Ordinal);
        Assert.NotEmpty(files["audio.flac"]);
        Assert.Equal(Encoding.UTF8.GetBytes("[00:00] Speaker 1: " + Transcript + "\n"), files["transcript.txt"]);
        return new ExportSnapshot(destination, names, files);
    }
    private static async Task ShutdownAsync(ProcessEngineChild child, EngineProcessClient client, CancellationToken token)
    { await AwaitEventsAsync(client, client.CloseAsync(), token); Assert.Equal(EngineClientState.Closed, await AwaitEventsAsync(client, client.Completion, token)); Assert.Equal(0, await AwaitEventsAsync(client, child.Exit, token)); }
    private static Task<EngineResult> SendAsync(EngineProcessClient client, EngineCommand command, CancellationToken token) =>
        AwaitEventsAsync(client, client.SendAsync(command), token);
    private static async Task<T> AwaitEventsAsync<T>(EngineProcessClient client, Task<T> operation, CancellationToken token)
    {
        var result = await operation.WaitAsync(Guard, token);
        DrainEvents(client);
        return result;
    }
    private static async Task AwaitEventsAsync(EngineProcessClient client, Task operation, CancellationToken token)
    {
        await operation.WaitAsync(Guard, token);
        DrainEvents(client);
    }
    private static void DrainEvents(EngineProcessClient client)
    {
        foreach (var output in client.DrainEvents())
            if (output.RequestID is null && output.Event is EngineEvent.Error error && error.Payload.Severity is EngineSeverity.Error or EngineSeverity.Fatal) Assert.Fail($"Background engine error: {error.Payload}");
    }
    private sealed record ExportSnapshot(string DestinationPath, string[] Names, Dictionary<string, byte[]> Files);
    private sealed class TestWorkspace : IAsyncDisposable
    {
        private readonly List<(ProcessEngineChild Child, EngineProcessClient Client)> _started = new();
        private TestWorkspace(string owner, string root, string fixture, string exports)
        { Owner = owner; Root = root; Fixture = fixture; ExportDirectory = exports; }
        internal string Owner { get; }
        internal string Root { get; }
        internal string Fixture { get; }
        internal string ExportDirectory { get; }
        internal static TestWorkspace Create()
        {
            var owner = Path.GetFullPath(Path.Combine(Path.GetTempPath(), $"MacAmbientJev.EngineHarnessTests-{Guid.NewGuid():N}"));
            Directory.CreateDirectory(owner);
            var root = Path.Combine(owner, "root"); var fixture = Path.Combine(owner, "fixture.f32le"); var exports = Path.Combine(owner, "exports");
            Directory.CreateDirectory(root); Directory.CreateDirectory(exports);
            using var writer = new BinaryWriter(new FileStream(fixture, FileMode.CreateNew, FileAccess.Write, FileShare.None));
            for (var frame = 0; frame < 33_000; frame++) writer.Write((frame - 16_000) / 32_768f);
            return new TestWorkspace(owner, root, fixture, exports);
        }
        internal (ProcessEngineChild Child, EngineProcessClient Client) Start(string harness)
        {
            var child = ProcessEngineChild.Start(harness, ["--root", Root, "--fixture", Fixture, "--sample-rate", "16000", "--channels", "1", "--inference", "deterministic", "--threads", "1"]);
            var client = new EngineProcessClient(child, EngineClientLimits.Production);
            _started.Add((child, client)); return (child, client);
        }
        public async ValueTask DisposeAsync()
        {
            var failures = new List<Exception>();
            foreach (var (child, client) in _started.AsEnumerable().Reverse())
            {
                try
                {
                    if (!child.Exit.IsCompleted) client.ForceKill();
                    await child.Exit.WaitAsync(Guard);
                    await client.Completion.WaitAsync(Guard);
                    try { await client.DisposeAsync().AsTask().WaitAsync(Guard); } catch (EngineClientFailedException) { }
                }
                catch (Exception error) { failures.Add(error); }
            }
            try { if (Directory.Exists(Owner)) Directory.Delete(Owner, recursive: true); } catch (Exception error) { failures.Add(error); }
            if (failures.Count != 0) throw new AggregateException("Harness test cleanup failed.", failures);
        }
    }
}
