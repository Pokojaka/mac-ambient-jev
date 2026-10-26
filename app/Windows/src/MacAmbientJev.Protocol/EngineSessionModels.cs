using System.Linq;

namespace MacAmbientJev.Protocol;

[WireUnion("kind", typeof(EngineSessionSourceKind))]
public abstract record EngineSessionSource : IWireValidatable
{
    private EngineSessionSource() { }

    public abstract void Validate(string path);

    public EngineSessionSourceKind Kind => StrictWireCodec.CaseValue<EngineSessionSourceKind>(this);

    [WireCase("microphone")]
    public sealed record Microphone() : EngineSessionSource
    {
        public override void Validate(string path) { }
    }

    [WireCase("system_audio")]
    public sealed record SystemAudio() : EngineSessionSource
    {
        public override void Validate(string path) { }
    }

    [WireCase("imported")]
    public sealed record Imported(
        [property: WireMember("original_filename")] string OriginalFilename) : EngineSessionSource, IWireValidatable
    {
        public override void Validate(string path) => WireCheck.Nonempty(OriginalFilename, path + ".original_filename");
    }
}

[WireUnion("kind", typeof(EngineSessionAudioKind))]
public abstract record EngineSessionAudio : IWireValidatable
{
    private EngineSessionAudio() { }

    public abstract void Validate(string path);

    public EngineSessionAudioKind Kind => StrictWireCodec.CaseValue<EngineSessionAudioKind>(this);

    [WireCase("available")]
    public sealed record Available() : EngineSessionAudio
    {
        public override void Validate(string path) { }
    }

    [WireCase("missing")]
    public sealed record Missing() : EngineSessionAudio
    {
        public override void Validate(string path) { }
    }

    [WireCase("unreadable")]
    public sealed record Unreadable(
        [property: WireMember("reason")] string Reason) : EngineSessionAudio, IWireValidatable
    {
        public override void Validate(string path) => WireCheck.Nonempty(Reason, path + ".reason");
    }
}

[WireUnion("kind", typeof(EngineSessionMetadataKind))]
public abstract record EngineSessionMetadata : IWireValidatable
{
    private EngineSessionMetadata() { }

    public abstract void Validate(string path);

    public EngineSessionMetadataKind Kind => StrictWireCodec.CaseValue<EngineSessionMetadataKind>(this);

    [WireCase("unreadable")]
    public sealed record Unreadable(
        [property: WireMember("reason")] string Reason) : EngineSessionMetadata, IWireValidatable
    {
        public override void Validate(string path) => WireCheck.Nonempty(Reason, path + ".reason");
    }

    [WireCase("readable")]
    public sealed record Readable(
        [property: WireMember("created_at")] double CreatedAt,
        [property: WireMember("source")] EngineSessionSource Source,
        [property: WireMember("audio")] EngineSessionAudio Audio,
        [property: WireMember("has_transcript")] bool HasTranscript) : EngineSessionMetadata, IWireValidatable
    {
        public override void Validate(string path)
        {
            WireCheck.Require(double.IsFinite(CreatedAt), path + ".created_at", "created_at must be finite.");
            if (Source is not null)
            {
                Source.Validate(path + ".source");
            }

            if (Audio is not null)
            {
                Audio.Validate(path + ".audio");
            }
        }
    }
}

[WireObject]
public sealed record EngineSessionSummary(
    [property: WireMember("folder_id")] string FolderID,
    [property: WireMember("session_id", IsNullable = true)] string? SessionID,
    [property: WireMember("status")] EngineSessionStatus Status,
    [property: WireMember("error", IsNullable = true)] EngineFailure? Error,
    [property: WireMember("display_name")] string DisplayName,
    [property: WireMember("status_text")] string StatusText,
    [property: WireMember("folder_path")] string FolderPath,
    [property: WireMember("export_path", IsNullable = true)] string? ExportPath,
    [property: WireMember("can_reprocess")] bool CanReprocess,
    [property: WireMember("can_retry_decisions")] bool CanRetryDecisions,
    [property: WireMember("can_export")] bool CanExport,
    [property: WireMember("metadata")] EngineSessionMetadata Metadata) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(FolderID, path + ".folder_id");
        WireCheck.OptionalNonempty(SessionID, path + ".session_id");
        WireCheck.Nonempty(DisplayName, path + ".display_name");
        WireCheck.Nonempty(StatusText, path + ".status_text");
        WireCheck.Nonempty(FolderPath, path + ".folder_path");
        WireCheck.OptionalNonempty(ExportPath, path + ".export_path");

        if (Metadata is not null)
        {
            Metadata.Validate(path + ".metadata");
        }

        if (Status == EngineSessionStatus.Unreadable)
        {
            WireCheck.Require(Error is not null, path + ".error", "Unreadable session requires an error.");
            WireCheck.Require(ExportPath is null, path + ".export_path", "Unreadable session must not have export_path.");
            WireCheck.Require(!CanReprocess, path + ".can_reprocess", "Unreadable session must not allow reprocessing.");
            WireCheck.Require(!CanRetryDecisions, path + ".can_retry_decisions", "Unreadable session must not allow decision retries.");
            WireCheck.Require(!CanExport, path + ".can_export", "Unreadable session must not allow export.");
            if (Metadata is not null)
            {
                WireCheck.Require(Metadata is EngineSessionMetadata.Unreadable, path + ".metadata", "Unreadable session requires unreadable metadata.");
            }
        }
        else
        {
            WireCheck.Require(SessionID is not null, path + ".session_id", "Readable session requires session_id.");
            if (Metadata is not null)
            {
                WireCheck.Require(Metadata is EngineSessionMetadata.Readable, path + ".metadata", "Readable session requires readable metadata.");
            }
        }
    }
}

[WireObject]
public sealed record EngineSessionListResult(
    [property: WireMember("sessions")] EngineSessionSummary[] Sessions,
    [property: WireMember("next_cursor", IsNullable = true)] string? NextCursor,
    [property: WireMember("previous_cursor", IsNullable = true)] string? PreviousCursor) : IWireValidatable
{
    public void Validate(string path)
    {
        if (Sessions is not null)
        {
            WireCheck.Require(Sessions.Length <= 100, path + ".sessions", "sessions must contain at most 100 entries.");
            WireCheck.Unique(Sessions.Where(session => session is not null && session.FolderID is not null).Select(session => session.FolderID), path + ".sessions");
        }

        WireCheck.OptionalNonempty(NextCursor, path + ".next_cursor");
        WireCheck.OptionalNonempty(PreviousCursor, path + ".previous_cursor");
    }
}

[WireObject]
public sealed record EngineExportResult(
    [property: WireMember("session_id")] string SessionID,
    [property: WireMember("destination_path")] string DestinationPath) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(SessionID, path + ".session_id");
        WireCheck.Nonempty(DestinationPath, path + ".destination_path");
    }
}
