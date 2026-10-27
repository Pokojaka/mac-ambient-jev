using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.EngineClient;

/// <summary>Owns one engine child, its NDJSON transport, and the request lifecycle.</summary>
public sealed class EngineProcessClient : IAsyncDisposable
{
    private enum RequestLane { Ordinary, Stop, Shutdown }

    private sealed class PendingRequest(EngineID id, EngineCommand command, RequestLane lane, byte[] encoded)
    {
        internal EngineID ID { get; } = id;
        internal EngineCommand Command { get; } = command;
        internal RequestLane Lane { get; } = lane;
        internal byte[] Encoded { get; set; } = encoded;
        internal TaskCompletionSource<EngineResult> Completion { get; } = NewCompletion<EngineResult>();
        internal bool Accepted { get; set; }
    }

    private readonly object _gate = new();
    private readonly IEngineChild _child;
    private readonly EngineClientLimits _limits;
    private readonly Stream _input, _output, _error;
    private readonly Task<int> _exit;
    private readonly Dictionary<ulong, PendingRequest> _pending = new();
    private readonly Queue<PendingRequest> _outbound = new();
    private readonly SemaphoreSlim _writeSignal = new(0);
    private readonly StderrRing _stderrRing = new();
    private readonly OutputInbox _inbox = new();
    private readonly TaskCompletionSource _stdoutStarted = NewCompletion(), _stderrStarted = NewCompletion();
    private readonly TaskCompletionSource<EngineClientState> _completion = NewCompletion<EngineClientState>();
    private TaskCompletionSource _eventSignal = NewCompletion();
    private Task? _closeTask, _stdoutWorker, _stderrWorker, _writerWorker;
    private ulong _nextRequestID = 1, _lastSequence;
    private int _outgoingBytes;
    private int? _exitCode;
    private EngineFailure? _lastEngineError;
    private EngineClientState _state = EngineClientState.Running;
    private string? _failureMessage;
    private readonly List<string> _additionalFailures = new();
    private bool _requestIDsExhausted, _admissionOpen = true, _shutdownTerminalObserved, _shutdownSucceeded, _inputClosed, _writerStopping, _writerInFlight;

    public EngineProcessClient(IEngineChild child, EngineClientLimits limits)
    {
        ArgumentNullException.ThrowIfNull(child);
        ArgumentNullException.ThrowIfNull(limits);
        limits.Validate();
        _child = child;
        _limits = limits;
        _input = child.StandardInput ?? throw new ArgumentException("Engine child stdin must not be null.", nameof(child));
        _output = child.StandardOutput ?? throw new ArgumentException("Engine child stdout must not be null.", nameof(child));
        _error = child.StandardError ?? throw new ArgumentException("Engine child stderr must not be null.", nameof(child));
        _exit = child.Exit ?? throw new ArgumentException("Engine child exit task must not be null.", nameof(child));
        if (!_input.CanWrite || !_output.CanRead || !_error.CanRead)
            throw new ArgumentException("Engine child streams must provide writable stdin and readable stdout/stderr.", nameof(child));

        lock (_gate) Hello = AdmitLocked(new EngineCommand.Hello(new EngineEmptyPayload()), RequestLane.Ordinary).Completion.Task;
        _stdoutWorker = Task.Run(ReadStdoutAsync);
        _stderrWorker = Task.Run(ReadStderrAsync);
        _writerWorker = Task.Run(WriteLoopAsync);
        _ = Task.Run(CoordinateAsync);
        _writeSignal.Release();
    }

    public static EngineProcessClient Start(string enginePath) =>
        new(ProcessEngineChild.Start(enginePath, Array.Empty<string>()), EngineClientLimits.Production);

    public Task<EngineResult> Hello { get; }

