using System.Collections.Immutable;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public sealed partial class ShellStore
{
    private long _rowDetailsEpoch;

    /// <summary>
    /// Reads every speaker page for a row in the current tail, without retrying or changing revision.
    /// Rejections and command failures are Failed with the error in State; a newer selection, invalidation,
    /// or tail revision, including the engine's stale_revision, is Superseded and is not an error.
    /// </summary>
    public async Task<RowDetailsRead<ShellRowDetails>> ReadRowDetailsAsync(string rowID)
    {
        ArgumentException.ThrowIfNullOrEmpty(rowID);
        EngineTranscriptRowDetailsPayload? payload = null;
        Task<EngineResult>? request = null;
        long generation = 0, epoch = 0;
        const EngineCommandName name = EngineCommandName.TranscriptRowDetails;
        await Post(() =>
        {
            if (_working.Phase != ShellPhase.Running)
            { _working = _working with { CommandError = "エンジンが起動していません。" }; return; }
            if (_working.Pending.Contains(name))
            { _working = _working with { CommandError = "同じ種類の操作を処理中です。" }; return; }
            var transcript = _working.Transcript;
            if (transcript.Tail is not { } tail || tail.SessionID != transcript.SessionID ||
                !tail.Rows.Any(row => row.RowID == rowID))
            { _working = _working with { CommandError = "詳細を表示する文字起こしの行を選択してください。" }; return; }
            generation = _selectionGeneration;
            epoch = _rowDetailsEpoch;
            payload = new EngineTranscriptRowDetailsPayload(tail.SessionID, tail.Revision, rowID, null, 200);
            _working = _working with { Pending = _working.Pending.Add(name), CommandError = null };
            try { request = _client.SendAsync(new EngineCommand.TranscriptRowDetails(payload)); }
            catch (Exception exception) { HandleRequestFailure(name, exception, true); }
        }).ConfigureAwait(false);
        if (payload is null || request is null) return new RowDetailsRead<ShellRowDetails>.Failed();

        bool IsCurrent()
        {
            var transcript = _working.Transcript;
            return generation == _selectionGeneration && epoch == _rowDetailsEpoch &&
                _working.Phase == ShellPhase.Running && transcript.SessionID == payload.SessionID &&
                transcript.Tail is { } tail && tail.Revision == payload.Revision &&
                tail.Rows.Any(row => row.RowID == rowID);
        }

        var speakers = ImmutableArray.CreateBuilder<EngineTranscriptSpeakerSpan>();
        var cursors = new HashSet<string>(StringComparer.Ordinal);
        EngineTranscriptRowDetailsPage? firstPage = null;
        while (true)
        {
            EngineResult result;
            try { result = await AwaitClientTask(request).ConfigureAwait(false); }
            catch (OperationCanceledException) when (_stop.IsCancellationRequested) { throw; }
            catch (Exception exception)
            {
                var superseded = false;
                await Post(() =>
                {
                    // The engine can publish a newer revision before this store receives it.
                    superseded = exception is EngineRequestException { Failure.Code: EngineErrorCode.StaleRevision } ||
                        exception is EngineRequestException && !IsCurrent();
                    if (superseded) RemovePending(name);
                    else HandleRequestFailure(name, exception, false);
                }).ConfigureAwait(false);
                return superseded ? new RowDetailsRead<ShellRowDetails>.Superseded() : new RowDetailsRead<ShellRowDetails>.Failed();
            }

            RowDetailsRead<ShellRowDetails> outcome = new RowDetailsRead<ShellRowDetails>.Failed();
            Task<EngineResult>? nextRequest = null;
            await Post(() =>
            {
                try
                {
                    if (result is not EngineResult.TranscriptRowDetails response)
                        throw new InvalidOperationException("transcript.row_details returned an unexpected result type.");
                    var page = response.Result;
                    if (page.SessionID != payload.SessionID || page.Revision != payload.Revision || page.RowID != rowID)
                        throw new InvalidOperationException("transcript.row_details returned another session, revision, or row.");
                    if (firstPage is not null && (page.ClauseState != firstPage.ClauseState || page.ClauseStateText != firstPage.ClauseStateText))
                        throw new InvalidOperationException("transcript.row_details changed clause state between pages.");
                    if (firstPage is null && page.PreviousCursor is not null)
                        throw new InvalidOperationException("transcript.row_details returned a previous cursor on its first page.");
                    if (!IsCurrent()) { RemovePending(name); outcome = new RowDetailsRead<ShellRowDetails>.Superseded(); return; }
                    firstPage ??= page;
                    speakers.AddRange(page.Speakers);
                    if (page.NextCursor is null)
                    {
                        outcome = new RowDetailsRead<ShellRowDetails>.Read(new ShellRowDetails(page.SessionID,
                            page.Revision, rowID, page.ClauseState, page.ClauseStateText, speakers.ToImmutable()));
                        RemovePending(name);
                        _working = _working with { CommandError = null };
                        return;
                    }
                    if (page.Speakers.Length == 0 || !cursors.Add(page.NextCursor))
                        throw new InvalidOperationException("transcript.row_details returned a non-advancing cursor.");
                    payload = payload with { Cursor = page.NextCursor };
                    try { nextRequest = _client.SendAsync(new EngineCommand.TranscriptRowDetails(payload)); }
                    catch (Exception exception) { HandleRequestFailure(name, exception, true); }
                }
                catch (Exception exception) { FailStore(exception); }
            }).ConfigureAwait(false);
            if (nextRequest is null) return outcome;
            request = nextRequest;
        }
    }
}
