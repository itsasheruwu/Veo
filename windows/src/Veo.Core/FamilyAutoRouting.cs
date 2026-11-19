using System.Text.Json;
using System.Text.RegularExpressions;

namespace Veo.Core;

public static class FamilyAutoRouting
{
    public static FamilyAutoPlan Resolve(IReadOnlyList<NativeModelDescriptor> catalog, string family, bool multiAgentEnabled)
    {
        if (family is not ("5.6" or "6")) throw new ArgumentException("Unknown Auto family.", nameof(family));
        var models = catalog.Where(x => x.Family(family)).ToArray();
        FamilyAutoLane? Lane(string variant, string effort)
        {
            var model = models.FirstOrDefault(x => x.Variant(variant));
            var option = model?.Efforts.FirstOrDefault(x => x.Id.Equals(effort, StringComparison.OrdinalIgnoreCase));
            return model is not null && option is not null ? new(model.Id, model.Model, model.Name, option.Id) : null;
        }
        var parent = Lane(family == "5.6" ? "sol" : "astra", "high")
            ?? throw new InvalidOperationException($"{family} Auto requires its lead model with High reasoning in the live catalog.");
        if (!multiAgentEnabled) return new(family, parent, parent, parent, parent, "single", [$"Native multi-agent support is unavailable. {parent.Name} will work and verify alone; independent review is unavailable."]);
        var routine = Lane("luna", "max"); var escalation = Lane(family == "5.6" ? "terra" : "sol", "high"); var warnings = new List<string>();
        if (routine is null) warnings.Add($"Luna / Maximum is unavailable. A fresh {parent.Name} / High worker will handle routine implementation.");
        if (escalation is null) warnings.Add($"The escalation model / High is unavailable. A fresh {parent.Name} / High worker will handle escalation.");
        return new(family, parent, routine ?? parent, escalation ?? parent, parent, warnings.Count == 0 ? "full" : "modelFallback", warnings.ToArray());
    }
    public static string Instructions(FamilyAutoPlan plan, string interactionMode)
    {
        var notice = plan.Warnings.Length == 0 ? "The full Auto route is available." : string.Join(" ", plan.Warnings);
        var opening = $"You are the GPT-{plan.Family} Auto parent running as {plan.Parent.Model} with {plan.Parent.Effort} reasoning.";
        if (interactionMode == "Plan") return opening + "\nThis is Plan mode. Investigate as needed and produce a plan only. Do not edit files, delegate implementation, spawn a reviewer, or claim that implementation or independent review occurred.\n" + notice;
        var debug = interactionMode == "Debug" ? "\nThis is Debug mode. Diagnose from concrete evidence, reproduce where safe, and make the smallest verified correction." : "";
        if (!plan.UsesMultiAgent) return opening + "\nAnswer-only, explanation and advisory requests stay with you. For requested code changes, inspect, implement and rerun relevant checks yourself while preserving the user's permissions and existing dirty work. Native multi-agent support is unavailable: do not attempt delegation or claim independent review. State briefly that you completed and verified the work alone and independent review was unavailable." + debug;
        return opening + $"""

        Veo owns this route. Do not modify global Codex configuration or install agents, skills or plugins.
        Answer-only, explanation and advisory requests stay with you. For code-changing Agentic or Debug tasks, own intent, architecture, decomposition, permissions and final verification. Delegate routine implementation to a fresh worker using {plan.Routine.Model} at {plan.Routine.Effort} effort. Use a fresh escalation worker using {plan.Escalation.Model} at {plan.Escalation.Effort} effort when complexity, risk, ambiguity or a failed routine attempt justifies escalation.
        Every worker task must include five labeled parts:
        1. OBJECTIVE — concrete outcome and acceptance criteria.
        2. FILES AND OWNERSHIP — exact files or narrow directories owned by the worker; no editing outside them.
        3. INTERFACES — contracts, callers, dependencies and integration boundaries to preserve.
        4. CONSTRAINTS — repository instructions, permissions, dirty-work preservation, non-goals and prohibited destructive or scope-broadening actions.
        5. VERIFICATION — proportionate checks and structured evidence to return.
        Require changed files, check results, unresolved risks and ownership compliance. Inspect each returned diff and rerun relevant checks yourself. Then spawn a fresh {plan.Reviewer.Model} reviewer at {plan.Reviewer.Effort} effort with no implementation ownership. Give it the objective, constraints, diff and verification evidence. Require exactly one structured verdict: VERDICT: ship, VERDICT: fix-first, or VERDICT: rethink, followed by findings. Never use the implementer as reviewer. Every fix invalidates the verdict: inspect and verify the fix, then obtain a fresh review before completion. Do not claim a phase the event history does not prove.
        {notice}{debug}
        """;
    }
}

public sealed record AutoWorkflowStep(string Name, string Status, string Evidence, string[] ReceiverThreads);
public sealed record AutoWorkflowState(string Stage, AutoWorkflowStep[] Steps, string? Verdict, string[] Warnings);
public sealed record FamilyRouteRun(string ClientId, string? TurnId, FamilyAutoPlan Plan, AutoWorkflowState State, DateTimeOffset UpdatedAt);

