using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Text.Json;

namespace MacAmbientJev.Protocol;

public static class StrictWireCodec
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public static T Decode<T>(ReadOnlySpan<byte> record) => (T)Decode(typeof(T), record);

    public static object Decode(Type type, ReadOnlySpan<byte> record)
    {
        ArgumentNullException.ThrowIfNull(type);
        StrictJsonValidator.Validate(record);

        using var document = JsonDocument.Parse(record.ToArray());
        EnsureSupportedSchema(type, new HashSet<Type>());
        if (document.RootElement.ValueKind != JsonValueKind.Object)
        {
            throw new ProtocolException(ProtocolError.InvalidJson);
        }

        return DecodeValue(type, document.RootElement, "$", allowNull: false, arrayElement: false);
    }

    public static byte[] Encode<T>(T value)
    {
        var type = typeof(T);
        if (!IsRecordRoot(type))
        {
            throw new InvalidOperationException($"Type '{type}' cannot be encoded as a wire record.");
        }

        EnsureSupportedSchema(type, new HashSet<Type>());
        var json = EncodeValue(type, value, "$", allowNull: false, arrayElement: false);
        var bytes = StrictUtf8.GetBytes(json);
        StrictJsonValidator.Validate(bytes);
        return bytes;
    }

    private static object DecodeValue(Type type, JsonElement element, string path, bool allowNull, bool arrayElement)
    {
        if (element.ValueKind == JsonValueKind.Null)
        {
            if (allowNull && !arrayElement)
            {
                if (Nullable.GetUnderlyingType(type) is not null || !type.IsValueType)
                {
                    return null!;
                }
            }

            throw DecodeError(WireError.WrongType, path, "Null is not allowed here.");
        }

        if (type == typeof(string))
        {
            if (element.ValueKind != JsonValueKind.String)
            {
                throw WrongType(path, "Expected a string.");
            }

            return element.GetString()!;
        }

        if (type == typeof(bool))
        {
            if (element.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            {
                throw WrongType(path, "Expected a boolean.");
            }

            return element.GetBoolean();
        }

        if (type == typeof(int))
        {
            return checked((int)DecodeInteger(element, path, signed: true, 32));
        }

        if (type == typeof(long))
        {
            return DecodeInteger(element, path, signed: true, 64);
        }

        if (type == typeof(ulong))
        {
            return DecodeUnsignedInteger(element, path);
        }

        if (type == typeof(double))
        {
            if (element.ValueKind != JsonValueKind.Number)
            {
                throw WrongType(path, "Expected a number.");
            }

            var value = element.GetDouble();
            if (!double.IsFinite(value))
            {
                throw DecodeError(WireError.OutOfRange, path, "Number is not finite.");
            }

            return value;
        }

        if (type == typeof(EngineID))
        {
            if (element.ValueKind != JsonValueKind.String)
            {
                throw WrongType(path, "Expected an Engine ID decimal string.");
            }

            try
            {
                return new EngineID(element.GetString()!);
            }
            catch (WireDecodeException exception)
            {
                throw DecodeError(exception.Error, path, exception.Message);
            }
        }

        var nullableType = Nullable.GetUnderlyingType(type);
        if (nullableType is not null)
        {
            return DecodeValue(nullableType, element, path, allowNull: false, arrayElement: arrayElement);
        }

        if (type.IsEnum)
        {
            if (element.ValueKind != JsonValueKind.String)
            {
                throw WrongType(path, "Expected a wire enum string.");
            }

            var tag = element.GetString()!;
            var enumSchema = GetEnumSchema(type);
            foreach (var entry in enumSchema.Entries)
            {
                if (StringComparer.Ordinal.Equals(entry.Tag, tag))
                {
                    return entry.Value;
                }
            }

            throw DecodeError(WireError.UnknownValue, path, $"Unknown value '{tag}' for {type.Name}.");
        }

        if (type.IsArray)
        {
            if (!IsVector(type))
            {
                throw new InvalidOperationException($"Only one-dimensional zero-based arrays are supported: '{type}'.");
            }

            if (element.ValueKind != JsonValueKind.Array)
            {
                throw WrongType(path, "Expected an array.");
            }

            var itemType = type.GetElementType()!;
            var values = new object?[element.GetArrayLength()];
            var index = 0;
            foreach (var item in element.EnumerateArray())
            {
                values[index] = DecodeValue(itemType, item, ArrayPath(path, index), allowNull: false, arrayElement: true);
                index++;
            }

            var array = Array.CreateInstance(itemType, values.Length);
            for (var itemIndex = 0; itemIndex < values.Length; itemIndex++)
            {
                array.SetValue(values[itemIndex], itemIndex);
            }

            return array;
        }

        if (element.ValueKind != JsonValueKind.Object)
        {
            throw WrongType(path, "Expected an object.");
        }

        if (TryGetUnionType(type, out var unionType))
        {
            return DecodeUnion(type, unionType, element, path, flattened: false, preselected: null);
        }

        var schema = GetObjectSchema(type, isCase: false);
        return DecodeObject(schema, element, path);
    }

    private static object DecodeObject(ObjectSchema schema, JsonElement element, string path)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw WrongType(path, "Expected an object.");
        }

        CaseSchema? flattenedCase = null;
        UnionSchema? flattenedUnion = null;
        HashSet<string> allowed;
        if (schema.FlattenMember is not null)
        {
            flattenedUnion = GetUnionSchema(schema.FlattenMember.PropertyType);
            flattenedCase = SelectUnionCase(flattenedUnion, element, path);
            allowed = GetFlattenedAllowedKeys(schema, flattenedUnion, flattenedCase);
        }
        else
        {
            allowed = new HashSet<string>(StringComparer.Ordinal);
            foreach (var member in schema.Members)
            {
                if (!allowed.Add(member.WireName!))
                {
                    throw new InvalidOperationException($"Duplicate wire member '{member.WireName}' on '{schema.Type}'.");
                }
            }
        }

        CheckUnknownMembers(element, allowed, path);
        CheckMissingMembers(element, schema.Members, path, flattenedUnion, flattenedCase);

        var instance = DecodeMembers(schema, element, path, flattenedUnion, flattenedCase);
        ValidateInstance(instance, path);
        return instance;
    }

    private static object DecodeMembers(ObjectSchema schema, JsonElement element, string path, UnionSchema? flattenedUnion, CaseSchema? flattenedCase)
    {
        var arguments = new object?[schema.ConstructorParameters.Length];
        for (var index = 0; index < schema.Members.Count; index++)
        {
            var member = schema.Members[index];
            object? value;
            if (member.IsFlatten)
            {
                value = DecodeUnion(member.PropertyType, flattenedUnion!.Type, element, path, flattened: true, flattenedCase);
            }
            else
            {
                var memberPath = MemberPath(path, member.WireName!);
                if (!element.TryGetProperty(member.WireName!, out var memberElement))
                {
                    throw DecodeError(WireError.MissingMember, memberPath, "Required member is missing.");
                }

                value = DecodeValue(member.PropertyType, memberElement, memberPath, member.IsNullable, arrayElement: false);
            }

            arguments[schema.MemberParameterIndexes[index]] = value;
        }

        return InvokeConstructor(schema.Constructor, arguments);
    }

    private static object DecodeUnion(Type requestedType, Type unionType, JsonElement element, string path, bool flattened, CaseSchema? preselected)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw WrongType(path, "Expected a union object.");
        }

        var union = GetUnionSchema(unionType);
        var selected = preselected ?? SelectUnionCase(union, element, path);
        if (!requestedType.IsAssignableFrom(selected.Type))
        {
            throw DecodeError(WireError.WrongType, MemberPath(path, union.Discriminator), "Discriminator selects a different union case.");
        }

        if (!flattened)
        {
            var allowed = GetUnionAllowedKeys(union, selected);
            CheckUnknownMembers(element, allowed, path);
            CheckMissingUnionMembers(element, union, selected, path);
        }

        CheckMissingMembers(element, selected.Object.Members, path, null, null);
        var instance = DecodeMembers(selected.Object, element, path, null, null);
        ValidateInstance(instance, path);
        return instance;
    }

    private static string EncodeValue(Type type, object? value, string path, bool allowNull, bool arrayElement)
    {
        if (value is null)
        {
            if (allowNull && !arrayElement && (!type.IsValueType || Nullable.GetUnderlyingType(type) is not null))
            {
                return "null";
            }

            throw DecodeError(WireError.WrongType, path, "Null is not allowed here.");
        }

        if (type == typeof(string))
        {
            if (value is not string text)
            {
                throw WrongType(path, "Expected a string value.");
            }

            return Quote(text, path);
        }

        if (type == typeof(bool))
        {
            return (bool)value ? "true" : "false";
        }

        if (type == typeof(int) || type == typeof(long))
        {
            return Convert.ToString(value, CultureInfo.InvariantCulture)!;
        }

        if (type == typeof(ulong))
        {
            return ((ulong)value).ToString(CultureInfo.InvariantCulture);
        }

        if (type == typeof(double))
        {
            var number = (double)value;
            if (!double.IsFinite(number))
            {
                throw DecodeError(WireError.OutOfRange, path, "Number must be finite.");
            }

            return FormatDouble(number);
        }

        if (type == typeof(EngineID))
        {
            var id = (EngineID)value;
            if (id.Value == 0)
            {
                throw DecodeError(WireError.OutOfRange, path, "Engine ID must be greater than zero.");
            }

            return Quote(id.RawValue, path);
        }

        var nullableType = Nullable.GetUnderlyingType(type);
        if (nullableType is not null)
        {
            return EncodeValue(nullableType, value, path, allowNull: false, arrayElement);
        }

        if (type.IsEnum)
        {
            var enumSchema = GetEnumSchema(type);
            foreach (var entry in enumSchema.Entries)
            {
                if (entry.Value.Equals(value))
                {
                    return Quote(entry.Tag, path);
                }
            }

            throw DecodeError(WireError.UnknownValue, path, $"Undefined value for {type.Name}.");
        }

        if (type.IsArray)
        {
            if (!IsVector(type))
            {
                throw new InvalidOperationException($"Only one-dimensional zero-based arrays are supported: '{type}'.");
            }

            if (value is not Array array || array.Rank != 1 || array.GetLowerBound(0) != 0)
            {
                throw WrongType(path, "Expected a zero-based array.");
            }

            var builder = new StringBuilder();
            builder.Append('[');
            var itemType = type.GetElementType()!;
            for (var index = 0; index < array.Length; index++)
            {
                if (index != 0)
                {
                    builder.Append(',');
                }

                var item = array.GetValue(index);
                if (item is null)
                {
                    throw DecodeError(WireError.WrongType, ArrayPath(path, index), "Array elements must not be null.");
                }

                builder.Append((string)EncodeValue(itemType, item, ArrayPath(path, index), allowNull: false, arrayElement: true));
            }

            builder.Append(']');
            return builder.ToString();
        }

        if (TryGetUnionType(type, out var unionType))
        {
            return EncodeUnion(type, unionType, value, path);
        }

        var schema = GetObjectSchema(type, isCase: false);
        if (!schema.Type.IsInstanceOfType(value))
        {
            throw WrongType(path, $"Expected a value of type '{schema.Type}'.");
        }

        ValidateInstance(value, path);
        var properties = new List<KeyValuePair<string, string>>();
        AddObjectProperties(schema, value, path, properties);
        return WriteObject(properties, path);
    }

    private static void AddObjectProperties(ObjectSchema schema, object value, string path, List<KeyValuePair<string, string>> properties)
    {
        for (var index = 0; index < schema.Members.Count; index++)
        {
            var member = schema.Members[index];
            var memberValue = GetPropertyValue(member.Property, value);
            if (member.IsFlatten)
            {
                if (memberValue is null)
                {
                    var union = member.PropertyType.GetCustomAttribute<WireUnionAttribute>(inherit: false)!;
                    throw DecodeError(WireError.WrongType, MemberPath(path, union.Discriminator), "Flattened union must not be null.");
                }

                AddUnionProperties(member.PropertyType, memberValue, path, properties);
                continue;
            }

            var memberPath = MemberPath(path, member.WireName!);
            if (memberValue is null && !member.IsNullable)
            {
                throw DecodeError(WireError.WrongType, memberPath, "Null is not allowed for this member.");
            }

            var encoded = (string)EncodeValue(member.PropertyType, memberValue, memberPath, member.IsNullable, arrayElement: false);
            properties.Add(new KeyValuePair<string, string>(member.WireName!, encoded));
        }
    }

    private static string EncodeUnion(Type requestedType, Type unionType, object value, string path)
    {
        var union = GetUnionSchema(unionType);
        if (!union.CasesByType.TryGetValue(value.GetType(), out var selected) || !requestedType.IsAssignableFrom(selected.Type))
        {
            throw WrongType(path, $"Runtime type '{value.GetType()}' is not a case of '{unionType}'.");
        }

        var properties = new List<KeyValuePair<string, string>>();
        AddUnionProperties(unionType, value, path, properties);
        return WriteObject(properties, path);
    }

    private static void AddUnionProperties(Type unionType, object value, string path, List<KeyValuePair<string, string>> properties)
    {
        var union = GetUnionSchema(unionType);
        if (!union.CasesByType.TryGetValue(value.GetType(), out var selected))
        {
            throw WrongType(path, $"Runtime type '{value.GetType()}' is not a case of '{unionType}'.");
        }

        var tag = selected.Case.Tag;
        if (!StringComparer.Ordinal.Equals(tag, selected.EnumEntry.Tag))
        {
            throw new InvalidOperationException($"Union case tag '{tag}' does not match its wire enum mapping.");
        }

        properties.Add(new KeyValuePair<string, string>(union.Discriminator, Quote(tag, MemberPath(path, union.Discriminator))));
        ValidateInstance(value, path);
        AddObjectProperties(selected.Object, value, path, properties);
    }

    private static string WriteObject(List<KeyValuePair<string, string>> properties, string path)
    {
        properties.Sort(static (left, right) => StringComparer.Ordinal.Compare(left.Key, right.Key));
        var builder = new StringBuilder();
        builder.Append('{');
        string? previous = null;
        for (var index = 0; index < properties.Count; index++)
        {
            var property = properties[index];
            if (previous is not null && StringComparer.Ordinal.Equals(previous, property.Key))
            {
                throw DecodeError(WireError.Constraint, MemberPath(path, property.Key), "Wire member names must be unique.");
            }

            if (index != 0)
            {
                builder.Append(',');
            }

            builder.Append(Quote(property.Key, MemberPath(path, property.Key)));
            builder.Append(':');
            builder.Append(property.Value);
            previous = property.Key;
        }

        builder.Append('}');
        return builder.ToString();
    }

    private static void EnsureSupportedSchema(Type type, HashSet<Type> visited)
    {
        if (!visited.Add(type))
        {
            return;
        }

        if (type == typeof(string) || type == typeof(bool) || type == typeof(int) || type == typeof(long) ||
            type == typeof(ulong) || type == typeof(double) || type == typeof(EngineID))
        {
            return;
        }

        var nullableType = Nullable.GetUnderlyingType(type);
        if (nullableType is not null)
        {
            EnsureSupportedSchema(nullableType, visited);
            return;
        }

        if (type.IsEnum)
        {
            _ = GetEnumSchema(type);
            return;
        }

        if (type.IsArray)
        {
            if (!IsVector(type))
            {
                throw new InvalidOperationException($"Only one-dimensional zero-based arrays are supported: '{type}'.");
            }

            EnsureSupportedSchema(type.GetElementType()!, visited);
            return;
        }

        if (TryGetUnionType(type, out var unionType))
        {
            var union = GetUnionSchema(unionType);
            if (type != unionType && !union.CasesByType.ContainsKey(type))
            {
                throw new InvalidOperationException($"Type '{type}' is not a declared case of wire union '{unionType}'.");
            }

            foreach (var arm in union.CasesByTag.Values)
            {
                foreach (var member in arm.Object.Members)
                {
                    EnsureSupportedSchema(member.PropertyType, visited);
                }
            }

            return;
        }

        if (type.GetCustomAttribute<WireObjectAttribute>(inherit: false) is not null)
        {
            var schema = GetObjectSchema(type, isCase: false);
            foreach (var member in schema.Members)
            {
                EnsureSupportedSchema(member.PropertyType, visited);
            }

            return;
        }

        throw new InvalidOperationException($"Unsupported wire type '{type}'.");
    }

    private static UnionSchema GetUnionSchema(Type unionType)
    {
        var attribute = unionType.GetCustomAttribute<WireUnionAttribute>(inherit: false)
            ?? throw new InvalidOperationException($"Type '{unionType}' is not annotated with WireUnion.");
        if (!unionType.IsClass || string.IsNullOrEmpty(attribute.Discriminator))
        {
            throw new InvalidOperationException($"Invalid wire union '{unionType}'.");
        }

        var hasPrivateParameterlessConstructor = false;
        foreach (var constructor in unionType.GetConstructors(BindingFlags.Instance | BindingFlags.NonPublic))
        {
            if (constructor.IsPrivate && constructor.GetParameters().Length == 0)
            {
                hasPrivateParameterlessConstructor = true;
            }
        }

        if (!hasPrivateParameterlessConstructor)
        {
            throw new InvalidOperationException($"Wire union '{unionType}' must have a private parameterless constructor.");
        }

        var enumSchema = GetEnumSchema(attribute.EnumType);
        var byTag = new Dictionary<string, CaseSchema>(StringComparer.Ordinal);
        var byType = new Dictionary<Type, CaseSchema>();
        foreach (var nestedType in unionType.GetNestedTypes(BindingFlags.Public | BindingFlags.NonPublic))
        {
            if (nestedType.BaseType != unionType)
            {
                continue;
            }

            var caseAttribute = nestedType.GetCustomAttribute<WireCaseAttribute>(inherit: false);
            if (caseAttribute is null || !nestedType.IsClass || !nestedType.IsSealed)
            {
                throw new InvalidOperationException($"Every direct nested union arm of '{unionType}' must be a sealed WireCase record.");
            }

            EnumEntry? enumEntry = null;
            foreach (var entry in enumSchema.Entries)
            {
                if (StringComparer.Ordinal.Equals(entry.Tag, caseAttribute.Tag))
                {
                    enumEntry = entry;
                    break;
                }
            }

            if (enumEntry is null)
            {
                throw new InvalidOperationException($"Wire case tag '{caseAttribute.Tag}' is not mapped by enum '{attribute.EnumType}'.");
            }

            var objectSchema = GetObjectSchema(nestedType, isCase: true);
            foreach (var member in objectSchema.Members)
            {
                if (member.IsFlatten)
                {
                    throw new InvalidOperationException($"Wire union arm '{nestedType}' cannot contain a flattened member.");
                }

                if (StringComparer.Ordinal.Equals(member.WireName, attribute.Discriminator))
                {
                    throw new InvalidOperationException($"Union discriminator '{attribute.Discriminator}' collides with a member on '{nestedType}'.");
                }
            }

            var arm = new CaseSchema(nestedType, caseAttribute, enumEntry, objectSchema);
            if (!byTag.TryAdd(caseAttribute.Tag, arm) || !byType.TryAdd(nestedType, arm))
            {
                throw new InvalidOperationException($"Wire union '{unionType}' contains duplicate case tags or types.");
            }
        }

        if (byTag.Count == 0)
        {
            throw new InvalidOperationException($"Wire union '{unionType}' has no declared WireCase arms.");
        }

        return new UnionSchema(unionType, attribute.Discriminator, enumSchema, byTag, byType);
    }

    private static ObjectSchema GetObjectSchema(Type type, bool isCase)
    {
        if (isCase)
        {
            if (type.GetCustomAttribute<WireCaseAttribute>(inherit: false) is null)
            {
                throw new InvalidOperationException($"Union arm '{type}' is missing WireCase.");
            }
        }
        else if (type.GetCustomAttribute<WireObjectAttribute>(inherit: false) is null)
        {
            throw new InvalidOperationException($"Type '{type}' is not annotated with WireObject.");
        }

        if (!(type.IsClass || type.IsValueType) || type.IsAbstract || type.IsInterface)
        {
            throw new InvalidOperationException($"Wire object '{type}' must be a concrete class or struct.");
        }

        var members = new List<MemberSchema>();
        foreach (var property in type.GetProperties(BindingFlags.Instance | BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic))
        {
            var wireMember = property.GetCustomAttribute<WireMemberAttribute>(inherit: false);
            var flatten = property.GetCustomAttribute<WireFlattenAttribute>(inherit: false);
            if (wireMember is null && flatten is null)
            {
                continue;
            }

            if (wireMember is not null && flatten is not null)
            {
                throw new InvalidOperationException($"Property '{property}' cannot be both WireMember and WireFlatten.");
            }

            if (property.GetIndexParameters().Length != 0 || property.GetMethod is null || property.GetMethod.IsStatic || !property.GetMethod.IsPublic)
            {
                throw new InvalidOperationException($"Wire property '{property}' must have a public non-indexed instance getter.");
            }

            if (flatten is not null)
            {
                if (isCase || property.PropertyType.IsValueType || property.PropertyType.GetCustomAttribute<WireUnionAttribute>(inherit: false) is null)
                {
                    throw new InvalidOperationException($"Flattened property '{property}' must be a non-null union base property on a wire object.");
                }

                members.Add(new MemberSchema(property, null, false, true));
            }
            else
            {
                if (string.IsNullOrEmpty(wireMember!.Name))
                {
                    throw new InvalidOperationException($"Wire member '{property}' must have a nonempty name.");
                }

                var isNullableType = Nullable.GetUnderlyingType(property.PropertyType) is not null || !property.PropertyType.IsValueType;
                if (wireMember.IsNullable && !isNullableType)
                {
                    throw new InvalidOperationException($"Nullable wire member '{property}' must use a reference or nullable value type.");
                }

                members.Add(new MemberSchema(property, wireMember.Name, wireMember.IsNullable, false));
            }
        }

        var memberByClrName = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var wireNames = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < members.Count; index++)
        {
            var member = members[index];
            if (!memberByClrName.TryAdd(member.Property.Name, index))
            {
                throw new InvalidOperationException($"Wire object '{type}' has CLR properties that collide ignoring case.");
            }

            if (!member.IsFlatten && !wireNames.Add(member.WireName!))
            {
                throw new InvalidOperationException($"Wire object '{type}' contains duplicate wire member '{member.WireName}'.");
            }
        }

        var publicConstructors = type.GetConstructors(BindingFlags.Instance | BindingFlags.Public);
        var matchingConstructors = new List<(ConstructorInfo Constructor, int[] Indexes)>();
        foreach (var constructor in publicConstructors)
        {
            var parameters = constructor.GetParameters();
            if (parameters.Length != members.Count)
            {
                continue;
            }

            var indexes = new int[parameters.Length];
            var matched = true;
            var used = new HashSet<int>();
            for (var parameterIndex = 0; parameterIndex < parameters.Length; parameterIndex++)
            {
                var parameter = parameters[parameterIndex];
                if (parameter.IsOptional || parameter.IsOut || parameter.ParameterType.IsByRef || parameter.Name is null ||
                    !memberByClrName.TryGetValue(parameter.Name, out var memberIndex) ||
                    parameter.ParameterType != members[memberIndex].Property.PropertyType || !used.Add(memberIndex))
                {
                    matched = false;
                    break;
                }

                indexes[memberIndex] = parameterIndex;
            }

            if (matched && used.Count == members.Count)
            {
                matchingConstructors.Add((constructor, indexes));
            }
        }

        if (matchingConstructors.Count != 1 || (isCase && publicConstructors.Length != 1))
        {
            throw new InvalidOperationException($"Wire object '{type}' must have exactly one public positional constructor binding every annotated property.");
        }

        var selected = matchingConstructors[0];
        var flattenMembers = members.Where(member => member.IsFlatten).ToArray();
        if (flattenMembers.Length > 1)
        {
            throw new InvalidOperationException($"Wire object '{type}' may contain at most one flattened union.");
        }

        if (flattenMembers.Length == 1)
        {
            var union = GetUnionSchema(flattenMembers[0].PropertyType);
            foreach (var key in wireNames)
            {
                if (StringComparer.Ordinal.Equals(key, union.Discriminator))
                {
                    throw new InvalidOperationException($"Flattened discriminator '{union.Discriminator}' collides in '{type}'.");
                }
            }

            foreach (var arm in union.CasesByTag.Values)
            {
                foreach (var member in arm.Object.Members)
                {
                    if (wireNames.Contains(member.WireName!))
                    {
                        throw new InvalidOperationException($"Flattened wire key '{member.WireName}' collides in '{type}'.");
                    }
                }
            }
        }

        if (members.Any(member => member.IsNullable && member.IsFlatten))
        {
            throw new InvalidOperationException($"Wire object '{type}' cannot flatten a nullable union.");
        }

        return new ObjectSchema(type, members, selected.Constructor, selected.Indexes, flattenMembers.SingleOrDefault());
    }

    private static EnumSchema GetEnumSchema(Type enumType)
    {
        if (!enumType.IsEnum)
        {
            throw new InvalidOperationException($"Wire enum type '{enumType}' is not an enum.");
        }

        var entries = new List<EnumEntry>();
        var tags = new HashSet<string>(StringComparer.Ordinal);
        var values = new HashSet<object>();
        foreach (var field in enumType.GetFields(BindingFlags.Public | BindingFlags.Static))
        {
            var attribute = field.GetCustomAttribute<WireValueAttribute>(inherit: false)
                ?? throw new InvalidOperationException($"Enum field '{enumType.Name}.{field.Name}' is missing WireValue.");
            var value = field.GetValue(null)!;
            if (string.IsNullOrEmpty(attribute.Value) || !tags.Add(attribute.Value) || !values.Add(value))
            {
                throw new InvalidOperationException($"Wire enum '{enumType}' contains empty or duplicate wire values.");
            }

            entries.Add(new EnumEntry(attribute.Value, value));
        }

        if (entries.Count == 0)
        {
            throw new InvalidOperationException($"Wire enum '{enumType}' has no values.");
        }

        return new EnumSchema(enumType, entries);
    }

    private static CaseSchema SelectUnionCase(UnionSchema union, JsonElement element, string path)
    {
        var discriminatorPath = MemberPath(path, union.Discriminator);
        if (!element.TryGetProperty(union.Discriminator, out var discriminator))
        {
            throw DecodeError(WireError.MissingMember, discriminatorPath, "Required discriminator is missing.");
        }

        if (discriminator.ValueKind != JsonValueKind.String)
        {
            throw WrongType(discriminatorPath, "Union discriminator must be a string.");
        }

        var tag = discriminator.GetString()!;
        if (!union.CasesByTag.TryGetValue(tag, out var selected))
        {
            throw DecodeError(WireError.UnknownValue, discriminatorPath, $"Unknown union discriminator '{tag}'.");
        }

        return selected;
    }

    private static HashSet<string> GetUnionAllowedKeys(UnionSchema union, CaseSchema selected)
    {
        var keys = new HashSet<string>(StringComparer.Ordinal) { union.Discriminator };
        foreach (var member in selected.Object.Members)
        {
            if (!keys.Add(member.WireName!))
            {
                throw new InvalidOperationException($"Union discriminator '{union.Discriminator}' collides with a member on '{selected.Type}'.");
            }
        }

        return keys;
    }

    private static HashSet<string> GetFlattenedAllowedKeys(ObjectSchema schema, UnionSchema union, CaseSchema selected)
    {
        var keys = GetUnionAllowedKeys(union, selected);
        foreach (var member in schema.Members)
        {
            if (member.IsFlatten)
            {
                continue;
            }

            if (!keys.Add(member.WireName!))
            {
                throw new InvalidOperationException($"Flattened wire key '{member.WireName}' collides in '{schema.Type}'.");
            }
        }

        return keys;
    }

    private static void CheckUnknownMembers(JsonElement element, HashSet<string> allowed, string path)
    {
        foreach (var property in element.EnumerateObject())
        {
            if (!allowed.Contains(property.Name))
            {
                throw DecodeError(WireError.UnknownMember, MemberPath(path, property.Name), "Unknown member.");
            }
        }
    }

    private static void CheckMissingMembers(JsonElement element, List<MemberSchema> members, string path, UnionSchema? union, CaseSchema? selected)
    {
        foreach (var member in members)
        {
            if (member.IsFlatten)
            {
                continue;
            }

            var memberPath = MemberPath(path, member.WireName!);
            if (!element.TryGetProperty(member.WireName!, out _))
            {
                throw DecodeError(WireError.MissingMember, memberPath, "Required member is missing.");
            }
        }

        if (union is not null && selected is not null)
        {
            CheckMissingUnionMembers(element, union, selected, path);
        }
    }

    private static void CheckMissingUnionMembers(JsonElement element, UnionSchema union, CaseSchema selected, string path)
    {
        var discriminatorPath = MemberPath(path, union.Discriminator);
        if (!element.TryGetProperty(union.Discriminator, out _))
        {
            throw DecodeError(WireError.MissingMember, discriminatorPath, "Required discriminator is missing.");
        }

        CheckMissingMembers(element, selected.Object.Members, path, null, null);
    }

    private static object? GetPropertyValue(PropertyInfo property, object instance)
    {
        try
        {
            return property.GetValue(instance);
        }
        catch (TargetInvocationException exception) when (exception.InnerException is not null)
        {
            ExceptionDispatchInfo.Capture(exception.InnerException).Throw();
            throw new InvalidOperationException("Unreachable after rethrow.");
        }
    }

    private static object InvokeConstructor(ConstructorInfo constructor, object?[] arguments)
    {
        try
        {
            return constructor.Invoke(arguments);
        }
        catch (TargetInvocationException exception) when (exception.InnerException is not null)
        {
            ExceptionDispatchInfo.Capture(exception.InnerException).Throw();
            throw new InvalidOperationException("Unreachable after rethrow.");
        }
    }

    private static void ValidateInstance(object instance, string path)
    {
        if (instance is IWireValidatable validatable)
        {
            validatable.Validate(path);
        }
    }

    private static long DecodeInteger(JsonElement element, string path, bool signed, int bits)
    {
        try
        {
            var magnitude = ParseIntegralMagnitude(element, path, signed, bits, out var negative);
            if (negative && magnitude != "0")
            {
                return long.Parse("-" + magnitude, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
            }

            return long.Parse(magnitude, NumberStyles.None, CultureInfo.InvariantCulture);
        }
        catch (WireDecodeException exception) when
            (exception.Error == WireError.WrongType && TrySwiftRoundedInteger(element, signed, bits, out var rounded))
        {
            return long.Parse(rounded, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
        }
    }

    private static ulong DecodeUnsignedInteger(JsonElement element, string path)
    {
        try
        {
            var magnitude = ParseIntegralMagnitude(element, path, signed: false, bits: 64, out _);
            return ulong.Parse(magnitude, NumberStyles.None, CultureInfo.InvariantCulture);
        }
        catch (WireDecodeException exception) when
            (exception.Error == WireError.WrongType && TrySwiftRoundedInteger(element, signed: false, bits: 64, out var rounded))
        {
            return ulong.Parse(rounded, NumberStyles.None, CultureInfo.InvariantCulture);
        }
    }

    private static bool TrySwiftRoundedInteger(JsonElement element, bool signed, int bits, out string value)
    {
        value = string.Empty;
        if (element.ValueKind != JsonValueKind.Number)
        {
            return false;
        }

        var number = element.GetDouble();
        if (!double.IsFinite(number) || Math.Abs(number) >= 9_007_199_254_740_992d || Math.Truncate(number) != number)
        {
            return false;
        }

        if (signed)
        {
            if (bits == 32)
            {
                if (number < int.MinValue || number > int.MaxValue)
                {
                    return false;
                }

                value = ((int)number).ToString(CultureInfo.InvariantCulture);
                return true;
            }

            value = ((long)number).ToString(CultureInfo.InvariantCulture);
            return true;
        }

        if (number < 0)
        {
            return false;
        }

        value = ((ulong)number).ToString(CultureInfo.InvariantCulture);
        return true;
    }

    private static string ParseIntegralMagnitude(JsonElement element, string path, bool signed, int bits, out bool negative)
    {
        if (element.ValueKind != JsonValueKind.Number)
        {
            throw WrongType(path, "Expected an integer number.");
        }

        var raw = element.GetRawText();
        var index = 0;
        negative = raw[index] == '-';
        if (negative)
        {
            index++;
        }

        var exponentIndex = raw.IndexOfAny(['e', 'E'], index);
        var significandEnd = exponentIndex >= 0 ? exponentIndex : raw.Length;
        var exponent = exponentIndex >= 0 ? ParseExponent(raw, exponentIndex + 1) : 0;
        var fractionDigits = 0;
        var digits = new StringBuilder(significandEnd - index);
        var afterDecimal = false;
        for (; index < significandEnd; index++)
        {
            var character = raw[index];
            if (character == '.')
            {
                afterDecimal = true;
            }
            else
            {
                digits.Append(character);
                if (afterDecimal)
                {
                    fractionDigits++;
                }
            }
        }

        var digitText = digits.ToString();
        var firstNonzero = 0;
        while (firstNonzero < digitText.Length && digitText[firstNonzero] == '0')
        {
            firstNonzero++;
        }

        if (firstNonzero == digitText.Length)
        {
            return "0";
        }

        digitText = digitText[firstNonzero..];
        var scale = exponent - fractionDigits;
        if (scale < 0)
        {
            var removeCount = -scale;
            if (removeCount > digitText.Length)
            {
                throw WrongType(path, "Number is fractional and cannot be decoded as an integer.");
            }

            for (var removeIndex = digitText.Length - removeCount; removeIndex < digitText.Length; removeIndex++)
            {
                if (digitText[removeIndex] != '0')
                {
                    throw WrongType(path, "Number is fractional and cannot be decoded as an integer.");
                }
            }

            digitText = digitText[..(digitText.Length - removeCount)];
            if (digitText.Length == 0)
            {
                return "0";
            }
        }

        if (!signed && negative)
        {
            throw DecodeError(WireError.OutOfRange, path, "Unsigned integer cannot be negative.");
        }

        var maxDigits = bits == 32 ? 10 : 20;
        var limit = signed
            ? (negative
                ? bits == 32 ? "2147483648" : "9223372036854775808"
                : bits == 32 ? "2147483647" : "9223372036854775807")
            : "18446744073709551615";

        var resultingLength = digitText.Length + Math.Max(scale, 0);
        if (resultingLength > maxDigits)
        {
            throw DecodeError(WireError.OutOfRange, path, "Integer is outside the supported range.");
        }

        if (scale > 0)
        {
            digitText += new string('0', scale);
        }

        if (digitText.Length > limit.Length ||
            (digitText.Length == limit.Length && StringComparer.Ordinal.Compare(digitText, limit) > 0))
        {
            throw DecodeError(WireError.OutOfRange, path, "Integer is outside the supported range.");
        }

        return digitText;
    }

    private static int ParseExponent(string raw, int index)
    {
        var negative = false;
        if (raw[index] is '+' or '-')
        {
            negative = raw[index] == '-';
            index++;
        }

        var cap = StrictJsonValidator.MaxLineBytes + 2;
        var value = 0;
        for (; index < raw.Length; index++)
        {
            var digit = raw[index] - '0';
            if (value > (cap - digit) / 10)
            {
                value = cap;
            }
            else
            {
                value = value * 10 + digit;
            }
        }

        return negative ? -value : value;
    }

    private static string FormatDouble(double value)
    {
        if (value == 0)
        {
            return BitConverter.DoubleToInt64Bits(value) < 0 ? "-0" : "0";
        }

        var roundTrip = value.ToString("R", CultureInfo.InvariantCulture);
        var negative = roundTrip[0] == '-';
        var start = negative ? 1 : 0;
        var exponentIndex = roundTrip.IndexOfAny(['E', 'e'], start);
        var exponent = exponentIndex < 0
            ? 0
            : int.Parse(roundTrip.AsSpan(exponentIndex + 1), NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture);
        var mantissaEnd = exponentIndex < 0 ? roundTrip.Length : exponentIndex;
        var decimalIndex = roundTrip.IndexOf('.', start, mantissaEnd - start);
        var integerDigits = decimalIndex < 0 ? mantissaEnd - start : decimalIndex - start;
        var digits = new StringBuilder(mantissaEnd - start);
        for (var index = start; index < mantissaEnd; index++)
        {
            if (roundTrip[index] != '.')
            {
                digits.Append(roundTrip[index]);
            }
        }

        var digitText = digits.ToString();
        var leadingZeros = 0;
        while (leadingZeros < digitText.Length && digitText[leadingZeros] == '0')
        {
            leadingZeros++;
        }

        digitText = digitText[leadingZeros..];
        var scientificExponent = integerDigits + exponent - leadingZeros - 1;
        var lastDigit = digitText.Length;
        while (lastDigit > 1 && digitText[lastDigit - 1] == '0')
        {
            lastDigit--;
        }

        var significantDigits = digitText[..lastDigit];
        var sign = negative ? "-" : string.Empty;
        if (scientificExponent < -4 || scientificExponent >= 16)
        {
            var mantissa = significantDigits.Length == 1
                ? significantDigits
                : significantDigits[0] + "." + significantDigits[1..];
            var exponentSign = scientificExponent < 0 ? "-" : "+";
            var exponentDigits = Math.Abs(scientificExponent).ToString(CultureInfo.InvariantCulture).PadLeft(2, '0');
            return sign + mantissa + "e" + exponentSign + exponentDigits;
        }

        var decimalPosition = integerDigits + exponent - leadingZeros;
        string decimalValue;
        if (decimalPosition <= 0)
        {
            decimalValue = "0." + new string('0', -decimalPosition) + digitText;
        }
        else if (decimalPosition >= digitText.Length)
        {
            decimalValue = digitText + new string('0', decimalPosition - digitText.Length);
        }
        else
        {
            decimalValue = digitText[..decimalPosition] + "." + digitText[decimalPosition..];
        }

        var trailingDecimal = decimalValue.IndexOf('.');
        if (trailingDecimal >= 0)
        {
            decimalValue = decimalValue.TrimEnd('0').TrimEnd('.');
        }

        return sign + decimalValue;
    }

    private static string Quote(string value, string path)
    {
        var builder = new StringBuilder(value.Length + 2);
        builder.Append('"');
        for (var index = 0; index < value.Length; index++)
        {
            var character = value[index];
            switch (character)
            {
                case '"':
                    builder.Append("\\\"");
                    break;
                case '\\':
                    builder.Append("\\\\");
                    break;
                case '\b':
                    builder.Append("\\b");
                    break;
                case '\f':
                    builder.Append("\\f");
                    break;
                case '\n':
                    builder.Append("\\n");
                    break;
                case '\r':
                    builder.Append("\\r");
                    break;
                case '\t':
                    builder.Append("\\t");
                    break;
                default:
                    if (character < 0x20)
                    {
                        builder.Append("\\u00");
                        builder.Append(((int)character).ToString("x2", CultureInfo.InvariantCulture));
                    }
                    else if (char.IsHighSurrogate(character))
                    {
                        if (index + 1 >= value.Length || !char.IsLowSurrogate(value[index + 1]))
                        {
                            throw DecodeError(WireError.WrongType, path, "String contains invalid UTF-16.");
                        }

                        builder.Append(character);
                        builder.Append(value[++index]);
                    }
                    else if (char.IsLowSurrogate(character))
                    {
                        throw DecodeError(WireError.WrongType, path, "String contains invalid UTF-16.");
                    }
                    else
                    {
                        builder.Append(character);
                    }

                    break;
            }
        }

        builder.Append('"');
        return builder.ToString();
    }

    private static bool TryGetUnionType(Type type, out Type unionType)
    {
        for (var current = type; current is not null && current != typeof(object); current = current.BaseType!)
        {
            if (current.GetCustomAttribute<WireUnionAttribute>(inherit: false) is not null)
            {
                unionType = current;
                return true;
            }
        }

        unionType = null!;
        return false;
    }

    private static bool IsRecordRoot(Type type) =>
        (type.GetCustomAttribute<WireObjectAttribute>(inherit: false) is not null) ||
        (type.GetCustomAttribute<WireUnionAttribute>(inherit: false) is not null) ||
        TryGetUnionType(type, out _);

    private static bool IsVector(Type type) => type.IsArray && type.GetArrayRank() == 1 && type == type.GetElementType()!.MakeArrayType();

    private static WireDecodeException DecodeError(WireError error, string path, string message) => new(error, path, message);

    private static WireDecodeException WrongType(string path, string message) => DecodeError(WireError.WrongType, path, message);

    private static string MemberPath(string path, string member) => path + "." + member;

    private static string ArrayPath(string path, int index) => path + "[" + index.ToString(CultureInfo.InvariantCulture) + "]";

    private sealed record MemberSchema(PropertyInfo Property, string? WireName, bool IsNullable, bool IsFlatten)
    {
        public Type PropertyType => Property.PropertyType;
    }

    private sealed record ObjectSchema(Type Type, List<MemberSchema> Members, ConstructorInfo Constructor, int[] MemberParameterIndexes, MemberSchema? FlattenMember)
    {
        public ParameterInfo[] ConstructorParameters => Constructor.GetParameters();
    }

    private sealed record EnumEntry(string Tag, object Value);

    private sealed record EnumSchema(Type Type, List<EnumEntry> Entries);

    private sealed record CaseSchema(Type Type, WireCaseAttribute Case, EnumEntry EnumEntry, ObjectSchema Object);

    private sealed record UnionSchema(Type Type, string Discriminator, EnumSchema Enum, Dictionary<string, CaseSchema> CasesByTag, Dictionary<Type, CaseSchema> CasesByType);
}
