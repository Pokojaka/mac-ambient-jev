namespace MacAmbientJev.Protocol;

internal static class EngineAcceleratorValidation
{
    public static void Hash(string? value, string path)
    {
        WireCheck.Require(
            value is { Length: 64 } && IsLowerHex(value),
            path,
            "Value must be exactly 64 lowercase ASCII hexadecimal characters.");
    }

    private static bool IsLowerHex(string value)
    {
        foreach (var character in value)
        {
            if (!(character is >= '0' and <= '9' or >= 'a' and <= 'f'))
            {
                return false;
            }
        }

        return true;
    }
}

[WireObject]
public sealed record EngineAcceleratorDependency(
    [property: WireMember("path")] string Path,
    [property: WireMember("hash")] string Hash) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(Path, path + ".path");
        EngineAcceleratorValidation.Hash(Hash, path + ".hash");
    }
}

[WireObject]
public sealed record EngineAcceleratorDescriptor(
    [property: WireMember("provider_name")] string ProviderName,
    [property: WireMember("device_id")] string DeviceID,
    [property: WireMember("gpu_name")] string GPUName,
    [property: WireMember("driver_version")] string DriverVersion,
    [property: WireMember("adapter_id")] string AdapterID,
    [property: WireMember("architecture")] string Architecture,
    [property: WireMember("dedicated_vram_bytes", IsNullable = true)] ulong? DedicatedVRAMBytes,
    [property: WireMember("package_identity")] string PackageIdentity,
    [property: WireMember("library_path")] string LibraryPath,
    [property: WireMember("library_hash")] string LibraryHash,
    [property: WireMember("dependencies")] EngineAcceleratorDependency[] Dependencies) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(ProviderName, path + ".provider_name");
        WireCheck.Nonempty(DeviceID, path + ".device_id");
        WireCheck.Nonempty(GPUName, path + ".gpu_name");
        WireCheck.Nonempty(DriverVersion, path + ".driver_version");
        WireCheck.Nonempty(AdapterID, path + ".adapter_id");
        WireCheck.Require(Architecture is "x64" or "arm64", path + ".architecture", "architecture must be x64 or arm64.");
        WireCheck.Nonempty(PackageIdentity, path + ".package_identity");
        WireCheck.Nonempty(LibraryPath, path + ".library_path");
        EngineAcceleratorValidation.Hash(LibraryHash, path + ".library_hash");
        var dependencies = Dependencies ?? throw new WireDecodeException(WireError.Constraint, path + ".dependencies", "dependencies must not be null.");
        WireCheck.Require(dependencies.Length <= 64, path + ".dependencies", "dependencies must contain at most 64 entries.");

        for (var index = 0; index < dependencies.Length; index++)
        {
            var dependency = dependencies[index] ?? throw new WireDecodeException(
                WireError.Constraint,
                path + ".dependencies[" + index + "]",
                "dependency must not be null.");
            dependency.Validate(path + ".dependencies[" + index + "]");
        }
    }
}

[WireObject]
public sealed record EngineAcceleratorsBindPayload(
    [property: WireMember("descriptor")] EngineAcceleratorDescriptor Descriptor);

[WireObject]
public sealed record EngineAcceleratorsBindResult(
    [property: WireMember("binding_id")] string BindingID) : IWireValidatable
{
    public void Validate(string path) => WireCheck.Nonempty(BindingID, path + ".binding_id");
}

[WireObject]
public sealed record EngineAcceleratorsVerifyPayload(
    [property: WireMember("binding_id")] string BindingID,
    [property: WireMember("asr_size")] EngineASRSize AsrSize,
    [property: WireMember("threads")] long Threads) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(BindingID, path + ".binding_id");
        WireCheck.Range(Threads, 1, 4, path + ".threads");
    }
}

public enum EngineAcceleratorsVerifyResultKind
{
    [WireValue("pass")] Pass,
    [WireValue("fail")] Fail,
}

[WireUnion("result", typeof(EngineAcceleratorsVerifyResultKind))]
public abstract record EngineAcceleratorsVerifyResult : IWireValidatable
{
    private EngineAcceleratorsVerifyResult() { }

    public abstract void Validate(string path);

    public EngineAcceleratorsVerifyResultKind Result => StrictWireCodec.CaseValue<EngineAcceleratorsVerifyResultKind>(this);

    [WireCase("pass")]
    public sealed record Pass(
        [property: WireMember("verification_id")] string VerificationID,
        [property: WireMember("rtf")] double RTF) : EngineAcceleratorsVerifyResult
    {
        public override void Validate(string path)
        {
            WireCheck.Nonempty(VerificationID, path + ".verification_id");
            WireCheck.Require(double.IsFinite(RTF) && RTF > 0, path + ".rtf", "rtf must be finite and positive.");
        }
    }

    [WireCase("fail")]
    public sealed record Fail(
        [property: WireMember("verification_id")] string VerificationID,
        [property: WireMember("reason")] string Reason,
        [property: WireMember("observed_output")] string ObservedOutput) : EngineAcceleratorsVerifyResult
    {
        public override void Validate(string path)
        {
            WireCheck.Nonempty(VerificationID, path + ".verification_id");
            WireCheck.Nonempty(Reason, path + ".reason");
            WireCheck.Require(ObservedOutput is not null, path + ".observed_output", "observed_output must not be null.");
        }
    }
}

public enum EngineProfileChoice
{
    [WireValue("small")] Small,
    [WireValue("large")] Large,
}

[WireObject]
public sealed record EngineProfilesDecidePayload(
    [property: WireMember("expected_revision")] EngineID ExpectedRevision,
    [property: WireMember("choice")] EngineProfileChoice Choice);
