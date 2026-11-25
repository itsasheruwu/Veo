using Veo.Protocol;

namespace Veo.Core;

public sealed record ComposerPermission(string Id, string Title, string Detail, string Sandbox, string Policy, bool AutomaticReview = false)
{
    internal static CapabilityDefinition ReviewerCapability { get; } = CodexCapabilities.All.First(item => item.Name == "approvalAutoReview");

    public static IReadOnlyList<ComposerPermission> Options { get; } =
    [
        new("Read only", "Supervised", "Ask before running commands or writing outside the read-only sandbox.",
            "read-only", "untrusted"),
        new("Workspace", "Auto-accept edits", "Allow project edits. Ask you before actions that need approval.",
            "workspace-write", "on-request"),
        new("Auto", "Auto", "Use Codex automatic review for actions that need approval.",
            "workspace-write", "on-request", AutomaticReview: true),
        new("Full access", "Full access", "Run commands and edit files without approval prompts.",
            "danger-full-access", "never")
    ];

    public string Reviewer => AutomaticReview ? "auto_review" : "user";
    public static bool IsKnown(string id) => Options.Any(mode => mode.Id == id);
    public static ComposerPermission Get(string id) => Options.FirstOrDefault(mode => mode.Id == id)
        ?? throw new InvalidDataException("Choose an explicit permission mode before sending.");
}
