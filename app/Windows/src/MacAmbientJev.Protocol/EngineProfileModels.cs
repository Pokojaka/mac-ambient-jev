namespace MacAmbientJev.Protocol;

public enum EngineProfileProvider
{
    [WireValue("cpu")] Cpu,
    [WireValue("nv_tensor_rt_rtx")] NvTensorRtRtx,
    [WireValue("open_vino")] OpenVINO,
    [WireValue("mi_graph_x")] MiGraphX,
    [WireValue("vitis_ai")] VitisAI,
    [WireValue("qnn")] Qnn,
}

public enum EngineProfileSelectionReason
{
    [WireValue("no_gpu")] NoGPU,
    [WireValue("hardware_query_failed")] HardwareQueryFailed,
    [WireValue("provider_unavailable")] ProviderUnavailable,
    [WireValue("provider_acquisition_failed")] ProviderAcquisitionFailed,
    [WireValue("unknown_dedicated_vram")] UnknownDedicatedVRAM,
    [WireValue("insufficient_dedicated_vram")] InsufficientDedicatedVRAM,
    [WireValue("insufficient_memory")] InsufficientMemory,
    [WireValue("awaiting_assets")] AwaitingAssets,
    [WireValue("eligible")] Eligible,
    [WireValue("verification_required")] VerificationRequired,
    [WireValue("verification_failed")] VerificationFailed,
    [WireValue("uncalibrated")] Uncalibrated,
    [WireValue("unmeasured")] Unmeasured,
    [WireValue("recommend_large")] RecommendLarge,
    [WireValue("too_slow")] TooSlow,
}

public enum EngineProfileDecisionState
{
    [WireValue("awaiting_assets")] AwaitingAssets,
    [WireValue("offered")] Offered,
    [WireValue("complete")] Complete,
}

public enum EngineProfileHardwareKind
{
    [WireValue("no_gpu")] NoGPU,
    [WireValue("query_failed")] QueryFailed,
    [WireValue("gpu")] Gpu,
}

public enum EngineProfileAcquisitionKind
{
    [WireValue("unavailable")] Unavailable,
    [WireValue("failed")] Failed,
    [WireValue("acquired")] Acquired,
}

[WireUnion("kind", typeof(EngineProfileHardwareKind))]
public abstract record EngineProfileHardware : IWireValidatable
{
    private EngineProfileHardware() { }

    public abstract void Validate(string path);

    public EngineProfileHardwareKind Kind => StrictWireCodec.CaseValue<EngineProfileHardwareKind>(this);

    [WireCase("no_gpu")]
    public sealed record NoGPU() : EngineProfileHardware
    {
        public override void Validate(string path) { }
    }

    [WireCase("query_failed")]
    public sealed record QueryFailed(
        [property: WireMember("message")] string Message) : EngineProfileHardware, IWireValidatable
    {
        public override void Validate(string path) => WireCheck.Nonempty(Message, path + ".message");
    }

    [WireCase("gpu")]
    public sealed record Gpu(
        [property: WireMember("name")] string Name,
        [property: WireMember("adapter_id")] string AdapterID,
        [property: WireMember("device_id")] string DeviceID,
        [property: WireMember("driver_version")] string DriverVersion,
        [property: WireMember("dedicated_vram_bytes", IsNullable = true)] ulong? DedicatedVRAMBytes) : EngineProfileHardware, IWireValidatable
    {
        public override void Validate(string path)
        {
            WireCheck.Nonempty(Name, path + ".name");
            WireCheck.Nonempty(AdapterID, path + ".adapter_id");
            WireCheck.Nonempty(DeviceID, path + ".device_id");
            WireCheck.Nonempty(DriverVersion, path + ".driver_version");
        }
    }
}

[WireUnion("kind", typeof(EngineProfileAcquisitionKind))]
public abstract record EngineProfileAcquisition : IWireValidatable
{
    private EngineProfileAcquisition() { }

    public abstract void Validate(string path);

    public EngineProfileAcquisitionKind Kind => StrictWireCodec.CaseValue<EngineProfileAcquisitionKind>(this);

    [WireCase("unavailable")]
    public sealed record Unavailable() : EngineProfileAcquisition
    {
        public override void Validate(string path) { }
    }

    [WireCase("failed")]
    public sealed record Failed(
        [property: WireMember("message")] string Message) : EngineProfileAcquisition, IWireValidatable
    {
        public override void Validate(string path) => WireCheck.Nonempty(Message, path + ".message");
    }

    [WireCase("acquired")]
    public sealed record Acquired(
        [property: WireMember("provider")] EngineProfileProvider Provider) : EngineProfileAcquisition
    {
        public override void Validate(string path) { }
    }
}

[WireObject]
public sealed record EngineProfilesEvaluatePayload(
    [property: WireMember("hardware")] EngineProfileHardware Hardware,
    [property: WireMember("acquisition")] EngineProfileAcquisition Acquisition,
    [property: WireMember("threads")] long Threads) : IWireValidatable
{
    public void Validate(string path) => WireCheck.Range(Threads, 1, 4, path + ".threads");
}

[WireObject]
public sealed record EngineProfileEvaluation(
    [property: WireMember("initial_size")] EngineASRSize InitialSize,
    [property: WireMember("recommend_large")] bool RecommendLarge,
    [property: WireMember("reason")] EngineProfileSelectionReason Reason,
    [property: WireMember("explanation")] string Explanation,
    [property: WireMember("measured_rtf", IsNullable = true)] double? MeasuredRTF,
    [property: WireMember("predicted_rtf", IsNullable = true)] double? PredictedRTF,
    [property: WireMember("decision_state")] EngineProfileDecisionState DecisionState,
    [property: WireMember("calibration_id", IsNullable = true)] string? CalibrationID) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Require(InitialSize == EngineASRSize.Small, path + ".initial_size", "initial_size must be small.");
        WireCheck.Require(RecommendLarge == (Reason == EngineProfileSelectionReason.RecommendLarge), path + ".recommend_large", "recommend_large must match reason.");
        WireCheck.Nonempty(Explanation, path + ".explanation");
        if (MeasuredRTF.HasValue)
        {
            WireCheck.Require(double.IsFinite(MeasuredRTF.Value) && MeasuredRTF.Value > 0, path + ".measured_rtf", "measured_rtf must be finite and positive.");
        }

        if (PredictedRTF.HasValue)
        {
            WireCheck.Require(double.IsFinite(PredictedRTF.Value) && PredictedRTF.Value > 0, path + ".predicted_rtf", "predicted_rtf must be finite and positive.");
        }

        if (CalibrationID is not null)
        {
            WireCheck.Nonempty(CalibrationID, path + ".calibration_id");
        }
    }
}

[WireObject]
public sealed record EngineProfileSetup(
    [property: WireMember("evaluation", IsNullable = true)] EngineProfileEvaluation? Evaluation);

public enum EngineResourceHoldReason
{
    [WireValue("thermal")] Thermal,
    [WireValue("resource_pressure")] ResourcePressure,
    [WireValue("monitor_failed")] MonitorFailed,
}

[WireObject]
public sealed record EngineResourceProtection(
    [property: WireMember("hold_reasons")] EngineResourceHoldReason[] HoldReasons) : IWireValidatable
{
    public void Validate(string path)
    {
        if (HoldReasons is not null)
        {
            WireCheck.Unique(HoldReasons, path + ".hold_reasons");
        }
    }
}
