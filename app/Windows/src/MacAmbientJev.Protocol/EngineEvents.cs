using System;

namespace MacAmbientJev.Protocol;

[WireObject]
public sealed record EngineAcceptedPayload(
    [property: WireMember("command")] EngineCommandName Command);

[WireUnion("event", typeof(EngineEventName))]
public abstract record EngineEvent
{
    private EngineEvent() { }

    public EngineEventName Name => StrictWireCodec.CaseValue<EngineEventName>(this);

    [WireCase("ready")]
    public sealed record Ready([property: WireMember("payload")] EngineReadyPayload Payload) : EngineEvent;

    [WireCase("state")]
    public sealed record State([property: WireMember("payload")] EngineState Payload) : EngineEvent;

    [WireCase("accepted")]
    public sealed record Accepted([property: WireMember("payload")] EngineAcceptedPayload Payload) : EngineEvent;

    [WireCase("completed")]
    public sealed record Completed([property: WireMember("payload")] EngineResult Payload) : EngineEvent;

    [WireCase("progress")]
    public sealed record Progress([property: WireMember("payload")] EngineProgressPayload Payload) : EngineEvent;

    [WireCase("rows")]
    public sealed record Rows([property: WireMember("payload")] EngineRowsPayload Payload) : EngineEvent;

    [WireCase("error")]
    public sealed record Error([property: WireMember("payload")] EngineFailure Payload) : EngineEvent;
}

[WireObject]
public sealed record EngineOutput(
    [property: WireMember("version")] long Version,
    [property: WireMember("sequence")] EngineID Sequence,
    [property: WireMember("request_id", IsNullable = true)] EngineID? RequestID,
    [property: WireFlatten] EngineEvent Event) : IWireValidatable
{
    public void Validate(string path)
    {
        if (Version != 1)
        {
            throw new WireDecodeException(WireError.UnsupportedVersion, path + ".version", "Only protocol version 1 is supported.");
        }

        if (Event is null)
        {
            return;
        }

        switch (Event)
        {
            case EngineEvent.Ready:
                WireCheck.Require(RequestID is null, path + ".request_id", "ready must be unsolicited.");
                break;
            case EngineEvent.Accepted:
            case EngineEvent.Completed:
                WireCheck.Require(RequestID is not null, path + ".request_id", "accepted and completed require request_id.");
                break;
            case EngineEvent.Error error:
                if (error.Payload is null)
                {
                    throw new WireDecodeException(WireError.WrongType, path + ".payload", "Null is not allowed for this member.");
                }

                WireCheck.Require(RequestID == error.Payload.RequestID, path + ".request_id", "error request_id must match payload.");
                break;
            case EngineEvent.State:
            case EngineEvent.Progress:
            case EngineEvent.Rows:
                break;
            default:
                throw new InvalidOperationException("Unrecognized engine event case.");
        }
    }
}
