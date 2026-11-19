using System.Text.Json;
using Veo.Infrastructure.Storage;

namespace Veo.Core;

[Flags] public enum ShortcutModifiers { None = 0, Control = 1, Shift = 2, Alt = 4 }
public sealed record CommandKeyBinding(int VirtualKey, ShortcutModifiers Modifiers)
{
    public string Display => string.Join("+", new[] { Modifiers.HasFlag(ShortcutModifiers.Control) ? "Ctrl" : null, Modifiers.HasFlag(ShortcutModifiers.Shift) ? "Shift" : null, Modifiers.HasFlag(ShortcutModifiers.Alt) ? "Alt" : null, KeyName(VirtualKey) }.OfType<string>());
    static string KeyName(int key) => key switch { >= 65 and <= 90 or >= 48 and <= 57 => ((char)key).ToString(), 188 => ",", 190 => ".", 192 => "`", 186 => ";", 187 => "=", 189 => "-", 191 => "/", 219 => "[", 220 => "\\", 221 => "]", 222 => "'", _ => "Key " + key };
}
public sealed record CommandDefinition(string Id, string Title, string Description, string? SlashName = null,
    bool AcceptsArguments = false, CommandKeyBinding? DefaultBinding = null);
public sealed record CommandInvocation(CommandDefinition Command, string Arguments, bool FromShortcut);

