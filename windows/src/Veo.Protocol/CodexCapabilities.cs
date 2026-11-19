namespace Veo.Protocol;

public sealed record CapabilityDefinition(string Name, bool Experimental, bool RequiresAllMethods, IReadOnlyList<string> Methods);

/// <summary>Behavior groups ported from the pinned Mac CodexAppServerCapability registry.</summary>
public static class CodexCapabilities
{
    public static IReadOnlyList<CapabilityDefinition> All { get; } =
    [
        new("turnSteering", false, false, ["turn/steer"]),
        new("queuedUserMessageIDs", false, false, ["turn/start", "turn/steer"]),
        new("threadSearch", true, false, ["thread/search"]),
        new("threadContentSearch", true, false, ["thread/searchOccurrences"]),
        new("threadManagement", false, false, ["thread/metadata/update", "thread/name/set", "thread/archive", "thread/unarchive", "thread/delete", "thread/fork"]),
        new("manualCompaction", false, false, ["thread/compact/start"]),
        new("review", false, false, ["review/start"]),
        new("liveDiffs", false, false, ["turn/diff/updated", "item/fileChange/patchUpdated"]),
        new("account", false, false, ["account/read", "account/rateLimits/read", "account/usage/read"]),
        new("accountLogin", false, true, ["account/login/start", "account/login/cancel"]),
        new("accountLogout", false, false, ["account/logout"]),
        new("skills", false, false, ["skills/list"]),
        new("skillsManagement", false, false, ["skills/config/write", "skills/extraRoots/set"]),
        new("plugins", false, false, ["plugin/list", "plugin/read"]),
        new("pluginManagement", false, false, ["plugin/install", "plugin/uninstall", "plugin/installed"]),
        new("apps", true, false, ["app/list", "app/read"]),
        new("appsLinking", true, true, ["app/list", "app/read", "app/installed"]),
        new("mcpStatus", false, false, ["mcpServerStatus/list"]),
        new("mcpOAuth", false, false, ["mcpServer/oauth/login"]),
        new("mcpReload", false, false, ["config/mcpServer/reload"]),
        new("commandExec", false, true, ["command/exec", "command/exec/write", "command/exec/resize", "command/exec/terminate"]),
        new("realtimeVoice", true, true, ["thread/realtime/start", "thread/realtime/appendAudio", "thread/realtime/appendText", "thread/realtime/appendSpeech", "thread/realtime/stop", "thread/realtime/listVoices"]),
        new("collaborationModes", true, true, ["collaborationMode/list", "thread/settings/update"]),
        new("permissionProfiles", true, false, ["permissionProfile/list"]),
        new("configManagement", false, false, ["config/read", "config/value/write", "config/batchWrite", "configRequirements/read"]),
        new("experimentalFeatures", true, false, ["experimentalFeature/list", "experimentalFeature/enablement/set"]),
        new("hooks", false, false, ["hooks/list"]),
        new("threadSubscriptions", false, true, ["thread/loaded/list", "thread/unsubscribe"]),
        new("integrationDetails", false, false, ["plugin/read", "plugin/skill/read", "app/read", "app/installed", "mcpServer/resource/read", "mcpServer/tool/call"]),
        new("accountExtras", false, false, ["account/workspaceMessages/read", "account/rateLimitResetCredit/consume", "account/sendAddCreditsNudgeEmail"]),
        new("liveTurnSettings", true, false, ["turn/settings/update"]),
        new("backgroundTerminals", true, true, ["thread/backgroundTerminals/list", "thread/backgroundTerminals/terminate", "thread/backgroundTerminals/clean"]),
        new("approvalAutoReview", false, false, ["item/autoApprovalReview/started", "item/autoApprovalReview/completed", "autoApprovalReview/strictReviewRequired", "thread/approveGuardianDeniedAction"]),
        new("serverQueue", true, true, ["thread/queue/add", "thread/queue/list", "thread/queue/update", "thread/queue/delete", "thread/queue/reorder", "thread/queue/start"]),
        new("realtimeTimeline", true, true, ["thread/timeline/list", "thread/realtime/item/started", "thread/realtime/item/transcript/delta", "thread/realtime/item/completed"]),
        new("historyRevert", false, false, ["thread/revert"]),
        new("richModelInfo", false, false, ["model/list", "modelProvider/capabilities/read"]),
        new("marketplaceManagement", false, true, ["marketplace/add", "marketplace/remove", "marketplace/upgrade"]),
        new("pluginSearch", true, false, ["plugin/search"]),
        new("externalAgentImport", false, false, ["externalAgentConfig/detect", "externalAgentConfig/import"]),
        new("threadMemoryMode", true, false, ["thread/memoryMode/set"]),
        new("itemHistory", false, false, ["thread/items/list"]),
        new("dynamicTools", false, false, ["item/tool/call"]),
    ];
}
