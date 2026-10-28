using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Text;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public sealed record ShellTranscriptRowViewModel(string RowID, string Text, string TimeText, string HeadingText, string WaitingText);

public sealed partial class LiveViewModel
{
    private readonly ObservableCollection<ShellTranscriptRowViewModel> _rows = new();
    private readonly ReadOnlyObservableCollection<ShellTranscriptRowViewModel> _readOnlyRows;
    private EngineTranscriptPage? _lastTail;
    private bool _hasLastTail;

    private void InitializeDisplay()
    {
        Context.Refreshed += ReconcileDisplay;
        ReconcileDisplay(this, EventArgs.Empty);
    }

    public ReadOnlyObservableCollection<ShellTranscriptRowViewModel> Rows => _readOnlyRows;
    public bool IsEmpty => Snapshot.Transcript.Tail is not { Rows.Length: > 0 };
    public bool IsFollowing => Snapshot.Transcript.Follow;
    public bool HasNewUpdates => Snapshot.Transcript.NewUpdatesAvailable;
    public bool IsBusy
    {
        get
        {
            var state = Snapshot;
            return state.IsPending(EngineCommandName.RecordingStart) || state.IsPending(EngineCommandName.RecordingStop) ||
                state.IsPending(EngineCommandName.DevicesList);
        }
    }
    public string? BadgeText => Snapshot.Engine?.Screen switch
    {
        null or EngineScreen.Idle => null,
        EngineScreen.Live => "ライブ（暫定）",
        EngineScreen.Finalizing => "確定処理中",
        EngineScreen.Finalized => "確定済み",
        var screen => throw new InvalidOperationException($"Unknown engine screen: {screen}.")
    };
    public string RefreshDevicesLabel => "デバイスを更新";

    public string? FailureText
    {
        get
        {
            var state = Snapshot;
            var parts = new List<string>();
            if (state.StoreFailure is not null) parts.Add(state.StoreFailure);
            if (state.CommandError is not null) parts.Add(state.CommandError);
            if (state.LastError is not null) parts.Add(state.LastError.Message);
            if (state.EngineFailure is { } failure)
            {
                parts.Add(failure.Message);
                if (failure.LastEngineError is { } engineError) parts.Add(engineError.Message);
                parts.Add("終了コード: " + (failure.ExitCode?.ToString(CultureInfo.InvariantCulture) ?? "未確定"));
                var stderr = Encoding.UTF8.GetString(failure.Stderr.Bytes);
                if (stderr.Length != 0) parts.Add("標準エラー出力: " + stderr);
                if (failure.Stderr.DiscardedBytes != 0)
                    parts.Add("標準エラー出力の破棄バイト数: " + failure.Stderr.DiscardedBytes.ToString(CultureInfo.InvariantCulture));
            }
            if (state.Phase == ShellPhase.EngineFailed) parts.Add("アプリを終了して起動し直してください");
            return parts.Count == 0 ? null : string.Join(Environment.NewLine, parts);
        }
    }

    public string? StartDisabledReason
    {
        get
        {
            if (StartRecording.CanExecute(null)) return null;
            var state = Snapshot;
            if (_selectedSource is not EngineSource source) return "音声ソースを選択してください";
            if (state.Capabilities is { } capabilities && !capabilities.Sources.Contains(source)) return "この音声ソースは利用できません";
            if (StartRecording.Execution is { IsCompleted: false } || state.IsPending(EngineCommandName.RecordingStart))
                return "録音を開始しています";
            if (state.IsPending(EngineCommandName.ModelsPrepare)) return "処理中です";
            if (state.IsPending(EngineCommandName.RecordingStop) || state.IsPending(EngineCommandName.DevicesList) ||
                state.IsPending(EngineCommandName.SettingsReplace)) return "処理中です";
            if (state.Capabilities is null) return "音声ソースを確認できません";
            if (_selectedDevice is null) return "デバイスを選択してください";
            if (_selectedDevice is EngineDevice.Id id &&
                (state.Devices is not { } devices || devices.Source != source || devices.Devices is null ||
                    !devices.Devices.Any(endpoint => endpoint.ID == id.ID))) return "選択したデバイスは利用できません";
            return EngineReadinessReason(state);
        }
    }