    public Task<EngineResult> SendAsync(EngineCommand command)
    {
        ArgumentNullException.ThrowIfNull(command);
        if (command.Name is EngineCommandName.Hello or EngineCommandName.Shutdown)
            throw new InvalidOperationException("hello is automatic and shutdown must be sent through CloseAsync().");
        PendingRequest pending;
        lock (_gate)
        {
            EnsureAdmissionOpenLocked();
            pending = AdmitLocked(command, command.Name == EngineCommandName.RecordingStop ? RequestLane.Stop : RequestLane.Ordinary);
        }
        _writeSignal.Release();
        return pending.Completion.Task;
    }

    public Task CloseAsync()
    {
        TaskCompletionSource closeCompletion;
        Task<EngineResult>? shutdownTask = null;
        var wasAlreadyFailed = false;
        var closeInput = false;
        var wakeWriter = false;
        lock (_gate)
        {
            if (_closeTask is not null) return _closeTask;
            if (_state == EngineClientState.Closed) return Task.CompletedTask;
            if (_state == EngineClientState.Running && !_admissionOpen)
            {
                var exitCode = _exitCode ?? throw new InvalidOperationException("Engine admission closed while running without an exit code.");
                closeInput = FailLocked($"Engine process exited before shutdown was initiated: {ExitFailureMessage(exitCode)}", null);
                wasAlreadyFailed = true;
            }
            closeCompletion = NewCompletion();
            _closeTask = closeCompletion.Task;
            if (_state == EngineClientState.Failed)
                wasAlreadyFailed = true;
            else
            {
                _state = EngineClientState.Closing;
                _admissionOpen = false;
                try
                {
                    shutdownTask = AdmitLocked(new EngineCommand.Shutdown(new EngineEmptyPayload()), RequestLane.Shutdown).Completion.Task;
                    wakeWriter = true;
                }
                catch (Exception exception)
                {
                    closeInput = FailLocked("Unable to admit the shutdown request safely", exception);
                    wasAlreadyFailed = true;
                }
            }
        }
        if (closeInput) CloseInputStream();
        if (wakeWriter) _writeSignal.Release();
        _ = Task.Run(() => FinishCloseCoreAsync(closeCompletion, shutdownTask, wasAlreadyFailed));
        return closeCompletion.Task;
    }

    public void ForceKill()
    {
        if (_exit.IsCompletedSuccessfully) return;
        bool closeInput;
        lock (_gate) closeInput = FailLocked("Engine process was force-killed", null);
        try { _child.Kill(); }
        catch (Exception exception) { ReportFailure("Killing the engine child failed", exception); throw; }
        finally { if (closeInput) CloseInputStream(); }
    }

    public Task<EngineClientState> Completion => _completion.Task;
    public EngineClientState State { get { lock (_gate) return _state; } }
    /// <summary>Gets the failure snapshot, if the client has failed.</summary>
    /// <remarks>After <see cref="Completion"/> finishes, the snapshot includes the final exit code and stderr. An immediate pending failure may have a null exit code and incomplete stderr.</remarks>
    public EngineClientFailure? Failure { get { lock (_gate) return _state == EngineClientState.Failed ? BuildFailureLocked() : null; } }
    public StderrSnapshot Stderr => _stderrRing.Snapshot();
    public bool IsStillWaiting { get { lock (_gate) return (_state is EngineClientState.Closing or EngineClientState.Failed) && !_completion.Task.IsCompleted; } }
    public int PendingCount { get { lock (_gate) return _pending.Count; } }
    public int OutgoingByteCount { get { lock (_gate) return _outgoingBytes; } }

    /// <summary>Drains queued outputs, including normalized rows, invalidations, and correlated replies.</summary>
    public IReadOnlyList<EngineOutput> DrainEvents()
    {
        lock (_gate)
        {
            var outputs = _inbox.Drain();
            if (outputs.Count > 0 && _state is not (EngineClientState.Closed or EngineClientState.Failed)) _eventSignal = NewCompletion();
            return outputs;
        }
    }

