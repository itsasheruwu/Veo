using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Veo.Protocol;
using System.Text.Json;

namespace Veo_Windows.Controls;

/// <summary>Native inventories and explicit actions, scoped to the originating chat.</summary>
public sealed class IntegrationsPanel : StackPanel
{
    readonly IntegrationCoordinator integrations;
    readonly IntegrationContext context;
    readonly Action<Uri> navigate;
    readonly StackPanel body = new() { Spacing = 12 };
    readonly InfoBar notice = new() { IsClosable = true };
    readonly ProgressBar progress = new() { IsIndeterminate = true, Visibility = Visibility.Collapsed };
    StackPanel importItems = new() { Spacing = 6 };
    TextBlock importStatus = Text("");
    string? importId;
    bool busy;
    public IntegrationsPanel(IntegrationCoordinator integrations, ThreadSession? session, Action<Uri> navigate)
    {
        this.integrations = integrations; this.navigate = navigate; context = IntegrationContext.For(session); Spacing = 12;
        var refresh = Button("Refresh integrations", RefreshAsync); AutomationProperties.SetAutomationId(refresh, "IntegrationsRefresh");
        Children.Add(Text(context.Cwd is null ? "Select a project chat for its skills and runtime tools." : "Project: " + context.Cwd));
        Children.Add(refresh); Children.Add(progress); Children.Add(notice); Children.Add(body);
        Loaded += (_, _) => { integrations.Navigate -= OnNavigate; integrations.Navigate += OnNavigate; integrations.Changed -= OnChanged; integrations.Changed += OnChanged; Run(RefreshAsync); };
        Unloaded += (_, _) => { integrations.Navigate -= OnNavigate; integrations.Changed -= OnChanged; };
    }
    void OnNavigate(Uri uri) => DispatcherQueue.TryEnqueue(() => navigate(uri));
    void OnChanged() => DispatcherQueue.TryEnqueue(() =>
    {
        if (importId is not null && integrations.ImportProgress(importId) is { } state)
            importStatus.Text = (state.Complete ? "Import finished" : "Import in progress") + $" · {state.Successes} succeeded · {state.Failures} failed" + (state.Errors.Length == 0 ? "" : "\n" + string.Join("\n", state.Errors));
    });
    async Task RefreshAsync() { var snapshot = await integrations.RefreshAsync(context); Render(snapshot); }
    void Render(IntegrationSnapshot state)
    {
        body.Children.Clear();
        foreach (var issue in state.Issues) body.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Title = issue.Unavailable ? "Unavailable in this runtime" : "Could not load inventory", Message = issue.Method + ": " + issue.Message });
        var skills = new StackPanel { Spacing = 10 };
        foreach (var skill in state.Skills)
        {
            var row = new StackPanel { Spacing = 4 }; var toggle = new ToggleSwitch { Header = skill.Title, IsOn = skill.Enabled }; var resetting = false;
            AutomationProperties.SetAutomationId(toggle, "IntegrationSkill_" + Uri.EscapeDataString(skill.Id));
            toggle.Toggled += (_, _) => { if (!resetting) Run(async () => { toggle.IsEnabled = false; try { await integrations.SetSkillEnabledAsync(context, skill, toggle.IsOn); } catch { resetting = true; toggle.IsOn = skill.Enabled; resetting = false; throw; } finally { toggle.IsEnabled = true; } }); };
            row.Children.Add(toggle); row.Children.Add(Text(skill.Description + "\n" + skill.Scope + (skill.Path is null ? "" : " · " + skill.Path)));
            if (skill.Path is not null) row.Children.Add(Button("Reveal skill source", () => { Reveal(skill.Path); return Task.CompletedTask; }, File.Exists(skill.Path)));
            skills.Children.Add(row);
        }
        if (state.Skills.Length == 0) skills.Children.Add(Text("No skills were reported for this project.")); body.Children.Add(Section("Skills", skills));
        var plugins = new StackPanel { Spacing = 10 };
        var search = new TextBox { Header = "Find plugins", PlaceholderText = "Search connected marketplaces" }; AutomationProperties.SetAutomationId(search, "PluginSearch");
        var matches = new StackPanel { Spacing = 8 }; plugins.Children.Add(search); plugins.Children.Add(Button("Search", async () => { matches.Children.Clear(); foreach (var plugin in await integrations.SearchPluginsAsync(context, search.Text)) matches.Children.Add(Plugin(plugin)); if (matches.Children.Count == 0) matches.Children.Add(Text("No matching plugins.")); })); plugins.Children.Add(matches);
        foreach (var marketplace in state.Marketplaces)
        {
            var group = new StackPanel { Spacing = 8 }; group.Children.Add(Text(marketplace.Path ?? marketplace.Name));
            group.Children.Add(Button("Update this marketplace", async () => { await integrations.ChangeMarketplaceAsync(context, "upgrade", marketplace.Name); Render(integrations.Snapshot(context)); }));
            var remove = new Button { Content = "Remove marketplace…" }; remove.Click += (_, _) => Run(async () => { if (await Confirm("Remove marketplace?", "Installed plugins remain owned by Codex. This removes the selected marketplace source.", "Remove")) { await integrations.ChangeMarketplaceAsync(context, "remove", marketplace.Name); Render(integrations.Snapshot(context)); } }); group.Children.Add(remove);
            foreach (var plugin in marketplace.Plugins) group.Children.Add(Plugin(plugin)); plugins.Children.Add(Section(marketplace.Title, group));
        }
        var source = new TextBox { Header = "Marketplace source", PlaceholderText = "Local path or source supported by Codex" }; plugins.Children.Add(source); plugins.Children.Add(Button("Add marketplace", async () => { await integrations.ChangeMarketplaceAsync(context, "add", source.Text); Render(integrations.Snapshot(context)); }));
        body.Children.Add(Section("Plugins and marketplaces", plugins));
        var apps = new StackPanel { Spacing = 8 };
        foreach (var app in state.Apps)
        {
            var details = new StackPanel { Spacing = 6 }; details.Children.Add(Text(app.Description));
            details.Children.Add(Text((app.Enabled ? "Enabled" : "Disabled") + " · " + (app.Accessible ? "Connected" : "Connection required") + (app.Callable is { } callable ? callable ? " · callable" : " · not callable" : " · tool availability not reported")));
            if (app.InstallUrl is not null && !app.Accessible) details.Children.Add(Button("Connect in Veo's browser", () => { integrations.OpenAppConnection(app); return Task.CompletedTask; }, app.Enabled));
            details.Children.Add(Button("Load app tools", async () =>
            {
                var loaded = await integrations.ReadAppDetailsAsync(context, new[] { app.Id });
                foreach (var item in loaded)
                {
                    var tools = IntegrationCoordinator.Rows(item.Raw, "tools");
                    details.Children.Add(Text(tools.Length == 0 ? "No tools were reported for this app." : "Tools supplied by this app:"));
                    foreach (var tool in tools) details.Children.Add(Text((tool.Str("title") ?? tool.Str("name") ?? "Tool") + "\n" + tool.Str("description")));
                }
            })); apps.Children.Add(Section(app.Name, details));
        }
        if (state.Apps.Length == 0) apps.Children.Add(Text("No apps were reported by this runtime.")); body.Children.Add(Section("Apps and connections", apps));
        var servers = new StackPanel { Spacing = 10 }; servers.Children.Add(Button("Reload MCP configuration", async () => { await integrations.ReloadMcpAsync(context); Render(integrations.Snapshot(context)); }));
        foreach (var server in state.McpServers) servers.Children.Add(Server(server));
        if (state.McpServers.Length == 0) servers.Children.Add(Text("No MCP servers were reported.")); body.Children.Add(Section("MCP servers", servers));
        body.Children.Add(Section("Import external-agent settings", ImportForm()));
    }
    FrameworkElement Plugin(PluginIntegration plugin)
    {
        var row = new StackPanel { Spacing = 6 }; row.Children.Add(Text(plugin.Description)); row.Children.Add(Text((plugin.Installed ? "Installed" : "Not installed") + " · " + (plugin.Enabled ? "enabled" : "disabled") + " · " + plugin.Availability + " · " + plugin.InstallPolicy));
        row.Children.Add(Button(plugin.Installed ? "Uninstall…" : "Install", async () =>
        {
            if (!plugin.Installed || await Confirm("Uninstall " + plugin.Title + "?", "Codex will remove this plugin's local installation.", "Uninstall")) { await integrations.SetPluginInstalledAsync(context, plugin, !plugin.Installed); Render(integrations.Snapshot(context)); }
        }, plugin.Installed || plugin.CanInstall));
        var detail = new StackPanel { Spacing = 5 }; row.Children.Add(Button("Load plugin details", async () =>
        {
            detail.Children.Clear(); var result = await integrations.ReadPluginAsync(plugin); detail.Children.Add(Text(result.Str("description") ?? plugin.Description));
            foreach (var key in new[] { "skills", "hooks", "apps", "appTemplates", "mcpServers", "scheduledTasks" })
            {
                var values = IntegrationCoordinator.Rows(result, key); if (values.Length == 0) continue;
                detail.Children.Add(Text(key switch { "mcpServers" => "MCP servers", "appTemplates" => "App templates", "scheduledTasks" => "Scheduled tasks", _ => char.ToUpperInvariant(key[0]) + key[1..] }));
                foreach (var item in values) detail.Children.Add(Text(item.ValueKind == JsonValueKind.String ? item.GetString()! : (item.Str("displayName") ?? item.Str("name") ?? item.Str("eventName") ?? item.Str("id") ?? "Included component") + (item.Str("description") is { } description ? "\n" + description : "")));
            }
        })); row.Children.Add(detail); return Section(plugin.Title, row);
    }
    FrameworkElement Server(McpServerIntegration server)
    {
        var row = new StackPanel { Spacing = 8 }; row.Children.Add(Text(server.RuntimeStatus + " · authentication: " + server.AuthStatus));
        if (server.Error is not null) row.Children.Add(new InfoBar { IsOpen = true, Severity = InfoBarSeverity.Error, Message = server.Error });
        if (server.AuthStatus is "notLoggedIn" or "expired") row.Children.Add(Button("Authorize in Veo's browser", async () => { await integrations.StartMcpOAuthAsync(context, server.Name); notice.Message = "Complete authorization, then refresh the MCP status."; notice.IsOpen = true; }));
        if (integrations.OAuth(server.Name) is { } oauth) row.Children.Add(Text(oauth.State + (oauth.Error is null ? "" : "\n" + oauth.Error)));
        foreach (var tool in server.Tools)
        {
            var toolRow = new StackPanel { Spacing = 8 }; toolRow.Children.Add(Text(tool.Description)); var form = new NativeSchemaFormPanel(tool.Form); toolRow.Children.Add(form); var output = new StackPanel { Spacing = 8 };
            toolRow.Children.Add(Button("Run tool", async () => { var result = await integrations.CallToolAsync(context, server.Name, tool, form.Values()); output.Children.Clear(); output.Children.Add(new IntegrationResultView(result)); }, tool.Form.IsSupported && context.RuntimeThreadId is not null));
            if (context.RuntimeThreadId is null) toolRow.Children.Add(Text("Load a runtime chat before calling a tool.")); toolRow.Children.Add(output); row.Children.Add(Section(tool.Title, toolRow));
        }
        foreach (var resource in server.Resources)
        {
            var resourceRow = new StackPanel { Spacing = 6 }; resourceRow.Children.Add(Text(resource.Description ?? resource.Uri)); var output = new StackPanel { Spacing = 8 };
            resourceRow.Children.Add(Button("Read resource", async () => { output.Children.Clear(); foreach (var content in await integrations.ReadResourceAsync(context, server.Name, resource.Uri)) output.Children.Add(new IntegrationResultView(content)); })); resourceRow.Children.Add(output); row.Children.Add(Section(resource.Name, resourceRow));
        }
        foreach (var template in server.Templates)
        {
            var templateRow = new StackPanel { Spacing = 6 }; templateRow.Children.Add(Text(template.Description ?? template.UriTemplate));
            var uri = new TextBox { Header = "Resolved resource URI", PlaceholderText = template.UriTemplate }; var output = new StackPanel { Spacing = 8 }; templateRow.Children.Add(uri);
            templateRow.Children.Add(Button("Read resolved resource", async () => { if (string.IsNullOrWhiteSpace(uri.Text) || uri.Text.Contains('{')) throw new InvalidOperationException("Resolve every template parameter before reading."); output.Children.Clear(); foreach (var content in await integrations.ReadResourceAsync(context, server.Name, uri.Text.Trim())) output.Children.Add(new IntegrationResultView(content)); })); templateRow.Children.Add(output); row.Children.Add(Section(template.Name, templateRow));
        }
        return Section(server.Name, row);
    }
    FrameworkElement ImportForm()
    {
        importItems = new() { Spacing = 6 }; importStatus = Text("");
        var form = new StackPanel { Spacing = 8 }; form.Children.Add(Text("Scan first, then choose the artifacts to import into local Codex configuration. Importing changes Codex settings and can affect other clients."));
        var home = new CheckBox { Content = "Include home-directory settings", IsChecked = false }; var source = new TextBox { Header = "Migration source (optional)", PlaceholderText = "Use the runtime default" }; AutomationProperties.SetAutomationId(home, "ImportIncludeHome"); form.Children.Add(home); form.Children.Add(source);
        var selected = new HashSet<string>(StringComparer.Ordinal); string? detectedSource = null;
        form.Children.Add(Button("Scan for importable artifacts", async () =>
        {
            selected.Clear(); importItems.Children.Clear(); detectedSource = string.IsNullOrWhiteSpace(source.Text) ? null : source.Text.Trim();
            foreach (var item in await integrations.DetectExternalAsync(context, home.IsChecked == true, detectedSource))
            {
                var checkbox = new CheckBox { Content = item.Description + "\n" + (item.Cwd ?? "Home settings") + (item.DetailCounts.Length == 0 ? "" : "\n" + string.Join(" · ", item.DetailCounts)), IsChecked = false };
                checkbox.Checked += (_, _) => selected.Add(item.Id); checkbox.Unchecked += (_, _) => selected.Remove(item.Id); importItems.Children.Add(checkbox);
            }
            if (importItems.Children.Count == 0) importItems.Children.Add(Text("No importable artifacts were detected."));
        })); form.Children.Add(importItems);
        form.Children.Add(Button("Import selected…", async () => { if (selected.Count == 0) throw new InvalidOperationException("Select at least one detected artifact."); if (await Confirm("Import selected settings?", $"Codex will import {selected.Count} selected artifact(s). Existing local configuration may change.", "Import")) { importId = await integrations.ImportExternalAsync(context, selected, detectedSource); OnChanged(); } })); form.Children.Add(importStatus); return form;
    }
    async Task<bool> Confirm(string title, string message, string primary) => await new ContentDialog { Title = title, Content = message, PrimaryButtonText = primary, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close, XamlRoot = XamlRoot }.ShowAsync() == ContentDialogResult.Primary;
    Button Button(string title, Func<Task> action, bool enabled = true) { var button = new Button { Content = title, IsEnabled = enabled }; button.Click += (_, _) => Run(action); return button; }
    async void Run(Func<Task> action)
    {
        if (busy) return; busy = true; progress.Visibility = Visibility.Visible;
        try { notice.IsOpen = false; await action(); } catch (Exception exception) { notice.Message = DiagnosticRedactor.Redact(exception.Message); notice.Severity = InfoBarSeverity.Error; notice.IsOpen = true; }
        finally { busy = false; progress.Visibility = Visibility.Collapsed; }
    }
    static void Reveal(string path) => Process.Start(new ProcessStartInfo("explorer.exe") { UseShellExecute = true, ArgumentList = { "/select,", path } });
    static TextBlock Text(string value) => new() { Text = value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    static Expander Section(string title, object content) => new() { Header = title, Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
}
