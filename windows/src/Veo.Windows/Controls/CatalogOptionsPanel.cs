using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Veo.Core;

namespace Veo_Windows.Controls;

public sealed class CatalogOptionsPanel : UserControl
{
    readonly WorkspaceCoordinator workspace; readonly ThreadCatalogCoordinator catalog;
    readonly Func<CatalogEntry, Task> open; readonly Func<CatalogSearchResult, Task>? navigate;
    readonly StackPanel body = new() { Spacing = 10 }; readonly CheckBox codex = new() { Content = "Show optional Codex CLI history" };
    readonly CheckBox grouped = new() { Content = "Group chats by project" }; readonly ComboBox sort = new() { Header = "Chat order", ItemsSource = Enum.GetValues<CatalogSort>() };
    readonly ListView chats = new() { Height = 210, SelectionMode = ListViewSelectionMode.Single, ItemContainerTransitions = new() };
    readonly ListView results = new() { Height = 200, ItemContainerTransitions = new() };
    readonly TextBox title = new() { Header = "Selected chat name" }; readonly TextBox projectLabel = new() { Header = "Project label" };
    readonly CheckBox collapsed = new() { Content = "Collapse this project" }; readonly CheckBox confirmDelete = new() { Content = "Permanently delete this chat (Veo chat deletion includes its local fork family)" };
    readonly TextBox query = new() { Header = "Search message content across projects" }; readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    readonly Button more = new() { Content = "Load more Codex history" }; CatalogPage? page; string? searchCursor; string? occurrenceCursor; bool runtimeSearch; bool loading; CancellationTokenSource? search;
    public CatalogOptionsPanel(WorkspaceCoordinator workspace, ThreadCatalogCoordinator catalog, Func<CatalogEntry, Task> open,
        Func<CatalogSearchResult, Task>? navigate = null)
    {
        this.workspace = workspace; this.catalog = catalog; this.open = open; this.navigate = navigate;
        body.Children.Add(codex); body.Children.Add(grouped); body.Children.Add(sort); chats.ItemTemplate = RowTemplate("Title", "Detail"); results.ItemTemplate = RowTemplate("Title", "Detail");
        Button("Save catalog options", async () => { await catalog.SetCodexHistoryAsync(codex.IsChecked == true); workspace.Preferences.GroupByProject = grouped.IsChecked == true; await workspace.SavePreferencesAsync(); await catalog.SaveOptionsAsync(catalog.Options with { Sort = (CatalogSort)(sort.SelectedItem ?? CatalogSort.Priority) }); await RefreshAsync(); });
        body.Children.Add(chats); body.Children.Add(more); more.Click += async (_, _) => await RunAsync(async () => { page = await catalog.LoadAsync(true); ShowPage(); });
        chats.ItemTemplate = RowTemplate("Title", "Detail");
        chats.SelectionChanged += (_, _) =>
        {
            if (Selected is not { } entry) return; title.Text = entry.Thread.Title; var key = ThreadCatalogCoordinator.ProjectKey(entry.Thread.Cwd);
            projectLabel.Text = catalog.Options.ProjectLabels?.GetValueOrDefault(key) ?? ""; collapsed.IsChecked = catalog.Options.CollapsedProjects?.Contains(key, StringComparer.OrdinalIgnoreCase) == true; confirmDelete.IsChecked = false;
        };
        Button("Open selected chat", async () => { if (Selected is { } entry) await open(entry); });
        body.Children.Add(title); Button("Rename selected chat", async () => { if (Selected is { } entry) { await catalog.RenameAsync(entry, title.Text); await RefreshAsync(); } });
        Button("Pin or unpin selected Veo chat", async () => { if (Selected is { Origin: CatalogOrigin.Veo } entry) { await workspace.SetPinnedAsync(await workspace.LoadAsync(entry.Thread), !entry.Thread.IsPinned); await RefreshAsync(); } else throw new InvalidOperationException("Pinning applies to Veo's local chat catalog."); });
        Button("Archive or restore selected chat", async () => { if (Selected is { } entry) { await catalog.SetArchivedAsync(entry, !entry.Thread.IsArchived); await RefreshAsync(); } });
        Button("Move selected chat earlier", () => MoveAsync(-1)); Button("Move selected chat later", () => MoveAsync(1));
        body.Children.Add(projectLabel); body.Children.Add(collapsed);
        Button("Save selected project label and collapse", async () =>
        {
            if (Selected is not { } entry) return; var key = ThreadCatalogCoordinator.ProjectKey(entry.Thread.Cwd); var labels = new Dictionary<string, string>(catalog.Options.ProjectLabels ?? [], StringComparer.OrdinalIgnoreCase);
            if (string.IsNullOrWhiteSpace(projectLabel.Text)) labels.Remove(key); else labels[key] = projectLabel.Text.Trim();
            var collapsedPaths = (catalog.Options.CollapsedProjects ?? []).Where(path => !path.Equals(key, StringComparison.OrdinalIgnoreCase)).ToList(); if (collapsed.IsChecked == true) collapsedPaths.Add(key);
            await catalog.SaveOptionsAsync(catalog.Options with { ProjectLabels = labels, CollapsedProjects = collapsedPaths.ToArray() });
        });
        body.Children.Add(confirmDelete); Button("Delete selected chat", async () => { if (confirmDelete.IsChecked != true) throw new InvalidOperationException("Select the deletion confirmation first."); if (Selected is { } entry) { confirmDelete.IsChecked = false; await catalog.DeleteAsync(entry); await RefreshAsync(); } });
        body.Children.Add(query); query.TextChanged += (_, _) => { search?.Cancel(); searchCursor = occurrenceCursor = null; };
        Button("Search saved local messages", () => SearchAsync(false, false)); Button("Search runtime messages", () => SearchAsync(true, false)); Button("More message matches", () => SearchAsync(runtimeSearch, true));
        results.ItemTemplate = RowTemplate("Title", "Detail"); body.Children.Add(results);
        Button("Find occurrences in selected result", async () =>
        {
            if (results.SelectedItem is not ResultRow row) return; search?.Cancel(); search = new(); var found = await catalog.OccurrencesAsync(row.Result.Entry, query.Text, null, search.Token); occurrenceCursor = found.NextCursor; ShowResults(found);
        });
        Button("Open selected message occurrence", async () => { if (results.SelectedItem is ResultRow row) { if (navigate is not null) await navigate(row.Result); else await open(row.Result.Entry); } });
        body.Children.Add(status); Content = body; Loaded += async (_, _) => await RunAsync(RefreshAsync);
        AutomationProperties.SetName(chats, "All project chats, with separate Veo and Codex origins"); AutomationProperties.SetName(results, "Message search results");
    }
    CatalogEntry? Selected => (chats.SelectedItem as ChatRow)?.Entry;
    public async Task RefreshAsync()
    {
        await catalog.InitializeAsync(); codex.IsChecked = workspace.Preferences.ShowCodexHistory; grouped.IsChecked = workspace.Preferences.GroupByProject; sort.SelectedItem = catalog.Options.Sort; page = await catalog.LoadAsync(); ShowPage();
    }
    void ShowPage()
    {
        if (page is null) return; chats.ItemsSource = page.Veo.Concat(page.Codex).Select(entry => new ChatRow(entry, entry.Thread.Title, (entry.Origin == CatalogOrigin.Codex ? "Codex CLI • " : "Veo • ") + entry.Thread.Cwd)).ToArray(); more.IsEnabled = page.NextCodexCursor is not null;
        status.Text = $"{page.Veo.Count} Veo chats · {page.Codex.Count} optional Codex chats loaded";
    }
    async Task MoveAsync(int delta)
    {
        var rows = chats.Items.OfType<ChatRow>().ToList(); if (chats.SelectedItem is not ChatRow selected) return; var index = rows.IndexOf(selected); var next = Math.Clamp(index + delta, 0, rows.Count - 1); (rows[index], rows[next]) = (rows[next], rows[index]);
        await catalog.ReorderVisibleAsync(rows.Select(x => x.Entry.Key).ToArray(), rows.Select(x => x.Entry.Key).ToArray()); await RefreshAsync();
    }
    async Task SearchAsync(bool runtime, bool moreResults)
    {
        if (moreResults && searchCursor is null) return; search?.Cancel(); search = new(); var token = search.Token; var text = query.Text; runtimeSearch = runtime;
        var found = runtime ? await catalog.SearchRuntimeAsync(text, moreResults ? searchCursor : null, token) : await catalog.SearchContentAsync(text, moreResults ? searchCursor : null, token);
        if (token.IsCancellationRequested || query.Text != text) return; searchCursor = found.NextCursor; ShowResults(found);
    }
    void ShowResults(CatalogSearchPage found) { results.ItemsSource = found.Data.Select(result => new ResultRow(result, result.Entry.Thread.Title, result.Snippet)).ToArray(); status.Text = $"{found.Data.Count} matches on this page" + (found.NextCursor is null ? "" : " · More available"); }
    void Button(string label, Func<Task> action) { var button = new Button { Content = label }; button.Click += async (_, _) => await RunAsync(action); body.Children.Add(button); }
    async Task RunAsync(Func<Task> action) { if (loading) return; loading = true; try { await action(); } catch (OperationCanceledException) { } catch (Exception error) { status.Text = Veo.Protocol.DiagnosticRedactor.Redact(error.Message); } finally { loading = false; } }
    static DataTemplate RowTemplate(string title, string detail) => (DataTemplate)XamlReader.Load($"<DataTemplate xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\"><StackPanel Spacing=\"2\"><TextBlock Text=\"{{Binding {title}}}\" TextTrimming=\"CharacterEllipsis\"/><TextBlock Text=\"{{Binding {detail}}}\" TextWrapping=\"Wrap\" FontSize=\"12\" Foreground=\"{{ThemeResource TextFillColorSecondaryBrush}}\"/></StackPanel></DataTemplate>");
    public sealed record ChatRow(CatalogEntry Entry, string Title, string Detail);
    public sealed record ResultRow(CatalogSearchResult Result, string Title, string Detail);
}
