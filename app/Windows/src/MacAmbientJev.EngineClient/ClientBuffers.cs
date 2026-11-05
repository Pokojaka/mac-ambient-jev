using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.EngineClient;

internal sealed class StderrRing
{
    internal const int Capacity = 256 * 1024;

    private readonly object _gate = new();
    private readonly byte[] _buffer = new byte[Capacity];
    private int _start;
    private int _count;
    private long _discardedBytes;

    internal void Append(ReadOnlySpan<byte> bytes)
    {
        lock (_gate)
        {
            if (bytes.Length == 0)
            {
                return;
            }

            if (bytes.Length >= Capacity)
            {
                _discardedBytes = checked(_discardedBytes + _count + bytes.Length - Capacity);
                bytes[^Capacity..].CopyTo(_buffer);
                _start = 0;
                _count = Capacity;
                return;
            }

            var discard = Math.Max(0, _count + bytes.Length - Capacity);
            _discardedBytes = checked(_discardedBytes + discard);
            _start = (_start + discard) % Capacity;
            _count -= discard;
            var write = (_start + _count) % Capacity;
            var first = Math.Min(bytes.Length, Capacity - write);
            bytes[..first].CopyTo(_buffer.AsSpan(write, first));
            bytes[first..].CopyTo(_buffer.AsSpan(0, bytes.Length - first));
            _count += bytes.Length;
        }
    }

    internal StderrSnapshot Snapshot()
    {
        lock (_gate)
        {
            var bytes = new byte[_count];
            var first = Math.Min(_count, Capacity - _start);
            Array.Copy(_buffer, _start, bytes, 0, first);
            Array.Copy(_buffer, 0, bytes, first, _count - first);
            return new StderrSnapshot(bytes, _discardedBytes);
        }
    }
}

internal sealed class StderrLineSplitter(Action<string> onLine)
{
    internal const int MaxLineBytes = 64 * 1024;

    private readonly MemoryStream _line = new();

    internal void Append(ReadOnlySpan<byte> bytes)
    {
        while (bytes.Length != 0)
        {
            var lineFeed = bytes.IndexOf((byte)'\n');
            _line.Write(lineFeed < 0 ? bytes : bytes[..lineFeed]);
            if (lineFeed < 0)
            {
                if (_line.Length >= MaxLineBytes) Emit();
                return;
            }

            Emit();
            bytes = bytes[(lineFeed + 1)..];
        }
    }

    internal void Complete()
    {
        if (_line.Length != 0) Emit();
    }

    private void Emit()
    {
        var text = Encoding.UTF8.GetString(_line.GetBuffer(), 0, (int)_line.Length).TrimEnd('\r');
        _line.SetLength(0);
        onLine(text);
    }
}

internal sealed class OutputInbox
{
    private readonly LinkedList<EngineOutput> _items = new();
    private LinkedListNode<EngineOutput>? _stateNode;
    private LinkedListNode<EngineOutput>? _progressNode;
    private LinkedListNode<EngineOutput>? _rowsNode;

    internal bool HasItems => _items.Count != 0;

    internal void Add(EngineOutput output)
    {
        ArgumentNullException.ThrowIfNull(output);
        if (output.Event is EngineEvent.Rows rows)
        {
            if (rows.Payload is null)
            {
                throw new ArgumentException("Rows output must include a payload.", nameof(output));
            }

            var invalidation = rows.Payload with
            {
                Kind = EngineRowsKind.ReloadRequired,
                Rows = Array.Empty<EngineTranscriptRow>(),
                RemovedRowIDs = Array.Empty<string>(),
                NextCursor = null
            };
            output = output with { Event = new EngineEvent.Rows(invalidation) };
        }

        LinkedListNode<EngineOutput>? previous = output.Event switch
        {
            EngineEvent.State => _stateNode,
            EngineEvent.Progress => _progressNode,
            EngineEvent.Rows => _rowsNode,
            _ => null
        };
        if (previous is not null)
        {
            _items.Remove(previous);
        }

        var node = _items.AddLast(output);
        switch (output.Event)
        {
            case EngineEvent.State:
                _stateNode = node;
                break;
            case EngineEvent.Progress:
                _progressNode = node;
                break;
            case EngineEvent.Rows:
                _rowsNode = node;
                break;
        }
    }

    internal IReadOnlyList<EngineOutput> Drain()
    {
        var snapshot = new EngineOutput[_items.Count];
        _items.CopyTo(snapshot, 0);
        _items.Clear();
        _stateNode = null;
        _progressNode = null;
        _rowsNode = null;
        return snapshot;
    }
}
