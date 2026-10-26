namespace MacAmbientJev.Protocol;

public static class CanonicalUInt64
{
    public static ulong Parse(ReadOnlySpan<char> decimalValue)
    {
        if (decimalValue.IsEmpty || decimalValue[0] is < '1' or > '9')
        {
            throw new ProtocolException(ProtocolError.InvalidId);
        }

        ulong value = (ulong)(decimalValue[0] - '0');
        for (var index = 1; index < decimalValue.Length; index++)
        {
            var character = decimalValue[index];
            if (character is < '0' or > '9')
            {
                throw new ProtocolException(ProtocolError.InvalidId);
            }

            var digit = (ulong)(character - '0');
            if (value > (ulong.MaxValue - digit) / 10)
            {
                throw new ProtocolException(ProtocolError.InvalidId);
            }

            value = value * 10 + digit;
        }

        return value;
    }
}