    public Task WaitForEventsAsync(CancellationToken cancellationToken)
    {
        Task waitTask;
        lock (_gate)
            waitTask = _inbox.HasItems || _state is EngineClientState.Closed or EngineClientState.Failed ? Task.CompletedTask : _eventSignal.Task;
        return cancellationToken.CanBeCanceled ? waitTask.WaitAsync(cancellationToken) : waitTask;
    }

    /// <summary>Closes the engine client and waits for shutdown.</summary>
    /// <remarks>Disposal may wait indefinitely and does not automatically kill the child process.</remarks>
    public ValueTask DisposeAsync() => new(CloseAsync());

    private PendingRequest AdmitLocked(EngineCommand command, RequestLane lane)
    {
        if (_requestIDsExhausted) throw new InvalidOperationException("The engine request ID space is exhausted.");
        var id = new EngineID(_nextRequestID);
        var encoded = EngineCodec.EncodeRequest(new EngineRequest(1, id, command));
        EnsureCapacityLocked(lane, encoded.Length);
        var pending = new PendingRequest(id, command, lane, encoded);
        _pending.Add(id.Value, pending);
        _outbound.Enqueue(pending);
        _outgoingBytes = checked(_outgoingBytes + encoded.Length);
        if (_nextRequestID == ulong.MaxValue) _requestIDsExhausted = true;
        else _nextRequestID++;
        return pending;
    }

    private void EnsureCapacityLocked(RequestLane lane, int encodedLength)
    {
        var ordinary = 0; var stop = 0; var shutdown = 0;
        foreach (var request in _pending.Values)
            switch (request.Lane)
            {
                case RequestLane.Ordinary: ordinary++; break;
                case RequestLane.Stop: stop++; break;
                case RequestLane.Shutdown: shutdown++; break;
            }
        var laneFull = lane switch
        {
            RequestLane.Ordinary => ordinary >= _limits.OrdinaryPending,
            RequestLane.Stop => stop >= 1,
            RequestLane.Shutdown => shutdown >= 1,
            _ => throw new InvalidOperationException("Unknown engine request lane.")
        };
        if (laneFull || _pending.Count >= _limits.OrdinaryPending + 2)
            throw new EngineClientOverloadedException("The engine request capacity is full.");
        if (encodedLength > _limits.OutgoingBytes - _outgoingBytes)
            throw new EngineClientOverloadedException("The engine outgoing byte capacity is full.");
    }

    private void EnsureAdmissionOpenLocked()
    {
        if (_state == EngineClientState.Failed) throw new EngineClientFailedException(BuildFailureLocked());
        if (_state != EngineClientState.Running || !_admissionOpen)
            throw new InvalidOperationException("The engine client is not admitting requests.");
    }

    private async Task ReadStdoutAsync()
    {
        try
        {
            var reader = new NdjsonFrameReader(_output);
            var read = reader.ReadAsync(CancellationToken.None);
            _stdoutStarted.TrySetResult();
            while (await read.ConfigureAwait(false) is { } record)
            {
                ProcessOutput(EngineCodec.DecodeOutput(record));
                read = reader.ReadAsync(CancellationToken.None);
            }
            HandleStdoutEof();
        }
        catch (Exception exception)
        {
            ReportFailure("Engine stdout protocol or read failure", exception);
            _stdoutStarted.TrySetResult();
            await DrainRawStdoutAsync().ConfigureAwait(false);
        }
        finally { _stdoutStarted.TrySetResult(); }
    }

    private async Task DrainRawStdoutAsync()
    {
        var buffer = new byte[16 * 1024];
        try { while (await _output.ReadAsync(buffer.AsMemory()).ConfigureAwait(false) != 0) { } }
        catch (Exception exception) { ReportFailure("Raw stdout draining failed after a transport fault", exception); }
    }

