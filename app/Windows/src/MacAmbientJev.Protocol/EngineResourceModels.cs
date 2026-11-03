namespace MacAmbientJev.Protocol;

public enum EngineResourceWorkload
{
    [WireValue("load")] Load,
    [WireValue("live")] Live,
    [WireValue("finalization")] Finalization,
}

public enum EngineResourceReadiness
{
    [WireValue("ready")] Ready,
    [WireValue("warning")] Warning,
    [WireValue("blocked")] Blocked,
}

public enum EngineResourceReason
{
    [WireValue("ready")] Ready,
    [WireValue("unsupported_cpu_count")] UnsupportedCPUCount,
    [WireValue("invalid_threads")] InvalidThreads,
    [WireValue("low_memory")] LowMemory,
    [WireValue("insufficient_physical_memory")] InsufficientPhysicalMemory,
    [WireValue("insufficient_commit_headroom")] InsufficientCommitHeadroom,
    [WireValue("envelope_unmeasured")] EnvelopeUnmeasured,
    [WireValue("envelope_stale")] EnvelopeStale,
    [WireValue("rtf_unmeasured")] RTFUnmeasured,
    [WireValue("rtf_stale")] RTFStale,
    [WireValue("live_too_slow")] LiveTooSlow,
}

[WireObject]
public sealed record EngineResourcesPreflightPayload(
    [property: WireMember("workload")] EngineResourceWorkload Workload);

[WireObject]
public sealed record EngineResourcesAcknowledgePayload(
    [property: WireMember("assessment_id")] string AssessmentID) : IWireValidatable
{
    public void Validate(string path) => WireCheck.Nonempty(AssessmentID, path + ".assessment_id");
}

[WireObject]
public sealed record EngineResourceAssessment(
    [property: WireMember("assessment_id")] string AssessmentID,
    [property: WireMember("result")] EngineResourceReadiness Result,
    [property: WireMember("reason")] EngineResourceReason Reason,
    [property: WireMember("explanation")] string Explanation) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Nonempty(AssessmentID, path + ".assessment_id");
        WireCheck.Nonempty(Explanation, path + ".explanation");
    }
}