/// <summary>One catalog supplies slash suggestions, menus, and persisted native accelerator bindings.</summary>
public sealed class CommandRegistry(ThreadRepository repository)
{
    readonly SemaphoreSlim gate = new(1, 1); Dictionary<string, CommandKeyBinding?> overrides = new(StringComparer.Ordinal);
    public event Action? Changed;
    public static IReadOnlyList<CommandDefinition> Definitions { get; } = Array.AsReadOnly(new CommandDefinition[]
    {
        new("model", "Model", "Choose a live runtime model", "model"), new("reasoning", "Reasoning", "Choose reasoning effort", "reasoning"),
        new("permissions", "Permissions", "Choose explicit workspace access", "permissions"), new("review", "Review changes", "Open the native review workflow", "review", true),
        new("rename", "Rename chat", "Rename the selected chat", "rename", true), new("newChat", "New chat", "Start a new chat", "new", true, Key('N')),
        new("temporary", "Temporary chat", "Make an unused projectless chat temporary", "temporary"), new("archive", "Archive chat", "Archive the selected chat", "archive"),
        new("delete", "Delete chat", "Delete the selected chat after confirmation", "delete"), new("fork", "Fork chat", "Choose a history turn boundary", "fork"),
        new("init", "Create AGENTS.md", "Ask Codex to inspect and preserve project guidance", "init"), new("compact", "Compact history", "Summarize history to free context", "compact"),
        new("agentic", "Agentic mode", "Switch to Agentic mode", "agentic"), new("plan", "Plan mode", "Switch to Plan mode", "plan", true),
        new("btw", "Side chat", "Ask a side question", "btw", true),
        new("debug", "Debug mode", "Switch to evidence-first Debug mode", "debug", true), new("goal", "Long-running goal", "Set or inspect a goal", "goal", true),
        new("copy", "Copy response", "Copy the last assistant response as Markdown", "copy"), new("diff", "Changes", "Open native changed files", "diff"),
        new("mention", "Mention a file", "Choose a project file mention", "mention"), new("status", "Runtime status", "Open local runtime settings", "status"),
        new("usage", "Usage and limits", "Open account usage and limits", "usage"), new("skills", "Skills", "Open skills and integrations", "skills"),
        new("mcp", "MCP servers", "Open MCP integrations", "mcp"), new("apps", "Connected apps", "Open connected apps", "apps"),
        new("plugins", "Plugins", "Open the plugin manager", "plugins"), new("appearance", "Appearance", "Open appearance settings", "appearance"),
        new("browser", "Browser settings", "Open browser settings", "browser"), new("terminal", "Toggle terminal", "Open the native docked terminal", "terminal", false, Key(192)),
        new("runtime", "Runtime settings", "Open local runtime settings", "runtime"), new("reconnect", "Reconnect", "Reconnect the local Codex runtime", "reconnect"),
        new("reveal", "Reveal project", "Reveal the selected workspace in Explorer", "reveal"), new("refresh", "Refresh chats", "Refresh all-project chat catalogs", "refresh", false, Key('R', true)),
        new("stop", "Stop turn", "Stop the active turn", "stop", false, Key(190)), new("clear", "Clear and start chat", "Start a fresh chat", "clear"),
        new("openProject", "Open project", "Open a local project folder", DefaultBinding: Key('O')),
        new("settings", "Settings", "Open Veo settings", DefaultBinding: Key(188)), new("stash", "Save prompt", "Save the draft in the prompt library", DefaultBinding: Key('S', true)),
        new("worktrees", "Project worktrees", "Open project worktrees", DefaultBinding: new('W', ShortcutModifiers.Control | ShortcutModifiers.Shift | ShortcutModifiers.Alt))
    });
    static CommandKeyBinding Key(int key, bool shift = false) => new(key, ShortcutModifiers.Control | (shift ? ShortcutModifiers.Shift : 0));
    public async Task InitializeAsync(CancellationToken token = default)
    {
        var json = await repository.ReadStateAsync("keyboard", "bindings", token);
        if (json is not null)
        {
            var saved = JsonSerializer.Deserialize<Dictionary<string, CommandKeyBinding?>>(json) ?? new();
            var known = Definitions.Select(x => x.Id).ToHashSet(StringComparer.Ordinal);
            if (saved.Keys.Any(id => !known.Contains(id))) throw new InvalidDataException("Saved keyboard settings contain an unknown command; the original settings were preserved.");
            Dictionary<string, CommandKeyBinding?> previous; lock (gate) { previous = overrides; overrides = new(saved, StringComparer.Ordinal); }
            try { foreach (var pair in saved) Validate(pair.Key, pair.Value); }
            catch { lock (gate) overrides = previous; throw; }
        }
    }
    public CommandKeyBinding? Binding(string id)
    {
        var definition = Definition(id); lock (gate) return overrides.TryGetValue(id, out var value) ? value : definition.DefaultBinding;
    }
    public CommandDefinition? Resolve(CommandKeyBinding binding) => Definitions.FirstOrDefault(x => Binding(x.Id) == binding);
    public async Task SetBindingAsync(string id, CommandKeyBinding? binding, CancellationToken token = default)
    {
        await gate.WaitAsync(token); try
        {
            Validate(id, binding); Dictionary<string, CommandKeyBinding?> next; lock (gate) next = new(overrides, StringComparer.Ordinal); next[id] = binding;
            await repository.SaveStateAsync("keyboard", "bindings", JsonSerializer.Serialize(next), token); lock (gate) overrides = next;
        }
        finally { gate.Release(); } Changed?.Invoke();
    }
    public async Task ResetAsync(string? id = null, CancellationToken token = default)
    {
        await gate.WaitAsync(token); try
        {
            Dictionary<string, CommandKeyBinding?> next; lock (gate) next = new(overrides, StringComparer.Ordinal);
            if (id is null) next.Clear(); else { Definition(id); next.Remove(id); }
            if (id is not null && Definition(id).DefaultBinding is { } restored && Definitions.Any(x => x.Id != id && (next.TryGetValue(x.Id, out var value) ? value : x.DefaultBinding) == restored)) throw new InvalidOperationException("The default shortcut is assigned elsewhere. Clear that binding first.");
            await repository.SaveStateAsync("keyboard", "bindings", JsonSerializer.Serialize(next), token); lock (gate) overrides = next;
        }
        finally { gate.Release(); } Changed?.Invoke();
    }
    void Validate(string id, CommandKeyBinding? binding)
    {
        var definition = Definition(id); if (binding is null) return;
        var key = binding.VirtualKey; var flags = binding.Modifiers;
        if (!(key is >= 65 and <= 90 or >= 48 and <= 57 or >= 186 and <= 192 or >= 219 and <= 222)) throw new ArgumentException("Use one letter, number, or punctuation key.");
        if (!flags.HasFlag(ShortcutModifiers.Control) || (flags & ~(ShortcutModifiers.Control | ShortcutModifiers.Shift | ShortcutModifiers.Alt)) != 0) throw new ArgumentException("Use Ctrl to avoid intercepting ordinary typing or terminal input.");
        var ownDefault = definition.DefaultBinding == binding;
        if (flags.HasFlag(ShortcutModifiers.Alt) && !ownDefault) throw new ArgumentException("Ctrl+Alt combinations can type characters with AltGr. Use Ctrl or Ctrl+Shift.");
        var reserved = flags switch
        {
            ShortcutModifiers.Control => "ACVXZYWQFH MDS".Replace(" ", "").Select(c => (int)c),
            ShortcutModifiers.Control | ShortcutModifiers.Shift => "WZSGCV".Select(c => (int)c),
            _ => Enumerable.Empty<int>()
        };
        if (!ownDefault && (reserved.Contains(key) || key is 187 or 189)) throw new ArgumentException("That shortcut is reserved for editing, windows, zoom, or the terminal.");
        if (Definitions.Any(x => x.Id != id && Binding(x.Id) == binding)) throw new InvalidOperationException("That shortcut is already assigned. Clear the other binding first.");
    }
    public static CommandDefinition Definition(string id) => Definitions.FirstOrDefault(x => x.Id == id) ?? throw new ArgumentException("Unknown Veo command.");
    public IReadOnlyList<CommandDefinition> Suggestions(string prefix) => Definitions.Where(x => x.SlashName is not null && x.SlashName.StartsWith(prefix.TrimStart('/'), StringComparison.OrdinalIgnoreCase)).ToArray();
    public static CommandInvocation? ParseSlash(string text)
    {
        if (!text.StartsWith('/') || text.StartsWith("//", StringComparison.Ordinal)) return null;
        var end = text.IndexOfAny([' ', '\t', '\r', '\n'], 1); var name = (end < 0 ? text[1..] : text[1..end]);
        var definition = Definitions.FirstOrDefault(x => x.SlashName?.Equals(name, StringComparison.OrdinalIgnoreCase) == true);
        return definition is null ? null : new(definition, end < 0 ? "" : text[(end + 1)..].Trim(), false);
    }
}

/// <summary>Window-scoped handlers ensure a shortcut always operates on its own selected chat.</summary>
public sealed class CommandDispatcher
{
    readonly Dictionary<string, Func<CommandInvocation, CancellationToken, Task>> handlers = new(StringComparer.Ordinal);
    public void Register(string id, Func<CommandInvocation, CancellationToken, Task> handler) { CommandRegistry.Definition(id); handlers[id] = handler; }
    public bool IsAvailable(string id) => handlers.ContainsKey(id);
    public async Task<bool> ExecuteSlashAsync(string text, CancellationToken token = default)
    {
        if (CommandRegistry.ParseSlash(text) is not { } invocation) return false;
        await ExecuteAsync(invocation, token); return true;
    }
    public Task ExecuteAsync(CommandInvocation invocation, CancellationToken token = default) => handlers.TryGetValue(invocation.Command.Id, out var handler) ? handler(invocation, token) : throw new NotSupportedException("This window has no action for " + invocation.Command.Title + ". Your draft was kept.");
}
