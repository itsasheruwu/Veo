using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Veo.Core;
using Veo.Protocol;
using Veo_Windows.ViewModels;

namespace Veo_Windows;

public sealed partial class MainPage
{
    readonly ObservableCollection<ChatGroup> sidebarGroups = [];
    readonly ObservableCollection<ChatRow> sidebarFlatRows = [];
    bool sidebarIsGrouped;

    async Task RefreshCatalogAsync()
    {
        var revision = ++catalogRefreshRevision;
        var query = SearchBox.Visibility == Visibility.Visible ? SearchBox.Text.Trim() : "";
        var grouped = workspace.Preferences.GroupByProject;
        var archived = workspace.Preferences.ShowArchived;
        var catalog = await App.Catalog.LoadAsync();
        var entries = catalog.Veo.Concat(catalog.Codex).Where(entry => query.Length == 0
            || (entry.Thread.Title + "\n" + entry.Thread.Preview + "\n" + entry.Thread.Cwd).Contains(query, StringComparison.OrdinalIgnoreCase)).ToArray();
        var projectPaths = grouped
            ? await App.Projects.RegisteredProjectPathsAsync(entries.Where(entry => entry.Thread.WorkspaceKind == "project").Select(entry => entry.Thread.Cwd))
            : null;
        if (revision != catalogRefreshRevision) return;

        SidebarCatalogLabel.Text = archived ? "Archived" : "Chats";
        SidebarEmptyLabel.Text = query.Length > 0 ? "No matching chats" : archived ? "No archived chats" : "No chats yet";
        SidebarEmptyLabel.Visibility = entries.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        Dictionary<(CatalogOrigin Origin, string Key), ChatRow> existingRows = sidebarIsGrouped == grouped
            ? visibleCatalogRows.ToDictionary(row => (row.Entry.Origin, row.Entry.Key))
            : [];
        var activeChats = workspace.LoadedSessions.Where(session => session.Timeline.IsRunning)
            .Select(session => session.Record.VeoId).ToHashSet(StringComparer.Ordinal);

        ChatRow Row(CatalogEntry entry)
        {
            if (!existingRows.TryGetValue((entry.Origin, entry.Key), out var row)) row = new ChatRow(entry, grouped);
            else row.Update(entry);
            row.SetRunning(activeChats.Contains(entry.Thread.VeoId) || entry.Thread.Status is "active" or "inProgress" or "running");
            return row;
        }

        updatingCatalog = true;
        try
        {
            sidebarIsGrouped = grouped;
            if (grouped)
            {
                var next = new List<ChatGroup>();
                foreach (var origin in new[] { CatalogOrigin.Veo, CatalogOrigin.Codex })
                {
                    var groups = sidebarGroups.Where(group => group.Origin == origin)
                        .ToDictionary(group => group.CollapseKey, StringComparer.OrdinalIgnoreCase);
                    foreach (var group in App.Catalog.Group(entries.Where(entry => entry.Origin == origin), projectPaths))
                    {
                        var label = (origin == CatalogOrigin.Codex ? "Codex CLI · " : "") + group.Label;
                        if (!groups.TryGetValue(group.CollapseKey, out var header))
                            header = new ChatGroup(label, group.CollapseKey, origin, group.IsProjectless, group.IsCollapsed);
                        else header.UpdateHeader(label, group.IsCollapsed);
                        UpdateSidebarCollection(header, group.IsCollapsed ? [] : group.Entries.Select(Row).ToArray());
                        next.Add(header);
                    }
                }
                UpdateSidebarCollection(sidebarGroups, next);
                if (!ReferenceEquals(GroupedChats.Source, sidebarGroups)) GroupedChats.Source = sidebarGroups;
                if (!ReferenceEquals(ChatList.ItemsSource, GroupedChats.View)) ChatList.ItemsSource = GroupedChats.View;
                sidebarFlatRows.Clear();
                visibleCatalogRows = sidebarGroups.SelectMany(group => group).ToArray();
            }
            else
            {
                UpdateSidebarCollection(sidebarFlatRows, entries.Select(Row).ToArray());
                if (!ReferenceEquals(ChatList.ItemsSource, sidebarFlatRows)) ChatList.ItemsSource = sidebarFlatRows;
                sidebarGroups.Clear();
                visibleCatalogRows = sidebarFlatRows.ToArray();
            }
            SyncCatalogSelection();
        }
        finally { updatingCatalog = false; }
    }

    static void UpdateSidebarCollection<T>(ObservableCollection<T> current, IReadOnlyList<T> next) where T : class
    {
        var desired = new HashSet<T>(next, ReferenceEqualityComparer.Instance);
        for (var index = current.Count - 1; index >= 0; index--)
            if (!desired.Contains(current[index])) current.RemoveAt(index);
        var retained = new HashSet<T>(current, ReferenceEqualityComparer.Instance);
        for (var index = 0; index < next.Count; index++)
        {
            if (index < current.Count && ReferenceEquals(current[index], next[index])) continue;
            if (retained.Contains(next[index])) current.Move(current.IndexOf(next[index]), index);
            else current.Insert(index, next[index]);
        }
    }

    void SyncCatalogSelection()
    {
        var selected = current?.Record.VeoId ?? workspace.Preferences.SelectedThread;
        var runtimeId = current?.Record.CodexThreadId;
        var row = visibleCatalogRows.FirstOrDefault(item => item.Record.VeoId == selected || runtimeId is not null
            && item.Entry.Origin == CatalogOrigin.Codex && item.Record.CodexThreadId == runtimeId);
        var wasUpdating = updatingCatalog;
        updatingCatalog = true;
        try { if (!ReferenceEquals(ChatList.SelectedItem, row)) ChatList.SelectedItem = row; }
        finally { updatingCatalog = wasUpdating; }
    }

    void SidebarRuntimeEventApplied(ThreadSession session, RuntimeEvent message)
    {
        if (message.Method is not ("turn/started" or "turn/completed" or "turn/aborted")) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            var row = visibleCatalogRows.FirstOrDefault(item => item.Record.VeoId == session.Record.VeoId
                || session.Record.CodexThreadId is { } id && item.Record.CodexThreadId == id);
            row?.SetRunning(session.Timeline.IsRunning);
        });
    }
}
