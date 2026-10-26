namespace MacAmbientJev.Protocol;

[WireObject]
public sealed record EngineDecisionRequestUsage(
    [property: WireMember("send_count")] long SendCount,
    [property: WireMember("input_tokens")] long InputTokens,
    [property: WireMember("success_count")] long SuccessCount,
    [property: WireMember("failure_count")] long FailureCount) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Require(SendCount >= 0, path + ".send_count", "send_count must not be negative.");
        WireCheck.Require(InputTokens >= 0, path + ".input_tokens", "input_tokens must not be negative.");
        WireCheck.Require(SuccessCount >= 0, path + ".success_count", "success_count must not be negative.");
        WireCheck.Require(FailureCount >= 0, path + ".failure_count", "failure_count must not be negative.");
        WireCheck.Require(
            SuccessCount <= SendCount && FailureCount <= SendCount - SuccessCount,
            path + ".send_count",
            "success_count + failure_count must not exceed send_count.");
    }
}

[WireObject]
public sealed record EngineDecisionUsageSnapshot(
    [property: WireMember("send_count")] long SendCount,
    [property: WireMember("input_tokens")] long InputTokens,
    [property: WireMember("success_count")] long SuccessCount,
    [property: WireMember("failure_count")] long FailureCount,
    [property: WireMember("pending_boundary_segment_count")] long PendingBoundarySegmentCount,
    [property: WireMember("pending_priority_clause_count")] long PendingPriorityClauseCount,
    [property: WireMember("boundary_requests")] EngineDecisionRequestUsage BoundaryRequests,
    [property: WireMember("priority_requests")] EngineDecisionRequestUsage PriorityRequests) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.Require(SendCount >= 0, path + ".send_count", "send_count must not be negative.");
        WireCheck.Require(InputTokens >= 0, path + ".input_tokens", "input_tokens must not be negative.");
        WireCheck.Require(SuccessCount >= 0, path + ".success_count", "success_count must not be negative.");
        WireCheck.Require(FailureCount >= 0, path + ".failure_count", "failure_count must not be negative.");
        WireCheck.Require(PendingBoundarySegmentCount >= 0, path + ".pending_boundary_segment_count", "pending_boundary_segment_count must not be negative.");
        WireCheck.Require(PendingPriorityClauseCount >= 0, path + ".pending_priority_clause_count", "pending_priority_clause_count must not be negative.");

        if (BoundaryRequests is not null)
        {
            BoundaryRequests.Validate(path + ".boundary_requests");
        }

        if (PriorityRequests is not null)
        {
            PriorityRequests.Validate(path + ".priority_requests");
        }

        if (BoundaryRequests is null || PriorityRequests is null)
        {
            return;
        }

        RequireMatchingSum(SendCount, BoundaryRequests.SendCount, PriorityRequests.SendCount, path + ".send_count");
        RequireMatchingSum(InputTokens, BoundaryRequests.InputTokens, PriorityRequests.InputTokens, path + ".input_tokens");
        RequireMatchingSum(SuccessCount, BoundaryRequests.SuccessCount, PriorityRequests.SuccessCount, path + ".success_count");
        RequireMatchingSum(FailureCount, BoundaryRequests.FailureCount, PriorityRequests.FailureCount, path + ".failure_count");
    }

    private static void RequireMatchingSum(long total, long boundary, long priority, string path)
    {
        WireCheck.Require(
            boundary >= 0 && priority >= 0 && boundary <= long.MaxValue - priority && total == boundary + priority,
            path,
            "total must equal the overflow-safe sum of boundary_requests and priority_requests.");
    }
}

[WireUnion("kind", typeof(EngineDecisionUsageKind))]
public abstract record EngineDecisionUsage
{
    private EngineDecisionUsage() { }

    public EngineDecisionUsageKind Kind => this switch
    {
        Available _ => EngineDecisionUsageKind.Available,
        Unavailable _ => EngineDecisionUsageKind.Unavailable,
        _ => throw new System.InvalidOperationException("Unrecognized engine decision usage case."),
    };

    [WireCase("available")]
    public sealed record Available(
        [property: WireMember("snapshot")] EngineDecisionUsageSnapshot Snapshot) : EngineDecisionUsage;

    [WireCase("unavailable")]
    public sealed record Unavailable(
        [property: WireMember("error")] EngineFailure Error) : EngineDecisionUsage;
}

[WireObject]
public sealed record EngineDiagnosticsResult(
    [property: WireMember("scope")] EngineDiagnosticsScope Scope,
    [property: WireMember("decision_usage")] EngineDecisionUsage DecisionUsage,
    [property: WireMember("automatic_input_volume")] EngineUnavailableCapability AutomaticInputVolume,
    [property: WireMember("thermal_monitoring")] EngineUnavailableCapability ThermalMonitoring);

[WireObject]
public sealed record EngineClauseTaggerIdentity(
    [property: WireMember("backend")] string Backend,
    [property: WireMember("model_id")] string ModelID,
    [property: WireMember("revision")] string Revision,
    [property: WireMember("tokenizer_sha256")] string TokenizerSHA256) : IWireValidatable
{
    public void Validate(string path)
    {
        WireCheck.NonWhitespace(Backend, path + ".backend");
        WireCheck.NonWhitespace(ModelID, path + ".model_id");
        RequireSHA256(Revision, path + ".revision");
        RequireSHA256(TokenizerSHA256, path + ".tokenizer_sha256");
    }

    private static void RequireSHA256(string? value, string path)
    {
        if (value is null)
        {
            throw new WireDecodeException(
                WireError.Constraint,
                path,
                "Value must be exactly 64 lowercase ASCII hexadecimal characters.");
        }

        var isValid = value.Length == 64;
        if (isValid)
        {
            foreach (var character in value)
            {
                if (!(character is >= '0' and <= '9' or >= 'a' and <= 'f'))
                {
                    isValid = false;
                    break;
                }
            }
        }

        WireCheck.Require(isValid, path, "Value must be exactly 64 lowercase ASCII hexadecimal characters.");
    }
}

[WireUnion("kind", typeof(EngineClauseTaggerInspectionKind))]
public abstract record EngineClauseTaggerInspection
{
    private EngineClauseTaggerInspection() { }

    public EngineClauseTaggerInspectionKind Kind => this switch
    {
        Validated _ => EngineClauseTaggerInspectionKind.Validated,
        Invalid _ => EngineClauseTaggerInspectionKind.Invalid,
        _ => throw new System.InvalidOperationException("Unrecognized engine clause tagger inspection case."),
    };

    [WireCase("validated")]
    public sealed record Validated(
        [property: WireMember("identity")] EngineClauseTaggerIdentity Identity) : EngineClauseTaggerInspection;

    [WireCase("invalid")]
    public sealed record Invalid(
        [property: WireMember("error")] EngineFailure Error) : EngineClauseTaggerInspection;
}

[WireObject]
public sealed record EngineModelsInspection(
    [property: WireMember("clause_tagger")] EngineClauseTaggerInspection ClauseTagger);