    private async Task ReadStderrAsync()
    {
        try
        {
            var buffer = new byte[16 * 1024];
            var read = _error.ReadAsync(buffer.AsMemory());
            _stderrStarted.TrySetResult();
            while (true)
            {
                var count = await read.ConfigureAwait(false);
                if (count == 0) return;
                _stderrRing.Append(buffer.AsSpan(0, count));
                read = _error.ReadAsync(buffer.AsMemory());
            }
        }
        catch (Exception exception)
        {
            ReportFailure("Engine stderr read failure", exception);
        }
        finally { _stderrStarted.TrySetResult(); }
    }

    private async Task WriteLoopAsync()
    {
        await Task.WhenAll(_stdoutStarted.Task, _stderrStarted.Task).ConfigureAwait(false);
        while (true)
        {
            await _writeSignal.WaitAsync().ConfigureAwait(false);
            PendingRequest? request;
            lock (_gate)
            {
                if (_outbound.Count != 0) { request = _outbound.Dequeue(); _writerInFlight = true; }
                else if (_writerStopping) return;
                else continue;
            }
            try
            {
                await _input.WriteAsync(request.Encoded.AsMemory()).ConfigureAwait(false);
                await _input.FlushAsync().ConfigureAwait(false);
            }
            catch (Exception exception)
            {
                SettleOutbound(request);
                ReportFailure("Engine stdin write or flush failure", exception);
                return;
            }
            SettleOutbound(request);
        }
    }

    private void SettleOutbound(PendingRequest request)
    {
        var closeInput = false;
        lock (_gate)
        {
            _writerInFlight = false;
            _outgoingBytes = checked(_outgoingBytes - request.Encoded.Length);
            request.Encoded = Array.Empty<byte>();
            if (_outgoingBytes < 0) throw new InvalidOperationException("Engine outgoing byte accounting underflowed.");
            if (_shutdownTerminalObserved && _outbound.Count == 0 && _state != EngineClientState.Failed)
                closeInput = ClaimInputCloseLocked();
        }
        if (closeInput) CloseInputStream();
    }

    private void ProcessOutput(EngineOutput output)
    {
        PendingRequest? completedRequest = null;
        EngineResult? result = null;
        EngineFailure? requestFailure = null;
        var closeInput = false;
        lock (_gate)
        {
            var sequence = output.Sequence.Value;
            if ((_lastSequence == 0 && sequence != 1) || (_lastSequence != 0 && sequence <= _lastSequence))
                throw new InvalidOperationException($"Invalid engine output sequence {sequence}; previous sequence was {_lastSequence}.");
            _lastSequence = sequence;
            if (output.Event is EngineEvent.Error anyError) _lastEngineError = anyError.Payload;

            switch (output.Event)
            {
                case EngineEvent.Accepted accepted:
                {
                    var id = RequiredRequestID(output);
                    if (!_pending.TryGetValue(id, out var pending)) throw new InvalidOperationException($"Accepted output refers to unknown request ID {id}.");
                    if (pending.Accepted || pending.Command.Name != accepted.Payload.Command)
                        throw new InvalidOperationException($"Accepted output does not match pending request ID {id}.");
                    pending.Accepted = true;
                    break;
                }
                case EngineEvent.Completed completed:
                {
                    var id = RequiredRequestID(output);
                    if (!_pending.TryGetValue(id, out var pending)) throw new InvalidOperationException($"Completed output refers to unknown request ID {id}.");
                    if (!pending.Accepted || pending.Command.Name != completed.Payload.Command)
                        throw new InvalidOperationException($"Completed output does not match accepted request ID {id}.");
                    _pending.Remove(id);
                    completedRequest = pending;
                    result = completed.Payload;
                    if (pending.Lane == RequestLane.Shutdown)
                    {
                        _shutdownTerminalObserved = true;
                        _shutdownSucceeded = true;
                        if (!_writerInFlight && _outbound.Count == 0) closeInput = ClaimInputCloseLocked();
                    }
                    break;
                }
                case EngineEvent.Error error when output.RequestID is not null:
                {
                    var id = output.RequestID.Value;
                    if (!_pending.TryGetValue(id, out var pending)) throw new InvalidOperationException($"Error output refers to unknown request ID {id}.");
                    _pending.Remove(id);
                    completedRequest = pending;
                    requestFailure = error.Payload;
                    if (pending.Lane == RequestLane.Shutdown)
                    {
                        _shutdownTerminalObserved = true;
                        if (!_writerInFlight && _outbound.Count == 0) closeInput = ClaimInputCloseLocked();
                    }
                    break;
                }
                case EngineEvent.Ready:
                case EngineEvent.State:
                case EngineEvent.Progress:
                case EngineEvent.Rows:
                case EngineEvent.Error:
                    break;
                default: throw new InvalidOperationException("Unrecognized engine output event.");
            }
            var wasEmpty = !_inbox.HasItems;
            _inbox.Add(output);
            if (wasEmpty) _eventSignal.TrySetResult();
        }
        if (completedRequest is not null)
        {
            if (requestFailure is not null) completedRequest.Completion.TrySetException(new EngineRequestException(requestFailure));
            else completedRequest.Completion.TrySetResult(result ?? throw new InvalidOperationException("Completed output omitted its result."));
        }
        if (closeInput) CloseInputStream();
    }