    private void ReconcileDisplay(object? sender, EventArgs args)
    {
        var tail = Snapshot.Transcript.Tail;
        if (_hasLastTail && ReferenceEquals(tail, _lastTail)) return;
        var source = tail is null ? Array.Empty<EngineTranscriptRow>() : tail.Rows;
        var projected = new ShellTranscriptRowViewModel[source.Length];
        EngineSpeakerLabel[]? previousHeadings = null;
        for (var i = 0; i < source.Length; i++)
        {
            var row = source[i];
            projected[i] = new ShellTranscriptRowViewModel(row.RowID, row.Text,
                string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}", row.StartMS / 60_000, row.StartMS / 1_000 % 60),
                HeadingText(row.Headings, previousHeadings),
                row.ClauseState == EngineClauseState.AwaitingNextSegment ? "発話文の続き待ち" : string.Empty);
            previousHeadings = row.Headings;
        }

        var projectedRowIDs = projected.Select(row => row.RowID).ToHashSet(StringComparer.Ordinal);
        for (var i = _rows.Count - 1; i >= 0; i--)
            if (!projectedRowIDs.Contains(_rows[i].RowID)) _rows.RemoveAt(i);

        for (var i = 0; i < projected.Length; i++)
        {
            var wanted = projected[i];
            if (i < _rows.Count && _rows[i].RowID == wanted.RowID)
            {
                if (_rows[i] != wanted) _rows[i] = wanted;
                continue;
            }
            var found = -1;
            for (var j = i + 1; j < _rows.Count; j++)
                if (_rows[j].RowID == wanted.RowID) { found = j; break; }
            if (found < 0) _rows.Insert(i, wanted);
            else
            {
                _rows.Move(found, i);
                if (_rows[i] != wanted) _rows[i] = wanted;
            }
        }
        _lastTail = tail;
        _hasLastTail = true;
    }

    private static string HeadingText(EngineSpeakerLabel[] headings, EngineSpeakerLabel[]? previous) =>
        headings.Length == 0 || previous is not null && headings.AsSpan().SequenceEqual(previous)
            ? string.Empty
            : string.Join(" / ", headings.Select(SpeakerLabel));

    private static string SpeakerLabel(EngineSpeakerLabel speaker) => speaker switch
    {
        EngineSpeakerLabel.Speaker1 => "Speaker 1",
        EngineSpeakerLabel.Speaker2 => "Speaker 2",
        EngineSpeakerLabel.Speaker3 => "Speaker 3",
        EngineSpeakerLabel.Speaker4 => "Speaker 4",
        EngineSpeakerLabel.Speaker5 => "Speaker 5",
        EngineSpeakerLabel.Speaker6 => "Speaker 6",
        EngineSpeakerLabel.Speaker7 => "Speaker 7",
        EngineSpeakerLabel.Other => "OTHER",
        EngineSpeakerLabel.Unknown => "UNKNOWN",
        _ => throw new InvalidOperationException($"Unknown speaker label: {speaker}.")
    };

    private static string EngineReadinessReason(ShellState state)
    {
        var engine = state.Engine;
        if (state.Phase != ShellPhase.Running || engine is null) return "エンジンの準備ができていません";
        var presentation = engine.Presentation;
        if (engine.Recording is not null) return presentation.RecordingStatusText;
        if (presentation.PreparationPhase is EnginePreparationPhase.Preparing or EnginePreparationPhase.Failed)
            return presentation.PreparationStatusText ??
                throw new InvalidOperationException("Preparation status text is required for this preparation phase.");
        return presentation.RecordingStatusText;
    }
}
