using System.Text.Json.Serialization;

namespace Veo.Core;

public enum TerminalSplitAxis { Horizontal, Vertical }
public enum TerminalGridPreset { Single, TwoUp, TwoStack, Quad, Six }
public sealed record TerminalSessionDescriptor(string Id, string ThreadId, string Cwd, string Title)
{
    // Temporary workspaces have UUID directory names. Keep the original cwd for the shell and tooltip.
    [JsonIgnore] public string DisplayTitle
    {
        get
        {
            var name = Path.GetFileName(Cwd.TrimEnd(Path.DirectorySeparatorChar));
            return Guid.TryParse(name, out _) && Title.StartsWith(name, StringComparison.OrdinalIgnoreCase)
                ? "Terminal" + Title[name.Length..] : Title;
        }
    }
    public override string ToString() => DisplayTitle;
}

[JsonPolymorphic(TypeDiscriminatorPropertyName = "$kind")]
[JsonDerivedType(typeof(TerminalPaneLeaf), "leaf")]
[JsonDerivedType(typeof(TerminalPaneSplit), "split")]
public abstract record TerminalPaneNode
{
    [JsonIgnore] public abstract IReadOnlyList<string> SessionIds { get; }
    [JsonIgnore] public int LeafCount => SessionIds.Count;
    public bool Contains(string id) => SessionIds.Contains(id, StringComparer.Ordinal);
    public TerminalPaneNode Replace(string oldId, string newId) => this switch
    {
        TerminalPaneLeaf leaf => leaf.SessionId == oldId ? new TerminalPaneLeaf(newId) : leaf,
        TerminalPaneSplit split => split with { First = split.First.Replace(oldId, newId), Second = split.Second.Replace(oldId, newId) },
        _ => throw new InvalidOperationException()
    };
    public TerminalPaneNode Split(string focused, string newId, TerminalSplitAxis axis)
    {
        if (LeafCount >= 6 || Contains(newId) || !Contains(focused)) throw new InvalidOperationException("Choose a visible pane and keep at most six panes.");
        TerminalPaneNode Recurse(TerminalPaneNode node) => node switch
        {
            TerminalPaneLeaf leaf when leaf.SessionId == focused => new TerminalPaneSplit(Guid.NewGuid().ToString("N"), axis, 0.5, leaf, new TerminalPaneLeaf(newId)),
            TerminalPaneSplit split => split with { First = Recurse(split.First), Second = Recurse(split.Second) },
            _ => node
        };
        return Recurse(this);
    }
    public TerminalPaneNode? Remove(string id) => this switch
    {
        TerminalPaneLeaf leaf => leaf.SessionId == id ? null : leaf,
        TerminalPaneSplit split => Collapse(split, split.First.Remove(id), split.Second.Remove(id)),
        _ => throw new InvalidOperationException()
    };
    private static TerminalPaneNode? Collapse(TerminalPaneSplit split, TerminalPaneNode? first, TerminalPaneNode? second) =>
        first is null ? second : second is null ? first : split with { First = first, Second = second };
    public TerminalPaneNode Swap(string first, string second)
    {
        if (first == second || !Contains(first) || !Contains(second)) return this;
        var temporary = "veo-swap-" + Guid.NewGuid().ToString("N"); return Replace(first, temporary).Replace(second, first).Replace(temporary, second);
    }
    public TerminalPaneNode SetRatio(string id, double ratio)
    {
        if (!double.IsFinite(ratio)) throw new ArgumentOutOfRangeException(nameof(ratio));
        return this is TerminalPaneSplit split ? split.Id == id ? split with { Ratio = Math.Clamp(ratio, 0.2, 0.8) }
            : split with { First = split.First.SetRatio(id, ratio), Second = split.Second.SetRatio(id, ratio) } : this;
    }
    public TerminalPaneNode? Prune(IReadOnlySet<string> live)
    {
        var result = this as TerminalPaneNode;
        foreach (var id in SessionIds.Where(id => !live.Contains(id))) result = result?.Remove(id);
        return result;
    }
    public static int Count(TerminalGridPreset preset) => preset switch { TerminalGridPreset.Single => 1, TerminalGridPreset.TwoUp or TerminalGridPreset.TwoStack => 2, TerminalGridPreset.Quad => 4, TerminalGridPreset.Six => 6, _ => throw new ArgumentOutOfRangeException(nameof(preset)) };
    public static TerminalPaneNode Preset(TerminalGridPreset preset, IReadOnlyList<string> ids)
    {
        var count = Count(preset);
        if (ids.Count < count || ids.Take(count).Distinct(StringComparer.Ordinal).Count() != count) throw new ArgumentException("Each visible pane needs a distinct existing session.");
        TerminalPaneNode Leaf(int index) => new TerminalPaneLeaf(ids[index]);
        TerminalPaneNode Pair(TerminalSplitAxis axis, TerminalPaneNode first, TerminalPaneNode second, double ratio = 0.5) => new TerminalPaneSplit(Guid.NewGuid().ToString("N"), axis, ratio, first, second);
        return preset switch
        {
            TerminalGridPreset.Single => Leaf(0),
            TerminalGridPreset.TwoUp => Pair(TerminalSplitAxis.Horizontal, Leaf(0), Leaf(1)),
            TerminalGridPreset.TwoStack => Pair(TerminalSplitAxis.Vertical, Leaf(0), Leaf(1)),
            TerminalGridPreset.Quad => Pair(TerminalSplitAxis.Vertical, Pair(TerminalSplitAxis.Horizontal, Leaf(0), Leaf(1)), Pair(TerminalSplitAxis.Horizontal, Leaf(2), Leaf(3))),
            TerminalGridPreset.Six => Pair(TerminalSplitAxis.Horizontal, Pair(TerminalSplitAxis.Vertical, Leaf(0), Leaf(3)),
                Pair(TerminalSplitAxis.Horizontal, Pair(TerminalSplitAxis.Vertical, Leaf(1), Leaf(4)), Pair(TerminalSplitAxis.Vertical, Leaf(2), Leaf(5))), 1d / 3),
            _ => throw new ArgumentOutOfRangeException(nameof(preset))
        };
    }
}
public sealed record TerminalPaneLeaf(string SessionId) : TerminalPaneNode
{ [JsonIgnore] public override IReadOnlyList<string> SessionIds => [SessionId]; }
public sealed record TerminalPaneSplit(string Id, TerminalSplitAxis Axis, double Ratio, TerminalPaneNode First, TerminalPaneNode Second) : TerminalPaneNode
{ [JsonIgnore] public override IReadOnlyList<string> SessionIds => [.. First.SessionIds, .. Second.SessionIds]; }
public sealed record TerminalWorkspaceSnapshot(int Version, bool Expanded, string? FocusedSessionId,
    IReadOnlyList<TerminalSessionDescriptor> Sessions, TerminalPaneNode? Layout)
{
    public void Validate()
    {
        if (Version != 1 || Sessions.Count > 1000 || Sessions.Any(session => string.IsNullOrWhiteSpace(session.Id) || string.IsNullOrWhiteSpace(session.ThreadId) || !Path.IsPathFullyQualified(session.Cwd)) || Sessions.Select(session => session.Id).Distinct(StringComparer.Ordinal).Count() != Sessions.Count)
            throw new InvalidDataException("Saved terminal session metadata is invalid.");
        var live = Sessions.Select(session => session.Id).ToHashSet(StringComparer.Ordinal);
        if (Layout is not null)
        {
            if (Layout.LeafCount > 6 || Layout.SessionIds.Distinct(StringComparer.Ordinal).Count() != Layout.LeafCount || Layout.SessionIds.Any(id => !live.Contains(id))) throw new InvalidDataException("Saved terminal pane layout references missing or repeated sessions.");
            void CheckNode(TerminalPaneNode node, int depth)
            {
                if (depth > 12) throw new InvalidDataException("Saved terminal layout is too deeply nested.");
                if (node is TerminalPaneSplit split)
                {
                    if (!double.IsFinite(split.Ratio) || split.Ratio < 0.2 || split.Ratio > 0.8 || !Enum.IsDefined(split.Axis)) throw new InvalidDataException("Saved terminal split dimensions are invalid.");
                    CheckNode(split.First, depth + 1); CheckNode(split.Second, depth + 1);
                }
            }
            CheckNode(Layout, 0);
        }
        if (FocusedSessionId is not null && !live.Contains(FocusedSessionId)) throw new InvalidDataException("The focused terminal session no longer exists.");
    }
}

