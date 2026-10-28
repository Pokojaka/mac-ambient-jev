using System;
using System.IO;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.EngineClient.Tests;

internal sealed class FakeEngineChild : IEngineChild
{
    private readonly BytePipe _stdin = new(), _stdout = new(), _stderr = new();
    private readonly TaskCompletionSource<int> _exit = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource _stdoutStarted = NewSignal(), _stderrStarted = NewSignal();
    private readonly TaskCompletionSource _firstWrite = NewSignal(), _inputClosed = NewSignal();
    private readonly TaskCompletionSource _writeRelease = NewSignal(), _stdoutRelease = NewSignal();
    private readonly TaskCompletionSource _stdoutEof = NewSignal(), _stderrEof = NewSignal();
    private readonly NdjsonFrameReader _requestReader;
    private readonly InputStream _input;
    private readonly OutputStream _output, _error;
    private readonly bool _holdStdout, _failWrite, _failFlush;
    private int _killCalls;
    private bool _disposed;

    internal FakeEngineChild(bool holdInputWrites, bool holdStdoutReads, bool failWrite, bool failFlush)
    {
        _holdStdout = holdStdoutReads; _failWrite = failWrite; _failFlush = failFlush;
        if (!holdInputWrites) _writeRelease.TrySetResult();
        if (!holdStdoutReads) _stdoutRelease.TrySetResult();
        _input = new InputStream(this); _output = new OutputStream(this, _stdout, false); _error = new OutputStream(this, _stderr, true);
        _requestReader = new NdjsonFrameReader(_stdin.Reader);
    }

    public Stream StandardInput => _input;
    public Stream StandardOutput => _output;
    public Stream StandardError => _error;
    public Task<int> Exit => _exit.Task;
    internal Task FirstInputWriteStarted => _firstWrite.Task;
    internal Task InputClosed => _inputClosed.Task;
    internal Task StdoutEofObserved => _stdoutEof.Task;
    internal Task StderrEofObserved => _stderrEof.Task;
    internal bool ReadersStartedBeforeFirstWrite { get; private set; }
    internal int KillCalls => Volatile.Read(ref _killCalls);

    internal async Task<EngineRequest?> ReadRequestAsync()
    {
        var frame = await _requestReader.ReadAsync(CancellationToken.None).ConfigureAwait(false);
        return frame is null ? null : EngineCodec.DecodeRequest(frame);
    }

    internal Task EmitAsync(EngineOutput output) => _stdout.WriteAsync(EngineCodec.EncodeOutput(output));
    internal Task WriteRawStdoutAsync(byte[] bytes) => _stdout.WriteAsync(bytes);
    internal Task WriteStderrAsync(byte[] bytes) => _stderr.WriteAsync(bytes);
    internal void CompleteStdout() => _stdout.Complete();
    internal void CompleteStderr() => _stderr.Complete();
    internal void CompleteExit(int code) => _exit.TrySetResult(code);
    internal void ReleaseInputWrites() => _writeRelease.TrySetResult();
    internal void ReleaseStdoutReads() => _stdoutRelease.TrySetResult();

    public void Kill() => Interlocked.Increment(ref _killCalls);

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        CloseInput(); _stdout.Complete(); _stderr.Complete();
        _writeRelease.TrySetResult(); _stdoutRelease.TrySetResult();
    }

    private void CloseInput()
    {
        if (_inputClosed.TrySetResult())
        {
            _stdin.Complete();
            _writeRelease.TrySetResult();
        }
    }

    private async ValueTask<int> ReadAsync(BytePipe pipe, Memory<byte> buffer, CancellationToken token, bool stdout)
    {
        if (stdout) _stdoutStarted.TrySetResult(); else _stderrStarted.TrySetResult();
        if (stdout && _holdStdout)
            await _stdoutRelease.Task.WaitAsync(token).ConfigureAwait(false);
        var count = await pipe.ReadAsync(buffer, token).ConfigureAwait(false);
        if (count == 0)
        {
            (stdout ? _stdoutEof : _stderrEof).TrySetResult();
        }
        return count;
    }

    private async ValueTask WriteAsync(ReadOnlyMemory<byte> bytes, CancellationToken token)
    {
        _firstWrite.TrySetResult();
        ReadersStartedBeforeFirstWrite = _stdoutStarted.Task.IsCompleted && _stderrStarted.Task.IsCompleted;
        if (_failWrite) throw new IOException("fake stdin write failed");
        await _writeRelease.Task.WaitAsync(token).ConfigureAwait(false);
        if (_disposed || _inputClosed.Task.IsCompleted) throw new ObjectDisposedException(nameof(FakeEngineChild));
        await _stdin.WriteAsync(bytes.ToArray()).ConfigureAwait(false);
    }

    private Task FlushAsync(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (_failFlush) throw new IOException("fake stdin flush failed");
        return Task.CompletedTask;
    }

    private static TaskCompletionSource NewSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    private sealed class InputStream(FakeEngineChild owner) : Stream
    {
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => !owner._disposed && !owner._inputClosed.Task.IsCompleted;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken) => owner.WriteAsync(buffer, cancellationToken);
        public override Task FlushAsync(CancellationToken cancellationToken) => owner.FlushAsync(cancellationToken);
        public override void Flush() => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        protected override void Dispose(bool disposing) { owner.CloseInput(); base.Dispose(disposing); }
    }

    private sealed class OutputStream(FakeEngineChild owner, BytePipe pipe, bool error) : Stream
    {
        public override bool CanRead => !owner._disposed;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken) => owner.ReadAsync(pipe, buffer, cancellationToken, !error);
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }

    private sealed class BytePipe
    {
        private readonly Channel<byte[]> _chunks = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true, SingleWriter = false });
        private byte[]? _current;
        private int _offset;
        internal Stream Reader { get; }
        internal BytePipe() => Reader = new PipeReader(this);
        internal Task WriteAsync(byte[] bytes) => _chunks.Writer.WriteAsync(bytes).AsTask();
        internal void Complete() => _chunks.Writer.TryComplete();
        internal async ValueTask<int> ReadAsync(Memory<byte> destination, CancellationToken token)
        {
            if (destination.IsEmpty) return 0;
            while (_current is null || _offset == _current.Length)
            {
                try { _current = await _chunks.Reader.ReadAsync(token).ConfigureAwait(false); _offset = 0; }
                catch (ChannelClosedException) { return 0; }
            }
            var count = Math.Min(destination.Length, _current.Length - _offset);
            _current.AsMemory(_offset, count).CopyTo(destination); _offset += count;
            return count;
        }
        private sealed class PipeReader(BytePipe pipe) : Stream
        {
            public override bool CanRead => true;
            public override bool CanSeek => false;
            public override bool CanWrite => false;
            public override long Length => throw new NotSupportedException();
            public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
            public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken) => pipe.ReadAsync(buffer, cancellationToken);
            public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
            public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
            public override void Flush() => throw new NotSupportedException();
            public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
            public override void SetLength(long value) => throw new NotSupportedException();
        }
    }
}
