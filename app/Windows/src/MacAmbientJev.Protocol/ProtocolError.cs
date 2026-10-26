namespace MacAmbientJev.Protocol;

public enum ProtocolError
{
    InvalidUtf8,
    ByteOrderMark,
    LineTooLong,
    BlankLine,
    InvalidJson,
    NestingTooDeep,
    DuplicateKey,
    InvalidNumber,
    PartialFinalLine,
    ClosedReader,
    InvalidId,
    BareCarriageReturn,
}

public sealed class ProtocolException : Exception
{
    public ProtocolError Error { get; }

    public ProtocolException(ProtocolError error) : base(error.ToString())
    {
        Error = error;
    }
}
