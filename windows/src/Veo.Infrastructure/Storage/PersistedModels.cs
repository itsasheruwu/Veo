namespace Veo.Infrastructure.Storage;

public sealed record PersistedThread(
    string VeoId, string? CodexThreadId, string Cwd, string Title,
    string Preview = "", DateTimeOffset UpdatedAt = default, string Status = "idle",
    bool IsPinned = false, bool IsArchived = false, string? ParentThreadId = null,
    string MetaJson = "{}", string WorkspaceKind = "project");

public sealed record PersistedTurn(string TurnId, string? Status, DateTimeOffset? StartedAt,
    string? ErrorJson, long SortIndex, bool TerminalObserved = false, DateTimeOffset? CompletedAt = null, string? Diff = null, IReadOnlyDictionary<string, DateTimeOffset>? Steers = null);

public sealed record PersistedItem(string ItemId, string? TurnId, string? Type,
    string? ClientId, string? Status, string RawJson, long SortIndex, DateTimeOffset UpdatedAt);

public sealed record PersistedDraft(string Text, string AttachmentsJson = "[]",
    string OptionsJson = "{}", DateTimeOffset UpdatedAt = default);

public sealed record PersistedPlan(string ThreadKey, string ItemId, string? TurnId,
    string OriginalMarkdown, string? EditedMarkdown, string Lifecycle = "ready",
    string? ImplementationClientId = null, string? ImplementationTurnId = null,
    DateTimeOffset UpdatedAt = default);
