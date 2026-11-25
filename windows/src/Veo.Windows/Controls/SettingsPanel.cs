using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Veo.Core;
using Veo_Windows.Services;

namespace Veo_Windows.Controls;

public sealed partial class SettingsPanel : UserControl
{
    static readonly Category[] Navigation =
    [
        new("General", "Project, access, and utility model", "\uE713"),
        new("Providers", "Connections and enabled models", "\uE950"),
        new("Voice", "Dictation model and language", "\uE720"),
        new("Keyboard Shortcuts", "Commands and project actions", "\uE765"),
        new("Projects", "Actions and new chat defaults", "\uE8B7"),
        new("Appearance", "Theme, accent, and materials", "\uE771"),
        new("Notifications", "Alerts, notification area, and sounds", "\uE7E7"),
        new("Terminal", "Docked terminal and agent CLIs", "\uE756"),
        new("Browser", "Search engine, tabs, passwords, and website data", "\uE909"),
        new("Runtime", "Local Codex connection", "\uE945"),
        new("Updates", "Version and release information", "\uE896"),
        new("Account", "Identity, usage, and limits", "\uE77B"),
        new("Integrations", "Skills, plugins, apps, and MCP", "\uE74C")
    ];
    sealed record Category(string Title, string Detail, string Glyph);

    readonly WorkspaceCoordinator workspace;
    readonly Func<string, bool> shortcutAvailable;
    readonly Func<bool, Task> setIncludeGPT56Models;
    readonly SolidColorBrush accentBrush = new();
    readonly List<(ListViewItem Item, Border Highlight, FontIcon Icon, TextBlock Label)> railItems = [];
    readonly List<(string Value, Button Button, Border Preview, TextBlock Label)> themeChoices = [];
    ShortcutSettingsPanel? shortcuts;

    public event Action? BackRequested;
    public bool IsCapturingShortcut => shortcuts?.IsCapturing == true;

