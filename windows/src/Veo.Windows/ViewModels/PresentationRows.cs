using CommunityToolkit.Mvvm.ComponentModel;
using Veo.Core;
using Veo.Infrastructure.Storage;
namespace Veo_Windows.ViewModels;
public sealed class ChatRow(CatalogEntry entry) : ObservableObject
{
    public CatalogEntry Entry { get; } = entry;
    double highlightOpacity;
    public double HighlightOpacity { get => highlightOpacity; private set => SetProperty(ref highlightOpacity, value); }
    public void SetSelected(bool value) => HighlightOpacity = value ? 0.18 : 0;
    public PersistedThread Record => Entry.Thread;
    public string Title => (Record.IsPinned ? "• " : "") + Record.Title;
    public string Project => (Entry.Origin == CatalogOrigin.Codex ? "Codex CLI · " : "") + Path.GetFileName(Record.Cwd.TrimEnd(Path.DirectorySeparatorChar));
    public string AccessibleLabel => Title + ", " + Project;
    public string Age
    {
        get
        {
            if (Record.UpdatedAt == default) return "";
            var elapsed = DateTimeOffset.UtcNow - Record.UpdatedAt;
            if (elapsed.TotalMinutes < 1) return "Now";
            if (elapsed.TotalHours < 1) return $"{(int)elapsed.TotalMinutes}m";
            if (elapsed.TotalDays < 1) return $"{(int)elapsed.TotalHours}h";
            return $"{(int)elapsed.TotalDays}d";
        }
    }
    public override string ToString() => Title + ", " + Project;
}
public sealed class ChatGroup(string key, string project, CatalogOrigin origin, bool projectless, bool collapsed, IEnumerable<ChatRow> entries) : System.Collections.ObjectModel.ObservableCollection<ChatRow>(entries)
{
    public string Key { get; } = key;
    public string ProjectPath { get; } = project;
    public CatalogOrigin Origin { get; } = origin;
    public string Chevron => collapsed ? "\uE76C" : "\uE70D";
    public string Icon => projectless ? "\uE8F2" : "\uE8B7";
    public string AccessibleLabel => Key + (collapsed ? ", collapsed" : ", expanded");
}
public sealed class MessageRow(ThreadSession session, TimelineItem item) : ObservableObject
{
    public ThreadSession Session { get; } = session;
    TimelineItem itemValue = item;
    public TimelineItem Item { get => itemValue; set => SetProperty(ref itemValue, value); }
    public string Id { get; } = item.Id;
    public string Kind { get; } = item.Kind switch { "userMessage" => "You", "agentMessage" => "Codex", "reasoning" => "Reasoning", "commandExecution" => "Terminal", _ => item.Kind };
    string textValue = item.Text;
    public string Text { get => textValue; set => SetProperty(ref textValue, value); }
    public void Update(TimelineItem value) { Text = value.Text; Item = value; }
    public void RefreshPresentation() => OnPropertyChanged(nameof(Text));
    public override string ToString() => Kind + ": " + Text;
}