public static class AutoWorkflowReducer
{
    public static AutoWorkflowState Derive(IReadOnlyList<TimelineItem> timeline, string clientId, string? turnId, FamilyAutoPlan plan, bool running)
    {
        var start = timeline.ToList().FindLastIndex(x => x.Raw.Str("clientId") == clientId || x.Id == clientId);
        var items = timeline.Skip(Math.Max(0, start)).Where(x => turnId is null || x.TurnId is null || x.TurnId == turnId).ToArray();
        var workers = items.Select((item, index) => (item, index)).Where(x => x.item.Kind == "collabAgentToolCall" && x.item.Raw.Str("tool") is "spawnAgent" or "spawn_agent").ToArray();
        bool Review(TimelineItem item)
        {
            var prompt = item.Raw.Str("prompt") ?? "";
            return prompt.Contains("VERDICT:", StringComparison.OrdinalIgnoreCase) && Regex.IsMatch(prompt.TrimStart(), @"^(?:you are (?:an? |the )?(?:fresh |independent |code )*reviewer\b|(?:your role is|role\s*[:—–-])\s*(?:an? |the )?(?:fresh |independent |code )*reviewer\b|(?:objective|task)\s*[:—–-]\s*(?:independently\s+)?review\b|(?:independently\s+)?review\b)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        }
        var implementation = workers.LastOrDefault(x => !Review(x.item));
        var review = workers.LastOrDefault(x => Review(x.item));
        var workerSeen = implementation.item is not null; var reviewSeen = review.item is not null && (!workerSeen || review.index > implementation.index);
        bool Active(TimelineItem item) => item.Raw.TryObjectProperty("agentsStates", out var states) && states.EnumerateObject().Any(x => x.Value.Str("status") is "running" or "pendingInit" or "inProgress");
        bool Finished(TimelineItem item) => item.Raw.TryObjectProperty("agentsStates", out var states) && states.EnumerateObject().Any() && states.EnumerateObject().All(x => x.Value.Str("status") is "completed" or "interrupted" or "errored" or "shutdown" or "notFound");
        string[] Receivers(TimelineItem? item) => item is not null && item.Raw.TryGetProperty("receiverThreadIds", out var receivers) && receivers.ValueKind == JsonValueKind.Array ? receivers.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString()!).ToArray() : [];
        var verification = workerSeen && items.Skip(implementation.index + 1).Any(x => x.Kind is "commandExecution" or "fileChange");
        var reportedVerification = workerSeen && items.Skip(implementation.index + 1).Any(x => x.Kind == "agentMessage" && x.Text.Contains("passed", StringComparison.OrdinalIgnoreCase) && (x.Text.Contains("final diff", StringComparison.OrdinalIgnoreCase) || x.Text.Contains("inspected the diff", StringComparison.OrdinalIgnoreCase)));
        string? verdict = null;
        if (reviewSeen)
        {
            var evidence = new List<string>();
            if (review.item!.Raw.TryObjectProperty("agentsStates", out var states)) evidence.AddRange(states.EnumerateObject().Select(x => x.Value.Str("message") ?? ""));
            evidence.AddRange(items.Skip(review.index + 1).Where(x => x.Kind == "agentMessage").Select(x => x.Text));
            foreach (var text in evidence) { var match = Regex.Match(text, @"\bVERDICT:\s*(ship|fix-first|rethink)\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant); if (match.Success) verdict = match.Groups[1].Value.ToLowerInvariant(); }
        }
        var implementationStatus = !plan.UsesMultiAgent ? "unavailable" : !workerSeen ? "pending" : Active(implementation.item!) ? "active" : Finished(implementation.item!) ? "complete" : "pending";
        var reviewStatus = !plan.UsesMultiAgent ? "unavailable" : !reviewSeen ? "pending" : Active(review.item!) ? "active" : Finished(review.item!) ? "complete" : "pending";
        var stage = start < 0 ? "Ready" : reviewStatus == "active" ? "Reviewing" : implementationStatus == "active" ? "Implementing" : verification && running ? "Verifying" : running ? "Parent working" : verdict is not null ? "Review: " + verdict : "Turn complete";
        return new(stage, [new("Architect", start >= 0 ? workerSeen || reviewSeen || !running ? "complete" : "active" : "pending", "Parent owns intent and permissions", []),
            new("Implementation", implementationStatus, workerSeen ? "Worker invocation observed" : "No worker invocation observed", Receivers(implementation.item)),
            new("Verification", verification || reportedVerification ? "complete" : "pending", verification ? "Parent command/file activity observed" : reportedVerification ? "Verification reported by parent" : "No verification evidence observed", []),
            new("Review", reviewStatus, reviewSeen ? "Fresh reviewer invocation observed" : "No current independent reviewer observed", Receivers(reviewSeen ? review.item : null))], verdict, plan.Warnings);
    }
}
