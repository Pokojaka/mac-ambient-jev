using System.Collections.Immutable;
using System.Threading.Channels;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

/// <summary>Owns the immutable shell snapshot, not the engine client's lifetime.</summary>
public sealed partial class ShellStore : IAsyncDisposable
{
    private sealed class Work(Action action)
    {
        internal Action Action { get; } = action;
        internal TaskCompletionSource Acknowledgement { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal Exception? Error { get; set; }
    }

    private readonly IEngineClient _client;
    private readonly TimeProvider _timeProvider;
    private readonly Channel<Work> _work = Channel.CreateUnbounded<Work>(new UnboundedChannelOptions { SingleReader = true, AllowSynchronousContinuations = false });
    private readonly CancellationTokenSource _stop = new();
    private readonly object _postGate = new();
    private ShellState _working = new(), _published = new();
    private ulong? _stateRevision;
    private bool _disposeRequested;
    private Task? _disposeTask;
    private readonly Task _reducerTask, _watcherTask, _initialization;

    public ShellStore(IEngineClient client) : this(client, TimeProvider.System) { }

    public ShellStore(IEngineClient client, TimeProvider timeProvider)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _timeProvider = timeProvider ?? throw new ArgumentNullException(nameof(timeProvider));
        _reducerTask = Task.Run(ReduceAsync);
        _watcherTask = Task.Run(WatchEventsAsync);
        _initialization = Task.Run(InitializeAsync);
    }

    /// <summary>Returns the latest atomically published immutable snapshot.</summary>
    public ShellState State => Volatile.Read(ref _published);
    /// <summary>Raised once per changed reducer batch, on the background reducer thread.</summary>
    public event EventHandler? Changed;
    public Task Initialization => _initialization;

    public async Task SetSettingsDraftAsync(EngineSettings? draft)
    {
        await Post(() => _working = _working with { SettingsDraft = draft, CommandError = null }).ConfigureAwait(false);
    }

    public Task<bool> ReloadSettingsAsync() => RunRequestAsync(() => new EngineCommand.SettingsGet(new EngineEmptyPayload()));
    public Task<bool> ReloadDevicesAsync(EngineSource source)
    {
        if (!Enum.IsDefined(source)) throw new ArgumentOutOfRangeException(nameof(source), source, "Unknown engine source.");
        return RunRequestAsync(() => new EngineCommand.DevicesList(new EngineDevicesListPayload(source)));
    }

    public Task<bool> ImportAudioAsync(string inputPath)
    {
        ArgumentException.ThrowIfNullOrEmpty(inputPath);
        return RunRequestAsync(() =>
        {
            if (_working.Engine?.Recording is not null || _working.Pending.Contains(EngineCommandName.RecordingStart) || _working.Pending.Contains(EngineCommandName.RecordingStop))
            { _working = _working with { CommandError = "録音中または録音の開始・停止中は音声を取り込めません。" }; return null; }
            return new EngineCommand.SessionImport(new EngineImportPayload(inputPath));
        });
    }

    public Task<bool> SetExportDestinationAsync(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        return RunRequestAsync(() =>
        {
            var confirmed = _working.ConfirmedSettings;
            if (confirmed is null) { _working = _working with { CommandError = "設定を保存してから書き出してください。" }; return null; }
            return new EngineCommand.SettingsReplace(new EngineSettingsReplacePayload(confirmed.Revision, confirmed.Settings with { ExportDestinationPath = path }));
        });
    }

    public Task<bool> CommitSettingsAsync() => RunRequestAsync(() =>
    {
        if (_working.SettingsDraft is null) { _working = _working with { CommandError = "Settings must be loaded or explicitly drafted before commit." }; return null; }
        EngineID? expected;
        if (_working.SettingsStatus is ShellSettingsStatus.Required or ShellSettingsStatus.Corrupt) expected = null;
        else if (_working.ConfirmedSettings is not null) expected = _working.ConfirmedSettings.Revision;
        else { _working = _working with { CommandError = "The confirmed settings revision is unknown." }; return null; }
        return new EngineCommand.SettingsReplace(new EngineSettingsReplacePayload(expected, _working.SettingsDraft));
    });