    private static ulong RequiredRequestID(EngineOutput output) =>
        output.RequestID?.Value ?? throw new InvalidOperationException("Terminal engine output omitted request_id.");

    private void HandleStdoutEof()
    {
        var closeInput = false;
        lock (_gate)
        {
            _admissionOpen = false;
            if (!_shutdownTerminalObserved && _state != EngineClientState.Failed)
                closeInput = FailLocked("Engine stdout reached EOF before a shutdown terminal response", null);
        }
        if (closeInput) CloseInputStream();
    }

    private async Task CoordinateAsync()
    {
        try
        {
            try { HandleProcessExit(await _exit.ConfigureAwait(false)); }
            catch (Exception exception) { ReportFailure("Waiting for the engine process exit failed", exception); }
            try { await Task.WhenAll(_stdoutWorker!, _stderrWorker!).ConfigureAwait(false); }
            catch (Exception exception) { ReportFailure("Waiting for engine output drains failed", exception); }
            var closeInput = false;
            lock (_gate) { if (!_writerStopping) closeInput = ClaimInputCloseLocked(); }
            if (closeInput) CloseInputStream();
            try { await _writerWorker!.ConfigureAwait(false); }
            catch (Exception exception) { ReportFailure("Engine stdin writer stopped unexpectedly", exception); }
        }
        catch (Exception exception) { ReportFailure("Engine client lifecycle coordination failed", exception); }
        finally
        {
            try { _child.Dispose(); }
            catch (Exception exception) { ReportFailure("Disposing the engine child failed", exception); }
            EngineClientState finalState;
            lock (_gate)
            {
                if (_state != EngineClientState.Failed)
                {
                    if (_exitCode is not int exitCode) FailLocked("Engine process exit code is unavailable", null);
                    else if (_state == EngineClientState.Running)
                        FailLocked($"Engine process exited before shutdown was initiated: {ExitFailureMessage(exitCode)}", null);
                    else if (exitCode != 0) FailLocked(ExitFailureMessage(exitCode), null);
                    else if (!_shutdownSucceeded) FailLocked("Engine exited successfully without a successful shutdown response", null);
                    else if (_pending.Count != 0) FailLocked($"Engine exited with {_pending.Count} request(s) lacking terminal responses", null);
                    else _state = EngineClientState.Closed;
                }
                else if (_exitCode is int failedExitCode && failedExitCode != 0)
                    AddSupplementalFailureLocked(ExitFailureMessage(failedExitCode));
                if (_state == EngineClientState.Failed) { FailPendingLocked(); _pending.Clear(); }
                if (_outgoingBytes != 0)
                {
                    AddSupplementalFailureLocked($"Outgoing byte accounting ended at {_outgoingBytes} bytes.");
                    _outgoingBytes = 0;
                    if (_state != EngineClientState.Failed) { FailLocked("Engine outgoing byte accounting did not settle", null); _pending.Clear(); }
                }
                SignalTerminalLocked();
                finalState = _state;
            }
            _completion.TrySetResult(finalState);
        }
    }

