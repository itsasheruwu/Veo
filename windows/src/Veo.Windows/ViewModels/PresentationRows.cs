using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Xaml;
using System.ComponentModel;
using Veo.Core;
using Veo.Infrastructure.Storage;
namespace Veo_Windows.ViewModels;
public sealed class ChatRow(CatalogEntry entry, bool grouped = false) : ObservableObject
{
    public CatalogEntry Entry { get; private set; } = entry;
    public Thickness CaptionPadding { get; } = new(grouped ? 41 : 8, 2, 9, 2);
    double highlightOpacity;
    bool running = entry.Thread.Status is "active" or "inProgress" or "running";
    public double HighlightOpacity { get => highlightOpacity; private set => SetProperty(ref highlightOpacity, value); }
    public void SetSelected(bool value) => HighlightOpacity = value ? 0.15 : 0;
    public Visibility LiveVisibility => running ? Visibility.Visible : Visibility.Collapsed;
    public Visibility AgeVisibility => running ? Visibility.Collapsed : Visibility.Visible;
    public void SetRunning(bool value)
    {
        if (running == value) return;
        running = value;
        OnPropertyChanged(nameof(LiveVisibility));
        OnPropertyChanged(nameof(AgeVisibility));
        OnPropertyChanged(nameof(AccessibleLabel));
    }
    public void Update(CatalogEntry next)
    {
        var previous = Record;
        Entry = next;
        if (previous.Title != Record.Title || previous.IsPinned != Record.IsPinned) OnPropertyChanged(nameof(Title));
        if (previous.Cwd != Record.Cwd) OnPropertyChanged(nameof(Project));
        if (previous.Title != Record.Title || previous.Cwd != Record.Cwd || previous.IsPinned != Record.IsPinned) OnPropertyChanged(nameof(AccessibleLabel));
        OnPropertyChanged(nameof(Age));
    }
    public PersistedThread Record => Entry.Thread;
    public string Title => (Record.IsPinned ? "• " : "") + Record.Title;
    public string Project => (Entry.Origin == CatalogOrigin.Codex ? "Codex CLI · " : "") + Path.GetFileName(Record.Cwd.TrimEnd(Path.DirectorySeparatorChar));
    public string AccessibleLabel => Title + ", " + Project + (running ? ", live" : "");
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
public sealed class ChatGroup(string key, string collapseKey, CatalogOrigin origin, bool projectless, bool collapsed) : System.Collections.ObjectModel.ObservableCollection<ChatRow>
{
    public string Key { get; private set; } = key;
    public string CollapseKey { get; } = collapseKey;
    public CatalogOrigin Origin { get; } = origin;
    bool isCollapsed = collapsed;
    public string Chevron => isCollapsed ? "\uE76C" : "\uE70D";
    public string Icon => projectless ? "\uE8F2" : "\uE8B7";
    public string AccessibleLabel => Key + (isCollapsed ? ", collapsed" : ", expanded");
    public void UpdateHeader(string label, bool collapsed)
    {
        if (Key == label && isCollapsed == collapsed) return;
        Key = label;
        isCollapsed = collapsed;
        OnPropertyChanged(new PropertyChangedEventArgs(nameof(Key)));
        OnPropertyChanged(new PropertyChangedEventArgs(nameof(Chevron)));
        OnPropertyChanged(new PropertyChangedEventArgs(nameof(AccessibleLabel)));
    }
}
public sealed class MessageRow(ThreadSession session, TimelineItem item) : ObservableObject
{
    public ThreadSession Session { get; } = session;
    public Action<string>? ToggleWork { get; init; }
    public Func<TimelineItem, Task>? ReviewTurn { get; init; }
    public Func<IReadOnlyList<(int Number, ConversationArtifact Artifact)>, string, Task>? AddConceptFeedback { get; init; }
    TimelineItem itemValue = item;
    public TimelineItem Item { get => itemValue; set => SetProperty(ref itemValue, value); }
    public string Id { get; } = item.Id;
    public string Kind { get; } = item.Kind switch { "userMessage" => "You", "agentMessage" => item.Raw.Str("veoProviderName") ?? "Codex", "reasoning" => "Reasoning", "commandExecution" => "Terminal", _ => item.Kind };
    string textValue = item.Text;
    public string Text { get => textValue; set => SetProperty(ref textValue, value); }
    public void Update(TimelineItem value) { Text = value.Text; Item = value; }
    public void RefreshPresentation() => OnPropertyChanged(nameof(Text));
    public override string ToString() => Kind + ": " + Text;
}