    public Task<bool> ExecuteAsync(EngineCommand command)
    {
        ArgumentNullException.ThrowIfNull(command);
        if (command is not (EngineCommand.StateGet or EngineCommand.DiagnosticsGet or EngineCommand.RecordingStart or EngineCommand.RecordingStop or EngineCommand.ModelsPrepare or EngineCommand.ModelsInspect))
            throw new ArgumentException("ShellStore does not support this command.", nameof(command));
        return RunRequestAsync(() => command);
    }

    public Task ReportPresentationFailureAsync(Exception exception)
    {
        ArgumentNullException.ThrowIfNull(exception);
        return Post(() => FailStore(exception));
    }

    /// <summary>Stops only this store's observers and reducer; the caller owns and closes the client.</summary>
    public ValueTask DisposeAsync()
    {
        lock (_postGate)
        {
            if (_disposeTask is not null) return new ValueTask(_disposeTask);
            _disposeRequested = true; _stop.Cancel();
            var final = new Work(() => _working = _working with { Phase = ShellPhase.Disposed, Pending = ImmutableHashSet<EngineCommandName>.Empty });
            if (!_work.Writer.TryWrite(final)) throw new InvalidOperationException("ShellStore reducer stopped before disposal was queued.");
            _work.Writer.TryComplete(); return new ValueTask(_disposeTask = FinishDisposeAsync(final.Acknowledgement.Task));
        }
    }

    private async Task FinishDisposeAsync(Task finalAcknowledgement)
    {
        try
        {
            await finalAcknowledgement.ConfigureAwait(false);
            var tailTask = _tailTask ?? Task.CompletedTask;
            await Task.WhenAll(_initialization, _watcherTask, _reducerTask, tailTask).ConfigureAwait(false);
        }
        finally { _stop.Dispose(); }
    }

    private Task Post(Action action)
    {
        ArgumentNullException.ThrowIfNull(action);
        var work = new Work(action);
        lock (_postGate) if (_disposeRequested || !_work.Writer.TryWrite(work)) throw new ObjectDisposedException(nameof(ShellStore));
        return work.Acknowledgement.Task;
    }

    // Publish and notify once per FIFO batch before settling acknowledgements.
    private async Task ReduceAsync()
    {
        while (await _work.Reader.WaitToReadAsync().ConfigureAwait(false))
        {
            var batch = new List<Work>();
            while (_work.Reader.TryRead(out var item)) batch.Add(item);
            var before = _working;
            foreach (var item in batch)
                try { item.Action(); }
                catch (Exception exception) { item.Error = exception; FailStore(exception); }
            Exception? notificationError = null;
            if (!ReferenceEquals(before, _working))
            {
                Volatile.Write(ref _published, _working);
                try { Changed?.Invoke(this, EventArgs.Empty); }
                catch (Exception exception) { notificationError = exception; FailStore(exception); Volatile.Write(ref _published, _working); }
            }
            foreach (var item in batch)
            {
                var error = item.Error ?? notificationError;
                if (error is null) item.Acknowledgement.TrySetResult(); else item.Acknowledgement.TrySetException(error);
            }
        }
    }