    private void HandleProcessExit(int exitCode)
    {
        lock (_gate)
        {
            _exitCode = exitCode;
            _admissionOpen = false;
        }
    }

    private async Task FinishCloseCoreAsync(TaskCompletionSource closeCompletion, Task<EngineResult>? shutdownTask, bool wasAlreadyFailed)
    {
        try
        {
            if (wasAlreadyFailed || shutdownTask is null) { await Completion.ConfigureAwait(false); throw CurrentClientFailure(); }
            EngineRequestException? rejection = null;
            try { await shutdownTask.ConfigureAwait(false); }
            catch (EngineRequestException exception) { rejection = exception; }
            catch (Exception) { await Completion.ConfigureAwait(false); throw CurrentClientFailure(); }
            await Completion.ConfigureAwait(false);
            if (rejection is not null) throw rejection;
            if (State == EngineClientState.Failed) throw CurrentClientFailure();
            closeCompletion.TrySetResult();
        }
        catch (Exception exception) { closeCompletion.TrySetException(exception); }
    }

    private EngineClientFailedException CurrentClientFailure()
    {
        lock (_gate) return new EngineClientFailedException(BuildFailureLocked());
    }

    private void ReportFailure(string message, Exception? exception)
    {
        bool closeInput;
        lock (_gate) closeInput = FailLocked(message, exception);
        if (closeInput) CloseInputStream();
    }

    private bool FailLocked(string message, Exception? exception)
    {
        var detail = exception is null ? message : $"{message}: {exception.GetType().Name}: {exception.Message}";
        if (_state != EngineClientState.Failed) { _state = EngineClientState.Failed; _failureMessage = detail; _admissionOpen = false; }
        else AddSupplementalFailureLocked(detail);
        ClearOutboundLocked();
        if (!_writerStopping) { _writerStopping = true; _writeSignal.Release(); }
        FailPendingLocked();
        SignalTerminalLocked();
        return ClaimInputCloseLocked();
    }

    private void FailPendingLocked()
    {
        var failure = new EngineClientFailedException(BuildFailureLocked());
        foreach (var pending in _pending.Values) pending.Completion.TrySetException(failure);
    }

    private void ClearOutboundLocked()
    {
        while (_outbound.Count != 0)
        {
            var request = _outbound.Dequeue();
            _outgoingBytes = checked(_outgoingBytes - request.Encoded.Length);
            request.Encoded = Array.Empty<byte>();
        }
    }

    private bool ClaimInputCloseLocked()
    {
        if (_inputClosed) return false;
        _inputClosed = true;
        if (!_writerStopping) { _writerStopping = true; _writeSignal.Release(); }
        return true;
    }

    private void CloseInputStream()
    {
        try { _input.Dispose(); }
        catch (Exception exception) { ReportFailure("Closing engine stdin failed", exception); }
    }

    private void SignalTerminalLocked() => _eventSignal.TrySetResult();

    private EngineClientFailure BuildFailureLocked()
    {
        var message = _failureMessage ?? throw new InvalidOperationException("A failed engine client has no failure message.");
        foreach (var additional in _additionalFailures) message += " Additional failure: " + additional;
        return new EngineClientFailure(message, _exitCode, _lastEngineError, _stderrRing.Snapshot());
    }

    private void AddSupplementalFailureLocked(string message)
    {
        if (_additionalFailures.Count < 8) _additionalFailures.Add(message);
    }

    private static string ExitFailureMessage(int exitCode) =>
        $"Engine process exited with code {exitCode} ({EngineExitCodes.Classify(exitCode)}).";
    private static TaskCompletionSource NewCompletion() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static TaskCompletionSource<T> NewCompletion<T>() => new(TaskCreationOptions.RunContinuationsAsynchronously);
}