/// <summary>Layout changes never own, recreate or relocate a shell. One registry owns each session once.</summary>
public sealed class TerminalSessionOwnership<TSession> : IAsyncDisposable where TSession : IAsyncDisposable
{
    private readonly Dictionary<string, (TerminalSessionDescriptor Descriptor, TSession Session)> entries = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim gate = new(1, 1);
    private bool disposed;
    public async Task<TSession> GetOrCreateAsync(TerminalSessionDescriptor descriptor, Func<Task<TSession>> factory)
    {
        await gate.WaitAsync();
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (entries.TryGetValue(descriptor.Id, out var existing))
            {
                if (existing.Descriptor.Cwd != descriptor.Cwd || existing.Descriptor.ThreadId != descriptor.ThreadId)
                    throw new InvalidOperationException("An existing shell keeps its original directory and thread identity.");
                return existing.Session;
            }
            var session = await factory(); entries.Add(descriptor.Id, (descriptor, session)); return session;
        }
        finally { gate.Release(); }
    }
    public async Task CloseAsync(string id)
    {
        await gate.WaitAsync();
        try { if (entries.Remove(id, out var entry)) await entry.Session.DisposeAsync(); }
        finally { gate.Release(); }
    }
    public async ValueTask DisposeAsync()
    {
        await gate.WaitAsync();
        try
        {
            if (disposed) return; disposed = true;
            var owned = entries.Values.ToArray(); entries.Clear();
            List<Exception>? errors = null;
            foreach (var entry in owned) try { await entry.Session.DisposeAsync(); } catch (Exception error) { (errors ??= []).Add(error); }
            if (errors is not null) throw new AggregateException("Some owned terminal sessions failed to close.", errors);
        }
        finally { gate.Release(); }
    }
}