    private async Task InitializeAsync()
    {
        try
        {
            var result = await AwaitClientTask(_client.Hello).ConfigureAwait(false);
            if (result is not EngineResult.Hello hello) throw new InvalidOperationException($"Automatic hello returned unexpected result {result.GetType().Name}.");
            await Post(() =>
            {
                _working = _working with { Capabilities = hello.Result.Capabilities }; ApplyState(hello.Result.State);
                if (!IsTerminal(_working.Phase)) _working = _working with { Phase = ShellPhase.Running };
            }).ConfigureAwait(false);
            if (State.Phase == ShellPhase.Running) await ReloadSettingsAsync().ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (_stop.IsCancellationRequested) { }
        catch (Exception exception)
        {
            if (_stop.IsCancellationRequested) return;
            try
            {
                await Post(() =>
                {
                    if (exception is EngineClientFailedException failed) ApplyClientFailure(ResolveClientFailure(failed.Failure));
                    else FailStore(exception);
                }).ConfigureAwait(false);
            }
            catch (ObjectDisposedException) when (_stop.IsCancellationRequested) { }
        }
    }

    private async Task WatchEventsAsync()
    {
        try
        {
            while (true)
            {
                var eventWait = _client.WaitForEventsAsync(_stop.Token);
                var completion = _client.Completion;
                var completionWon = completion.IsCompleted ||
                    await Task.WhenAny(eventWait, completion).ConfigureAwait(false) == completion;
                if (!completionWon) await eventWait.ConfigureAwait(false);
                if (completionWon)
                {
                    var completedState = await completion.WaitAsync(_stop.Token).ConfigureAwait(false);
                    if (completedState is not (EngineClientState.Failed or EngineClientState.Closed)) throw new InvalidOperationException($"Client completed in unexpected state {completedState}.");
                }

                var observedState = EngineClientState.Running;
                await Post(() =>
                {
                    foreach (var output in _client.DrainEvents()) ReduceEvent(output);
                    observedState = _client.State;
                    SyncClientState(observedState);
                }).ConfigureAwait(false);
                if (observedState == EngineClientState.Failed)
                {
                    await completion.WaitAsync(_stop.Token).ConfigureAwait(false);
                    await Post(() =>
                    {
                        foreach (var output in _client.DrainEvents()) ReduceEvent(output);
                        ApplyClientFailure(ResolveClientFailure(RequireClientFailure()));
                    }).ConfigureAwait(false);
                    return;
                }
                if (observedState == EngineClientState.Closed) return;
            }
        }
        catch (OperationCanceledException) when (_stop.IsCancellationRequested) { }
        catch (ObjectDisposedException) when (_stop.IsCancellationRequested) { }
        catch (Exception exception) when (!_stop.IsCancellationRequested)
        {
            try { await Post(() => FailStore(exception)).ConfigureAwait(false); }
            catch when (State.StoreFailure is not null || _stop.IsCancellationRequested) { }
        }
    }

    private void SyncClientState(EngineClientState state)
    {
        if (state == EngineClientState.Failed)
            ApplyClientFailure(ResolveClientFailure(RequireClientFailure()));
        else if (state == EngineClientState.Closed && !IsTerminal(_working.Phase))
            _working = _working with { Phase = ShellPhase.Closed, Pending = ImmutableHashSet<EngineCommandName>.Empty };
    }

    // Correlated Accepted/Completed/Error are transport-owned; request tasks apply terminal results once; Rows belong to the transcript reducer.
    private void ReduceEvent(EngineOutput output)
    {
        switch (output.Event)
        {
            case EngineEvent.Ready ready: _working = _working with { Capabilities = ready.Payload.Capabilities }; ApplyState(ready.Payload.State); break;
            case EngineEvent.State state: ApplyState(state.Payload); break;
            case EngineEvent.Progress progress: _working = _working with { Progress = progress.Payload }; break;
            case EngineEvent.Error error when output.RequestID is null: _working = _working with { LastError = error.Payload }; break;
            case EngineEvent.Rows rows: ReduceRows(rows.Payload); break;
            case EngineEvent.Error: case EngineEvent.Accepted: case EngineEvent.Completed: break;
            default: throw new InvalidOperationException("Unrecognized engine event in the client inbox.");
        }
    }

    private void ApplyState(EngineState value)
    {
        var revision = value.Revision.Value;
        if (_stateRevision is ulong previous && revision <= previous) return;
        _stateRevision = revision;
        var next = _working with { Engine = value };
        if (_working.ConfirmedSettings is null && value.Setup == EngineSetupStatus.SettingsRequired && next.SettingsStatus != ShellSettingsStatus.Corrupt)
            next = next with { SettingsStatus = ShellSettingsStatus.Required };
        _working = next;
    }

    private Task<bool> RunRequestAsync(Func<EngineCommand?> commandFactory) => RunRequestAsync(commandFactory, ApplyResult, HandleRequestFailure);

    private async Task<bool> RunRequestAsync(Func<EngineCommand?> commandFactory, Action<EngineCommand, EngineResult> apply, Action<EngineCommandName, Exception, bool> failure)
    {
        ArgumentNullException.ThrowIfNull(commandFactory); ArgumentNullException.ThrowIfNull(apply); ArgumentNullException.ThrowIfNull(failure);
        EngineCommand? command = null; Task<EngineResult>? request = null;
        await Post(() =>
        {
            command = commandFactory();
            if (command is null) return;
            if (_working.Phase != ShellPhase.Running) { _working = _working with { CommandError = "The engine is not running." }; return; }
            var settings = command.Name is EngineCommandName.SettingsGet or EngineCommandName.SettingsReplace;
            if (_working.Pending.Contains(command.Name) || settings && (_working.Pending.Contains(EngineCommandName.SettingsGet) || _working.Pending.Contains(EngineCommandName.SettingsReplace)))
            { _working = _working with { CommandError = "A request of this kind is already pending." }; return; }
            _working = _working with { Pending = _working.Pending.Add(command.Name), CommandError = null };
            try { request = _client.SendAsync(command); }
            catch (Exception exception) { failure(command.Name, exception, true); }
        }).ConfigureAwait(false);
        if (command is null || request is null) return false;
        EngineResult result;
        try { result = await AwaitClientTask(request).ConfigureAwait(false); }
        catch (OperationCanceledException) when (_stop.IsCancellationRequested) { throw; }
        catch (Exception exception) { await Post(() => failure(command.Name, exception, false)).ConfigureAwait(false); return false; }
        var success = false;
        await Post(() =>
        {
            RemovePending(command.Name);
            try
            {
                if (result.Command != command.Name) throw new InvalidOperationException($"{command.Name} returned result for {result.Command}.");
                apply(command, result); success = true;
            }
            catch (Exception exception) { FailStore(exception); }
        }).ConfigureAwait(false);
        return success;
    }

    private void ApplyResult(EngineCommand command, EngineResult result)
    {
        if (result.Command != command.Name) throw new InvalidOperationException($"{command.Name} returned result for {result.Command}.");
        switch (command, result)
        {
            case (EngineCommand.StateGet, EngineResult.StateGet state): ApplyState(state.Result); break;
            case (EngineCommand.DevicesList devicesCommand, EngineResult.DevicesList devices):
                if (devices.Result.Source != devicesCommand.Payload.Source)
                    throw new InvalidOperationException($"devices.list requested {devicesCommand.Payload.Source} but returned {devices.Result.Source}.");
                _working = _working with { Devices = devices.Result };
                break;
            case (EngineCommand.DiagnosticsGet, EngineResult.DiagnosticsGet diagnostics): _working = _working with { Diagnostics = diagnostics.Result }; break;
            case (EngineCommand.ModelsInspect, EngineResult.ModelsInspect models): _working = _working with { ModelsInspection = models.Result }; break;
            case (EngineCommand.SettingsGet, EngineResult.SettingsGet settings): ApplySettings(settings.Result, false); break;
            case (EngineCommand.SettingsReplace, EngineResult.SettingsReplace settings): ApplySettings(settings.Result, true); break;
            case (EngineCommand.RecordingStart, EngineResult.RecordingStart started): SelectSession(started.Result.SessionID); break;
            case (EngineCommand.SessionImport, EngineResult.SessionImport):
            case (EngineCommand.RecordingStop, EngineResult.RecordingStop):
            case (EngineCommand.ModelsPrepare, EngineResult.ModelsPrepare): break;
            default: throw new InvalidOperationException($"{command.Name} returned unexpected result {result.GetType().Name}.");
        }
        if (command.Name is EngineCommandName.SettingsGet or EngineCommandName.SettingsReplace)
            _working = _working with { SettingsConflict = false, LastError = IsTerminal(_working.Phase) ? _working.LastError : null, CommandError = null };
        else _working = _working with { CommandError = null };
    }

    private void ApplySettings(EngineSettingsResult result, bool replace) => _working = replace
        ? _working with { ConfirmedSettings = result, SettingsStatus = ShellSettingsStatus.Available, SettingsConflict = false }
        : _working with { ConfirmedSettings = result, SettingsDraft = result.Settings, SettingsStatus = ShellSettingsStatus.Available, SettingsConflict = false };

    private void HandleRequestFailure(EngineCommandName name, Exception exception, bool admission)
    {
        RemovePending(name);
        switch (exception)
        {
            case EngineRequestException failed:
                _working = _working with { LastError = failed.Failure };
                if (name == EngineCommandName.SettingsGet && failed.Failure.Code == EngineErrorCode.SettingsRequired) _working = _working with { SettingsStatus = ShellSettingsStatus.Required };
                else if (name == EngineCommandName.SettingsGet && failed.Failure.Code == EngineErrorCode.InvalidSettings) _working = _working with { SettingsStatus = ShellSettingsStatus.Corrupt };
                if (name == EngineCommandName.SettingsReplace && failed.Failure.Code == EngineErrorCode.StaleRevision) _working = _working with { SettingsConflict = true };
                break;
            case EngineClientFailedException failed: ApplyClientFailure(ResolveClientFailure(failed.Failure)); break;
            case EngineClientOverloadedException: _working = _working with { CommandError = exception.Message }; break;
            case InvalidOperationException when admission: _working = _working with { CommandError = exception.Message }; break;
            default: FailStore(exception); break;
        }
    }

    private EngineClientFailure ResolveClientFailure(EngineClientFailure failure) => _client.Completion.IsCompleted ? RequireClientFailure() : failure;

    private EngineClientFailure RequireClientFailure() => _client.Failure ?? throw new InvalidOperationException("Client state is Failed but its failure snapshot is null.");
    private void ApplyClientFailure(EngineClientFailure failure) => _working = _working with
    {
        Phase = _working.Phase == ShellPhase.Disposed ? ShellPhase.Disposed : ShellPhase.EngineFailed,
        EngineFailure = failure, LastError = failure.LastEngineError is null ? _working.LastError : failure.LastEngineError, Pending = ImmutableHashSet<EngineCommandName>.Empty
    };
    private void FailStore(Exception exception) => _working = _working with
    {
        Phase = _working.Phase == ShellPhase.Disposed ? ShellPhase.Disposed : ShellPhase.EngineFailed,
        StoreFailure = _working.StoreFailure ?? $"{exception.GetType().Name}: {exception.Message}", Pending = ImmutableHashSet<EngineCommandName>.Empty
    };
    private void RemovePending(EngineCommandName name) => _working = _working with { Pending = _working.Pending.Remove(name) };

    private static bool IsTerminal(ShellPhase phase) => phase is ShellPhase.EngineFailed or ShellPhase.Closed or ShellPhase.Disposed;

    private async Task<EngineResult> AwaitClientTask(Task<EngineResult> task)
    {
        try { return await task.WaitAsync(_stop.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (_stop.IsCancellationRequested)
        {
            // The caller owns the engine lifecycle; observe a request that outlives this store.
            _ = task.ContinueWith(faulted => _ = faulted.Exception, CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            throw;
        }
    }
}
