using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace MacAmbientJev.Protocol;

[AttributeUsage(AttributeTargets.Class | AttributeTargets.Struct, Inherited = false)]
public sealed class WireObjectAttribute : Attribute;

[AttributeUsage(AttributeTargets.Property, Inherited = false)]
public sealed class WireMemberAttribute(string name) : Attribute
{
    public string Name { get; } = name ?? throw new ArgumentNullException(nameof(name));

    public bool IsNullable { get; set; }
}

[AttributeUsage(AttributeTargets.Property, Inherited = false)]
public sealed class WireFlattenAttribute : Attribute;

[AttributeUsage(AttributeTargets.Class, Inherited = false)]
public sealed class WireUnionAttribute(string discriminator, Type enumType) : Attribute
{
    public string Discriminator { get; } = discriminator ?? throw new ArgumentNullException(nameof(discriminator));

    public Type EnumType { get; } = enumType ?? throw new ArgumentNullException(nameof(enumType));
}

[AttributeUsage(AttributeTargets.Class, Inherited = false)]
public sealed class WireCaseAttribute(string tag) : Attribute
{
    public string Tag { get; } = tag ?? throw new ArgumentNullException(nameof(tag));
}

[AttributeUsage(AttributeTargets.Field, Inherited = false)]
public sealed class WireValueAttribute(string value) : Attribute
{
    public string Value { get; } = value ?? throw new ArgumentNullException(nameof(value));
}

public interface IWireValidatable
{
    void Validate(string path);
}

public enum WireError
{
    UnknownMember,
    MissingMember,
    WrongType,
    UnknownValue,
    OutOfRange,
    Constraint,
    UnsupportedVersion,
    OversizedRow,
}

public sealed class WireDecodeException : Exception
{
    public WireError Error { get; }

    public string Path { get; }

    public WireDecodeException(WireError error, string path, string message) : base(message)
    {
        Error = error;
        Path = path ?? throw new ArgumentNullException(nameof(path));
    }
}

public sealed record EngineID
{
    public ulong Value { get; }

    public string RawValue => Value.ToString(CultureInfo.InvariantCulture);

    public EngineID(ulong value)
    {
        if (value == 0)
        {
            throw new WireDecodeException(WireError.OutOfRange, "$", "Engine ID must be greater than zero.");
        }

        Value = value;
    }

    public EngineID(string decimalValue)
    {
        try
        {
            Value = CanonicalUInt64.Parse(decimalValue.AsSpan());
        }
        catch (ProtocolException)
        {
            throw new WireDecodeException(
                WireError.OutOfRange,
                "$",
                "Engine ID must be a canonical positive UInt64 decimal string.");
        }
    }
}

public static class WireCheck
{
    public static void Require(bool condition, string path, string message)
    {
        if (!condition)
        {
            throw new WireDecodeException(WireError.Constraint, path, message);
        }
    }

    public static void Nonempty(string? value, string path)
    {
        if (string.IsNullOrEmpty(value))
        {
            throw new WireDecodeException(WireError.Constraint, path, "Value must not be null or empty.");
        }
    }

    public static void OptionalNonempty(string? value, string path)
    {
        if (value is not null && value.Length == 0)
        {
            throw new WireDecodeException(WireError.Constraint, path, "Value must not be empty.");
        }
    }

    public static void Unique<T>(IEnumerable<T> values, string path)
    {
        ArgumentNullException.ThrowIfNull(values);

        var seen = new HashSet<T>();
        var seenStrings = new HashSet<string>(StringComparer.Ordinal);
        foreach (var value in values)
        {
            if (value is string text)
            {
                if (!seenStrings.Add(CanonicalString(text)))
                {
                    throw new WireDecodeException(WireError.Constraint, path, "Values must be unique.");
                }

                continue;
            }

            if (!seen.Add(value))
            {
                throw new WireDecodeException(WireError.Constraint, path, "Values must be unique.");
            }
        }
    }

    public static string CanonicalString(string value)
    {
        ArgumentNullException.ThrowIfNull(value);

        var separatorIndex = value.IndexOf('\uFFFE');
        if (separatorIndex < 0)
        {
            return value.Normalize(NormalizationForm.FormC);
        }

        var builder = new StringBuilder(value.Length);
        var segmentStart = 0;
        while (separatorIndex >= 0)
        {
            builder.Append(value[segmentStart..separatorIndex].Normalize(NormalizationForm.FormC));
            builder.Append('\uFFFE');
            segmentStart = separatorIndex + 1;
            separatorIndex = value.IndexOf('\uFFFE', segmentStart);
        }

        builder.Append(value[segmentStart..].Normalize(NormalizationForm.FormC));
        return builder.ToString();
    }

    public static bool EquivalentStrings(string left, string right) =>
        StringComparer.Ordinal.Equals(CanonicalString(left), CanonicalString(right));

    public static void Range(long value, long min, long max, string path)
    {
        if (value < min || value > max)
        {
            throw new WireDecodeException(WireError.OutOfRange, path, $"Value must be between {min} and {max}.");
        }
    }

    public static void Nonblank(string value, string path)
    {
        if (value is null || IsOnlyFoundationWhitespace(value))
        {
            throw new WireDecodeException(WireError.Constraint, path, "Value must contain a non-whitespace character.");
        }
    }

    public static void NonWhitespace(string value, string path)
    {
        if (value is null || IsOnlyUnicodeWhitespace(value))
        {
            throw new WireDecodeException(WireError.Constraint, path, "Value must contain a non-whitespace character.");
        }
    }

    private static bool IsOnlyFoundationWhitespace(string value)
    {
        foreach (var rune in value.EnumerateRunes())
        {
            var category = Rune.GetUnicodeCategory(rune);
            if (!(rune.Value is >= 0x0009 and <= 0x000D or 0x0085 or 0x200B ||
                  category is UnicodeCategory.SpaceSeparator or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator))
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsOnlyUnicodeWhitespace(string value)
    {
        foreach (var rune in value.EnumerateRunes())
        {
            if (!IsUnicodeWhitespace(rune.Value))
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsUnicodeWhitespace(int scalar) =>
        scalar is >= 0x0009 and <= 0x000D or
            0x0020 or
            0x0085 or
            0x00A0 or
            0x1680 or
            >= 0x2000 and <= 0x200A or
            0x2028 or
            0x2029 or
            0x202F or
            0x205F or
            0x3000;
}
