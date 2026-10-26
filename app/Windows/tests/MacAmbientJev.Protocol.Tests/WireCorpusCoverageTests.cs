using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using MacAmbientJev.Protocol;
using Xunit;

namespace MacAmbientJev.Protocol.Tests;

public sealed class WireCorpusCoverageTests
{
    [Fact]
    public void linkedCorpusCoversTheReflectedWireContract()
    {
        Assert.Empty(WireCorpusCoverage.Analyze(WireCorpusTests.ReadCorpus()));
    }
}

internal static class WireCorpusCoverage
{
    private static readonly Type[] ContractTypes = typeof(EngineRequest).Assembly.GetTypes();
    private static readonly IReadOnlySet<string> Required = BuildRequiredTokens();

    internal static IReadOnlySet<string> RequiredTokens() => Required;

    internal static IReadOnlyList<string> Analyze(IReadOnlyList<byte[]> records)
    {
        ArgumentNullException.ThrowIfNull(records);
        var observed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var record in records)
        {
            ArgumentNullException.ThrowIfNull(record);
            using var document = JsonDocument.Parse(record);
            if (document.RootElement.TryGetProperty("event", out _))
            {
                Observe(EngineCodec.DecodeOutput(record), observed);
            }
            else
            {
                Observe(EngineCodec.DecodeRequest(record), observed);
            }
        }

