using System.Linq;

namespace MacAmbientJev.Protocol;

[WireObject]
public sealed record EngineTranscriptRow(
    [property: WireMember("row_id")] string RowID,
    [property: WireMember("start_ms")] long StartMS,
    [property: WireMember("end_ms")] long EndMS,
    [property: WireMember("text")] string Text,
    [property: WireMember("headings")] EngineSpeakerLabel[] Headings,
    [property: WireMember("clause_state", IsNullable = true)] EngineClauseState? ClauseState) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(RowID, path + ".row_id");
        WireCheck.Require(StartMS >= 0, path + ".start_ms", "start_ms must not be negative.");
        WireCheck.Require(EndMS >= StartMS, path + ".end_ms", "end_ms must not precede start_ms.");
        WireCheck.Nonblank(Text, path + ".text");
    }
}

[WireObject]
public sealed record EngineTranscriptPage(
    [property: WireMember("session_id")] string SessionID,
    [property: WireMember("revision")] EngineID Revision,
    [property: WireMember("rows")] EngineTranscriptRow[] Rows,
    [property: WireMember("next_cursor", IsNullable = true)] string? NextCursor,
    [property: WireMember("previous_cursor", IsNullable = true)] string? PreviousCursor) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(SessionID, path + ".session_id");
        if (Rows is not null)
        {
            WireCheck.Require(Rows.Length <= 200, path + ".rows", "rows must contain at most 200 entries.");
            WireCheck.Unique(Rows.Where(row => row is not null && row.RowID is not null).Select(row => row.RowID), path + ".rows");
        }

        WireCheck.OptionalNonempty(NextCursor, path + ".next_cursor");
        WireCheck.OptionalNonempty(PreviousCursor, path + ".previous_cursor");
    }
}

[WireObject]
public sealed record EngineRowsPayload(
    [property: WireMember("session_id")] string SessionID,
    [property: WireMember("revision")] EngineID Revision,
    [property: WireMember("kind")] EngineRowsKind Kind,
    [property: WireMember("rows")] EngineTranscriptRow[] Rows,
    [property: WireMember("removed_row_ids")] string[] RemovedRowIDs,
    [property: WireMember("next_cursor", IsNullable = true)] string? NextCursor) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(SessionID, path + ".session_id");
        if (Rows is not null && RemovedRowIDs is not null)
        {
            WireCheck.Require(Rows.Length + RemovedRowIDs.Length <= 200, path + ".rows", "rows and removed_row_ids must total at most 200 entries.");
            WireCheck.Unique(Rows.Where(row => row is not null && row.RowID is not null).Select(row => row.RowID), path + ".rows");
            WireCheck.Unique(RemovedRowIDs, path + ".removed_row_ids");
            for (var index = 0; index < RemovedRowIDs.Length; index++)
            {
                WireCheck.Nonempty(RemovedRowIDs[index], path + ".removed_row_ids[" + index + "]");
            }

            WireCheck.Unique(
                Rows.Where(row => row is not null && row.RowID is not null).Select(row => row.RowID).Concat(RemovedRowIDs),
                path + ".rows");
        }

        WireCheck.OptionalNonempty(NextCursor, path + ".next_cursor");
        switch (Kind)
        {
            case EngineRowsKind.Snapshot:
                WireCheck.Require(RemovedRowIDs is not null && RemovedRowIDs.Length == 0, path + ".removed_row_ids", "snapshot must not remove rows.");
                break;
            case EngineRowsKind.Changes:
                WireCheck.Require(NextCursor is null, path + ".next_cursor", "changes must have a null next_cursor.");
                break;
            case EngineRowsKind.ReloadRequired:
                WireCheck.Require(Rows is not null && Rows.Length == 0 && RemovedRowIDs is not null && RemovedRowIDs.Length == 0,
                    path + ".rows", "reload_required must not include row data.");
                WireCheck.Require(NextCursor is null, path + ".next_cursor", "reload_required must have a null next_cursor.");
                break;
        }
    }
}

[WireObject]
public sealed record EngineTranscriptSpeakerSpan(
    [property: WireMember("speaker_id")] string SpeakerID,
    [property: WireMember("display_label")] string DisplayLabel,
    [property: WireMember("start_ms")] long StartMS,
    [property: WireMember("end_ms")] long EndMS) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(SpeakerID, path + ".speaker_id");
        WireCheck.Nonempty(DisplayLabel, path + ".display_label");
        WireCheck.Require(StartMS >= 0, path + ".start_ms", "start_ms must not be negative.");
        WireCheck.Require(EndMS >= 0, path + ".end_ms", "end_ms must not be negative.");
        WireCheck.Require(EndMS >= StartMS, path + ".end_ms", "end_ms must not precede start_ms.");
    }
}

[WireObject]
public sealed record EngineTranscriptRowDetailsPage(
    [property: WireMember("session_id")] string SessionID,
    [property: WireMember("revision")] EngineID Revision,
    [property: WireMember("row_id")] string RowID,
    [property: WireMember("clause_state")] EngineClauseState ClauseState,
    [property: WireMember("clause_state_text")] string ClauseStateText,
    [property: WireMember("speakers")] EngineTranscriptSpeakerSpan[] Speakers,
    [property: WireMember("next_cursor", IsNullable = true)] string? NextCursor,
    [property: WireMember("previous_cursor", IsNullable = true)] string? PreviousCursor) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(SessionID, path + ".session_id");
        WireCheck.Nonempty(RowID, path + ".row_id");
        WireCheck.Nonempty(ClauseStateText, path + ".clause_state_text");
        if (Speakers is not null)
        {
            WireCheck.Require(Speakers.Length <= 200, path + ".speakers", "speakers must contain at most 200 entries.");
        }

        WireCheck.OptionalNonempty(NextCursor, path + ".next_cursor");
        WireCheck.OptionalNonempty(PreviousCursor, path + ".previous_cursor");
    }
}