    public SettingsPanel(WorkspaceCoordinator workspace, Func<string, bool> shortcutAvailable, Func<bool, Task> setIncludeGPT56Models)
    {
        this.workspace = workspace;
        this.shortcutAvailable = shortcutAvailable;
        this.setIncludeGPT56Models = setIncludeGPT56Models;
        InitializeComponent();
        foreach (var category in Navigation)
        {
            var icon = new FontIcon { Glyph = category.Glyph, Width = 18, Style = StyleFor("SettingIcon") };
            var label = new TextBlock
            {
                Text = category.Title, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center
            };
            var row = new Grid { ColumnSpacing = 10, Padding = new Thickness(10, 0, 10, 0) };
            row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new());
            row.Children.Add(icon);
            var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(label);
            var subtitle = SettingText(category.Detail, "SettingDetail");
            subtitle.FontSize = 11;
            subtitle.TextWrapping = TextWrapping.NoWrap;
            subtitle.TextTrimming = TextTrimming.CharacterEllipsis;
            text.Children.Add(subtitle);
            Grid.SetColumn(text, 1);
            row.Children.Add(text);
            var highlight = new Border
            {
                Style = (Style)Application.Current.Resources["RoundedSidebarHighlight"],
                Background = accentBrush, Opacity = 0, Margin = new Thickness(1)
            };
            var visuals = new Grid { MinHeight = 46, Children = { highlight, row } };
            var item = new ListViewItem { Content = visuals, Tag = category };
            AutomationProperties.SetName(item, category.Title);
            AutomationProperties.SetHelpText(item, category.Detail);
            AutomationProperties.SetAutomationId(item, "Settings_" + category.Title.Replace(" ", "", StringComparison.Ordinal));
            ToolTipService.SetToolTip(item, category.Detail);
            Categories.Items.Add(item);
            railItems.Add((item, highlight, icon, label));
        }
        ActualThemeChanged += (_, _) => RefreshPalette();
        SettingsScroll.SizeChanged += (_, args) =>
        {
            var inset = args.NewSize.Width < 520 ? 18 : 32;
            Document.Width = Math.Min(760, Math.Max(0, args.NewSize.Width - 12));
            Document.Padding = new Thickness(inset, 32, inset, 40);
        };
        Select("General");
        RefreshPalette();
    }

    public void Select(string? category)
    {
        category = category is "Continuation" ? "Account" : category;
        var index = Array.FindIndex(Navigation, item => item.Title == category);
        Categories.SelectedIndex = Math.Max(0, index);
    }

    public void SetWorkspaceWidth(double width, double sidebarWidth)
    {
        RailWidth.Width = new GridLength(Math.Min(sidebarWidth, Math.Max(156, width * 0.34)));
    }

    public void FocusCategory()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (Categories.SelectedItem is ListViewItem item && item.IsLoaded)
                item.Focus(FocusState.Programmatic);
            else if (IsLoaded)
                Categories.Focus(FocusState.Programmatic);
        });
    }

    public void RefreshPalette()
    {
        var p = workspace.Preferences;
        SettingsLayout.Background = WorkspaceAppearance.Region(this, p.CanvasMaterial, WorkspaceSurface.Canvas);
        SettingsRail.Background = WorkspaceAppearance.Region(this, p.SidebarMaterial, WorkspaceSurface.Sidebar);
        WorkspaceAppearance.ApplyAccent(this, p.Accent);
        accentBrush.Color = AccentColor(p.Accent);
        UpdateSelectionAppearance();
    }

    void Category_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (Categories.SelectedItem is not ListViewItem { Tag: Category category }) return;
        PageTitle.Text = category.Title;
        PageDetail.Text = category.Detail;
        Feedback.IsOpen = false;
        Sections.Children.Clear();
        themeChoices.Clear();
        shortcuts = null;
        UpdateSelectionAppearance();
        SettingsScroll.ChangeView(null, 0, null, disableAnimation: true);
        AutomationProperties.SetName(SettingsScroll, category.Title + " settings");

        switch (category.Title)
        {
            case "Providers": ShowProviders(); break;
            case "General": ShowGeneral(); break;
            case "Voice": ShowVoice(); break;
            case "Keyboard Shortcuts":
                shortcuts = new ShortcutSettingsPanel(App.Commands, shortcutAvailable);
                Sections.Children.Add(shortcuts);
                break;
            case "Projects":
                Sections.Children.Add(new ProjectsPanel(workspace, App.Projects, () => App.Main?.SelectedThread,
                    (path, action) => App.Main?.RunProjectActionAsync(path, action)
                        ?? Task.FromException(new InvalidOperationException("Open the Veo workspace first."))));
                break;
            case "Appearance": ShowAppearance(); break;
            case "Notifications": ShowNotifications(); break;
            case "Terminal": ShowTerminal(); break;
            case "Browser": ShowBrowser(); break;
            case "Runtime": ShowRuntime(); break;
            case "Updates": ShowUpdates(); break;
            case "Account": ShowAccount(); break;
            case "Integrations":
                Sections.Children.Add(new IntegrationsPanel(App.Integrations, App.Main?.SelectedThread,
                    uri => _ = App.Main?.NavigateBrowserAsync(uri)));
                break;
        }
    }

    void Back_Click(object sender, RoutedEventArgs e) => BackRequested?.Invoke();

    void ShowGeneral()
    {
        var p = workspace.Preferences;
        var router = Section("Auto router");
        AddRow(router, "Jev API key", "Used for first-turn Jev routing. Stored in Windows Credential Manager.", "\uE8D7",
            ActionButton("API key…", EditJevKeyAsync));

        var defaults = Section("Workspace defaults");
        AddRow(defaults, "New chat access", "Default filesystem access for new chats.", "\uEA18",
            Choice("New chat access", ComposerPermission.Options.Select(mode => mode.Title).ToArray(),
                ComposerPermission.Get(p.DefaultAccess).Title,
                title => p.DefaultAccess = ComposerPermission.Options.First(mode => mode.Title == title).Id));
        AddRow(defaults, "Group chats by project", "Organize the sidebar by workspace folder.", "\uE8B7",
            Toggle("Group chats by project", p.GroupByProject, v => p.GroupByProject = v));
        AddRow(defaults, "Show archived chats", "Include archived chats in the workspace catalog.", "\uE7B8",
            Toggle("Show archived chats", p.ShowArchived, v => p.ShowArchived = v));

        const string includeGPT56 = "Include GPT-5.6 models";
        var models = Section("Models");
        var include = new ToggleSwitch { IsOn = App.Models.IncludeGPT56Models, OffContent = "", OnContent = "", MinWidth = 0 };
        AutomationProperties.SetName(include, includeGPT56);
        AutomationProperties.SetAutomationId(include, SettingId(includeGPT56));
        include.IsEnabled = !include.IsOn || App.Models.CanDisableGPT56Models;
        var saving = false;
        include.Toggled += async (_, _) =>
        {
            if (saving) return;
            saving = true;
            include.IsEnabled = false;
            await RunAsync(() => setIncludeGPT56Models(include.IsOn));
            include.IsOn = App.Models.IncludeGPT56Models;
            include.IsEnabled = !include.IsOn || App.Models.CanDisableGPT56Models;
            saving = false;
        };
        AddRow(models, includeGPT56, "Show the GPT-5.6 family and 5.6 Auto in the composer picker.", "\uE8B7", include);

        var data = Section("Local data");
        AddRow(data, "Export settings", "Save a readable JSON file with your nonsecret preferences.", "\uE74E",
            ActionButton("Export…", ExportSettingsAsync));
    }

    async Task EditJevKeyAsync()
    {
        var key = new PasswordBox { Header = "Jev API key" };
        var dialog = new ContentDialog
        {
            Title = "Jev API key", Content = key, XamlRoot = XamlRoot,
            PrimaryButtonText = "Save key", SecondaryButtonText = "Remove key", CloseButtonText = "Cancel"
        };
        var result = await dialog.ShowAsync();
        var credentials = new Veo.Platform.Windows.Security.CredentialManager(workspace.DataRoot);
        if (result == ContentDialogResult.Primary)
        {
            if (string.IsNullOrWhiteSpace(key.Password)) throw new InvalidOperationException("Enter a Jev API key.");
            try { credentials.Save("Router/Jev", "api-key", key.Password); }
            finally { key.Password = ""; }
            ShowFeedback("Jev key saved.", InfoBarSeverity.Success);
        }
        else if (result == ContentDialogResult.Secondary)
        {
            credentials.Delete("Router/Jev", "api-key");
            ShowFeedback("Jev key removed.", InfoBarSeverity.Success);
        }
    }

    async Task ExportSettingsAsync()
    {
        var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = "Veo settings" };
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Main!));
        picker.FileTypeChoices.Add("JSON", [".json"]);
        if (await picker.PickSaveFileAsync() is { } file)
            await Windows.Storage.FileIO.WriteTextAsync(file, JsonSerializer.Serialize(workspace.Preferences, new JsonSerializerOptions { WriteIndented = true }));
    }

    void ShowNotifications()
    {
        var p = workspace.Preferences;
        var background = Section("While you’re away");
        AddRow(background, "Notification area icon", "Show Veo in the Windows notification area.", "\uE770",
            Toggle("Notification area icon", p.ShowTrayIcon, v => { p.ShowTrayIcon = v; App.ApplyTrayPreference(); }));
        AddRow(background, "Keep Veo running", "Allow Veo to stay active after closing its window.", "\uE8FD",
            Toggle("Keep Veo running", p.KeepRunningWhenClosed, v => p.KeepRunningWhenClosed = v));
        AddRow(background, "Turn and attention alerts", "Windows notification setting: " + App.NotificationPlatform.Setting, "\uE7E7",
            Toggle("Turn and attention alerts", p.Notifications, v => p.Notifications = v));
        AddRow(background, "Windows notification settings", "Manage system permissions for Veo alerts.", "\uE713",
            ActionButton("Open Settings", async () => await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:notifications"))));

        var sound = Section("Sound");
        AddRow(sound, "Completion sound", "Play a sound when a turn completes.", "\uE767",
            Toggle("Completion sound", p.CompletionSound, v => p.CompletionSound = v));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        actions.Children.Add(ActionButton("Import…", ImportSoundAsync));
        actions.Children.Add(ActionButton("Use default", () => SavePreferenceAsync(() => p.CompletionSoundPath = null)));
        AddRow(sound, "Custom sound", "Choose a WAV file or use the Windows default alert.", "\uE8D6", actions);
        if (App.NotificationPlatform.LastError is { } error) Sections.Children.Add(SettingText(error, "SettingDetail"));
    }

    async Task ImportSoundAsync()
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Main!));
        picker.FileTypeFilter.Add(".wav");
        if (await picker.PickSingleFileAsync() is not { } file) return;
        using (var reader = new NAudio.Wave.WaveFileReader(file.Path))
            if (reader.Length == 0) throw new InvalidDataException("The sound contains no samples.");
        var directory = Path.Combine(workspace.DataRoot, "Sounds");
        Directory.CreateDirectory(directory);
        var destination = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".wav");
        File.Copy(file.Path, destination);
        await SavePreferenceAsync(() => workspace.Preferences.CompletionSoundPath = destination);
        ShowFeedback("Completion sound imported.", InfoBarSeverity.Success);
    }

    void ShowTerminal()
    {
        var p = workspace.Preferences;
        var agents = Section("Agent CLIs");
        var allowAgents = Toggle("Agent CLIs", p.AgentClis, v => p.AgentClis = v);
        AddRow(agents, "Agent CLIs", "Allow launching Codex and Claude in Veo-managed terminals.", "\uE756", allowAgents);
        agents.Children.Add(new Border
        {
            Child = SettingText("Veo asks for consent when Agent CLIs are off.", "SettingDetail"),
            Padding = new Thickness(52, 0, 16, 12)
        });
        var access = new StackPanel { Visibility = p.AgentClis ? Visibility.Visible : Visibility.Collapsed };
        AddRow(access, "Full access for Codex", "Launch Codex in Veo’s terminal with its sandbox and approval prompts disabled.", "\uEA18",
            Toggle("Full access for Codex", p.CodexFullAccess, v => p.CodexFullAccess = v));
        AddRow(access, "Full access for Claude", "Launch Claude in Veo’s terminal with its permission prompts disabled.", "\uEA18",
            Toggle("Full access for Claude", p.ClaudeFullAccess, v => p.ClaudeFullAccess = v));
        agents.Children.Add(access);
        allowAgents.Toggled += (_, _) => access.Visibility = allowAgents.IsOn ? Visibility.Visible : Visibility.Collapsed;
    }

    void ShowBrowser()
    {
        var p = workspace.Preferences;
        AddRow(Section("Search"), "Search engine", "Use this provider for searches from the address bar and start page.", "\uE721",
            Choice("Search engine", ["Google", "ChatGPT", "DuckDuckGo", "Bing", "Kagi", "Brave", "Ecosia"], p.SearchEngine, v => p.SearchEngine = v));
        AddRow(Section("Tabs"), "Restore browser tabs", "Reopen the previous browser tabs when Veo launches.", "\uE8A7",
            Toggle("Restore browser tabs", p.RestoreBrowserTabs, v => p.RestoreBrowserTabs = v));
        AddRow(Section("Passwords"), "Password and form AutoFill", "Allow WebView2 to fill saved sign-in and form details.", "\uE8D7",
            Toggle("Password and form AutoFill", p.BrowserAutoFill, v => p.BrowserAutoFill = v));
        var web = Section("Web content");
        AddRow(web, "JavaScript", "Allow scripts to run on websites opened in Veo.", "\uE943",
            Toggle("JavaScript", p.JavaScript, v => p.JavaScript = v));
        AddRow(web, "Fraudulent website warning", "Show WebView2 warnings for suspected unsafe websites.", "\uEA18",
            Toggle("Fraudulent website warning", p.BrowserFraudWarning, v => p.BrowserFraudWarning = v));
    }

    void ShowRuntime()
    {
        var p = workspace.Preferences;
        var connection = Section("Local connection");
        var runtimeState = SettingText("", "SettingDetail");
        var diagnostics = new TextBox
        {
            Text = workspace.Runtime.DiagnosticTail, IsReadOnly = true, AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap, MaxHeight = 200
        };
        var executable = new TextBox
        {
            Text = p.CodexExecutable ?? workspace.Runtime.ExecutablePath ?? "", TextWrapping = TextWrapping.Wrap
        };
        AutomationProperties.SetName(executable, "Codex executable path");
        var executableEditor = new StackPanel { Spacing = 8 };
        executableEditor.Children.Add(executable);
        executableEditor.Children.Add(ActionButton("Choose executable…", async () =>
        {
            var picker = new Windows.Storage.Pickers.FileOpenPicker();
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Main!));
            picker.FileTypeFilter.Add(".exe");
            if (await picker.PickSingleFileAsync() is { } file) executable.Text = file.Path;
        }));
        executableEditor.Children.Add(ActionButton("Save and reconnect", async () =>
        {
            await SavePreferenceAsync(() => p.CodexExecutable = executable.Text);
            await ReconnectAsync();
        }));
        AddRow(connection, "Codex executable", "Veo starts the locally installed CLI through standard input and output.", "\uE756", executableEditor, fullWidth: true);
        AddRow(connection, "Runtime connection", null, "\uE945", ActionButton("Reconnect", ReconnectAsync));
        AutomationProperties.SetName(diagnostics, "Local diagnostics");
        AddRow(Section("Diagnostics"), "Local diagnostics", null, "\uE9D9", diagnostics, fullWidth: true);
        AddEmbedded("Runtime management", new RuntimeManagementPanel(App.RuntimeManagement, App.Main?.SelectedThread));
        ApplyRuntimeState();

        async Task ReconnectAsync()
        {
            ShowFeedback("Reconnecting to Codex…", InfoBarSeverity.Informational);
            await workspace.ReconnectAsync();
            ApplyRuntimeState();
            Feedback.IsOpen = false;
        }
        void ApplyRuntimeState()
        {
            var methodCount = workspace.Runtime.Capabilities.Methods(Veo.Protocol.ProtocolDirection.ClientRequest).Count;
            runtimeState.Text = $"{workspace.Runtime.State} · generation {workspace.Runtime.Generation} · {methodCount} client methods";
            diagnostics.Text = workspace.Runtime.DiagnosticTail;
        }
        connection.Children.Add(new Border { Child = runtimeState, Padding = new Thickness(52, 0, 16, 12) });
    }

    void ShowUpdates()
    {
        var version = typeof(SettingsPanel).Assembly.GetName().Version?.ToString() ?? "";
        AddRow(Section("Software update"), "Installed version", version, "\uE896",
            ActionButton("View releases", async () =>
                await Windows.System.Launcher.LaunchUriAsync(new Uri("https://github.com/itsasheruwu/Veo/releases"))));
    }

    void ShowAccount()
    {
        var identity = Section("Codex account");
        var summary = new StackPanel { Spacing = 10 };
        AddRow(identity, "Local Codex account", "Sign in through Veo’s browser using the local Codex CLI.", "\uE77B",
            ActionButton("Sign in", () => workspace.LoginAsync("chatgpt")));
        AddRow(identity, "Account and usage", "Refresh identity and limits from the active Codex runtime.", "\uE9D9",
            ActionButton("Refresh", async () => { await workspace.RefreshAccountAsync(); PopulateAccount(summary); }));
        identity.Children.Add(new Border { Child = summary, Padding = new Thickness(16, 0, 16, 12) });
        PopulateAccount(summary);
        AddEmbedded("Usage-limit continuation", new ContinuationPanel(workspace, App.Continuation, App.QuietWake)
            { MinWidth = 0 });

    }

    void PopulateAccount(StackPanel summary)
    {
        summary.Children.Clear();
        var account = workspace.Account;
        if (account.ValueKind != JsonValueKind.Object) return;
        var text = account.TryGetProperty("account", out var detail) && detail.ValueKind == JsonValueKind.Object
            ? string.Join("\n", detail.EnumerateObject().Where(x => x.Value.ValueKind is JsonValueKind.String or JsonValueKind.Number)
                .Select(x => x.Name + ": " + x.Value))
            : "No signed-in account reported by Codex.";
        var accountText = SettingText(text, "SettingDetail");
        accountText.IsTextSelectionEnabled = true;
        summary.Children.Add(accountText);
        if (workspace.RateLimits.ValueKind == JsonValueKind.Object)
            summary.Children.Add(new TextBox
            {
                Header = "Reported usage limits", Text = JsonSerializer.Serialize(workspace.RateLimits, new JsonSerializerOptions { WriteIndented = true }),
                IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 180
            });
    }
}