        var issues = Required.Except(observed, StringComparer.Ordinal)
            .Select(token => $"Missing wire corpus coverage: {token}")
            .Concat(observed.Except(Required, StringComparer.Ordinal)
                .Select(token => $"Unregistered wire corpus token: {token}"));
        return issues.OrderBy(issue => issue, StringComparer.Ordinal).ToArray();
    }

    private static HashSet<string> BuildRequiredTokens()
    {
        var tokens = new HashSet<string>(StringComparer.Ordinal);
        var wireUnions = ContractTypes.Where(type => type.GetCustomAttribute<WireUnionAttribute>(inherit: false) is not null).ToArray();
        var wireObjects = ContractTypes.Where(type => type.GetCustomAttribute<WireObjectAttribute>(inherit: false) is not null).ToArray();
        var wireCases = ContractTypes.Where(type => type.GetCustomAttribute<WireCaseAttribute>(inherit: false) is not null).ToArray();
        var enumTypes = ContractTypes.Where(type => type.IsEnum && EnumFields(type)
            .Any(field => field.GetCustomAttribute<WireValueAttribute>(inherit: false) is not null)).ToHashSet();

        foreach (var type in wireObjects.Concat(wireCases).Where(type => !type.IsAbstract))
        {
            tokens.Add("type " + TypeName(type));
        }

        foreach (var type in ContractTypes)
        {
            foreach (var property in DeclaredProperties(type))
            {
                var member = property.GetCustomAttribute<WireMemberAttribute>(inherit: false);
                var flatten = property.GetCustomAttribute<WireFlattenAttribute>(inherit: false);
                if (member is not null)
                {
                    var ownerName = TypeName(property.DeclaringType ?? type);
                    tokens.Add($"key {ownerName}.{member.Name}");
                    if (member.IsNullable)
                    {
                        tokens.Add($"nullable {ownerName}.{member.Name}=null");
                        tokens.Add($"nullable {ownerName}.{member.Name}=non-null");
                    }
                }

                if (flatten is not null)
                {
                    tokens.Add($"property {TypeName(property.DeclaringType ?? type)}.{property.Name}");
                }

                if (member is not null || flatten is not null)
                {
                    var propertyType = Nullable.GetUnderlyingType(property.PropertyType) ?? property.PropertyType;
                    while (propertyType.IsArray)
                    {
                        propertyType = propertyType.GetElementType()!;
                    }

                    if (propertyType.IsEnum)
                    {
                        enumTypes.Add(propertyType);
                    }
                }
            }
        }

        foreach (var unionType in wireUnions)
        {
            var union = RequiredAttribute<WireUnionAttribute>(unionType);
            if (!union.EnumType.IsEnum)
            {
                throw new InvalidOperationException($"Wire union {TypeName(unionType)} references non-enum {TypeName(union.EnumType)}.");
            }

            enumTypes.Add(union.EnumType);
            tokens.Add($"key {TypeName(unionType)}.{union.Discriminator}");
            foreach (var arm in unionType.GetNestedTypes(BindingFlags.Public | BindingFlags.NonPublic)
                         .Where(nested => nested.BaseType == unionType))
            {
                var wireCase = RequiredAttribute<WireCaseAttribute>(arm);
                if (!arm.IsAbstract)
                {
                    tokens.Add("type " + TypeName(arm));
                }

                tokens.Add($"union {TypeName(unionType)}={wireCase.Tag}");
            }

            foreach (var field in EnumFields(union.EnumType))
            {
                var wireValue = RequiredAttribute<WireValueAttribute>(field);
                tokens.Add($"union {TypeName(unionType)}={wireValue.Value}");
            }
        }

        foreach (var arm in wireCases)
        {
            if (arm.DeclaringType?.GetCustomAttribute<WireUnionAttribute>(inherit: false) is null || arm.BaseType != arm.DeclaringType)
            {
                throw new InvalidOperationException($"Wire case {TypeName(arm)} is not a direct arm of a wire union.");
            }

            _ = RequiredAttribute<WireCaseAttribute>(arm);
        }

        foreach (var enumType in enumTypes)
        {
            foreach (var field in EnumFields(enumType))
            {
                var wireValue = RequiredAttribute<WireValueAttribute>(field);
                tokens.Add($"enum {TypeName(enumType)}={wireValue.Value}");
            }
        }

        return tokens;
    }

    private static void Observe(object value, HashSet<string> observed) => ObserveValue(value.GetType(), value, observed);

    private static void ObserveValue(Type declaredType, object? value, HashSet<string> observed)
    {
        if (value is null)
        {
            return;
        }

        var type = Nullable.GetUnderlyingType(declaredType) ?? declaredType;
        if (type.IsArray)
        {
            foreach (var item in (Array)value)
            {
                ObserveValue(type.GetElementType()!, item, observed);
            }

            return;
        }

        if (type.IsEnum)
        {
            var field = type.GetField(value.ToString()!, BindingFlags.Public | BindingFlags.Static)
                ?? throw new InvalidOperationException($"No enum field for {TypeName(type)} value '{value}'.");
            var wireValue = RequiredAttribute<WireValueAttribute>(field);
            observed.Add($"enum {TypeName(type)}={wireValue.Value}");
            return;
        }

        var runtimeType = value.GetType();
        var unionType = FindUnionType(type) ?? FindUnionType(runtimeType);
        if (unionType is not null)
        {
            var union = RequiredAttribute<WireUnionAttribute>(unionType);
            var wireCase = RequiredAttribute<WireCaseAttribute>(runtimeType);
            observed.Add($"union {TypeName(unionType)}={wireCase.Tag}");
            observed.Add($"key {TypeName(unionType)}.{union.Discriminator}");
            var enumField = EnumFields(union.EnumType).SingleOrDefault(field =>
                field.GetCustomAttribute<WireValueAttribute>(inherit: false)?.Value == wireCase.Tag)
                ?? throw new InvalidOperationException($"Wire union arm {TypeName(runtimeType)} has no {TypeName(union.EnumType)} mapping.");
            observed.Add($"enum {TypeName(union.EnumType)}={RequiredAttribute<WireValueAttribute>(enumField).Value}");
            ObserveObject(runtimeType, value, observed);
            return;
        }

        if (runtimeType.GetCustomAttribute<WireObjectAttribute>(inherit: false) is not null)
        {
            ObserveObject(runtimeType, value, observed);
        }
    }

    private static void ObserveObject(Type type, object value, HashSet<string> observed)
    {
        observed.Add("type " + TypeName(type));
        foreach (var property in DeclaredProperties(type))
        {
            var member = property.GetCustomAttribute<WireMemberAttribute>(inherit: false);
            var flatten = property.GetCustomAttribute<WireFlattenAttribute>(inherit: false);
            if (member is null && flatten is null)
            {
                continue;
            }

            var propertyValue = property.GetValue(value);
            if (flatten is not null)
            {
                observed.Add($"property {TypeName(type)}.{property.Name}");
                ObserveValue(property.PropertyType, propertyValue, observed);
                continue;
            }

            observed.Add($"key {TypeName(type)}.{member!.Name}");
            if (member.IsNullable)
            {
                observed.Add($"nullable {TypeName(type)}.{member.Name}={(propertyValue is null ? "null" : "non-null")}");
            }

            ObserveValue(property.PropertyType, propertyValue, observed);
        }
    }

    private static Type? FindUnionType(Type type)
    {
        for (var current = type; current != typeof(object); current = current.BaseType!)
        {
            if (current.GetCustomAttribute<WireUnionAttribute>(inherit: false) is not null)
            {
                return current;
            }
        }

        return null;
    }

    private static T RequiredAttribute<T>(MemberInfo member) where T : Attribute =>
        member.GetCustomAttribute<T>(inherit: false)
        ?? throw new InvalidOperationException($"{TypeName(member.DeclaringType ?? member as Type ?? typeof(object))} is missing {typeof(T).Name}.");

    private static PropertyInfo[] DeclaredProperties(Type type) => type.GetProperties(
        BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly);

    private static FieldInfo[] EnumFields(Type enumType) => enumType.GetFields(BindingFlags.Public | BindingFlags.Static);

    private static string TypeName(Type type)
    {
        var fullName = type.FullName ?? type.Name;
        var namespacePrefix = type.Namespace is null ? string.Empty : type.Namespace + ".";
        if (fullName.StartsWith(namespacePrefix, StringComparison.Ordinal))
        {
            fullName = fullName[namespacePrefix.Length..];
        }

        return fullName.Replace('+', '.');
    }
}
