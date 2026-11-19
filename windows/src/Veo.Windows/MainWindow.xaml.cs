using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.Graphics;
namespace Veo_Windows;
public sealed partial class MainWindow : Window
{
    MainPage? Page => RootFrame.Content as MainPage;
    public string PendingActivation { get; set; } = "";
    public Veo.Core.ThreadSession? SelectedThread => Page?.CurrentThread;
    public bool IsActive { get; private set; }
    Services.WindowBoundsCoordinator? bounds;
    public MainWindow()
    {
        Services.StartupDiagnostics.Record("MainWindow XAML loading");
        InitializeComponent(); Services.StartupDiagnostics.Record("MainWindow XAML loaded"); ExtendsContentIntoTitleBar = true; SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = Microsoft.UI.Windowing.TitleBarHeightOption.Standard;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        AppWindow.Resize(new SizeInt32(1380, 900));
        RootFrame.NavigationFailed += (_, args) => Services.StartupDiagnostics.Record("Frame navigation failed: " + args.SourcePageType?.FullName, args.Exception);
        Services.StartupDiagnostics.Record("MainPage navigation starting");
        var navigated = RootFrame.Navigate(typeof(MainPage), null, new SuppressNavigationTransitionInfo());
        Services.StartupDiagnostics.Record("MainPage navigation returned " + navigated);
        if (Page is { } page)
        {
            page.SidebarLayoutChanged += UpdateSidebarToggle;
            page.ToolbarContextChanged += UpdateTitleBarCommands;
        }
        SidebarToggleSlot.SizeChanged += (_, _) => AppTitleBar.RecomputeDragRegions();
        ToolbarCommands.SizeChanged += (_, _) => AppTitleBar.RecomputeDragRegions();
        AppTitleBar.ActualThemeChanged += (_, _) => ApplyCaptionTheme();
        ApplyCaptionTheme();
        Activated += (_, args) => IsActive = args.WindowActivationState != WindowActivationState.Deactivated;
    }
    void ApplyCaptionTheme()
    {
        var caption = AppWindow.TitleBar;
        if (new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast)
        {
            caption.ButtonForegroundColor = caption.ButtonInactiveForegroundColor = null;
            return;
        }
        var dark = AppTitleBar.ActualTheme == ElementTheme.Dark;
        var foreground = dark ? (byte)232 : (byte)32;
        var inactive = dark ? (byte)160 : (byte)104;
        caption.ButtonForegroundColor = Windows.UI.Color.FromArgb(255, foreground, foreground, foreground);
        caption.ButtonInactiveForegroundColor = Windows.UI.Color.FromArgb(255, inactive, inactive, inactive);
    }
    void UpdateSidebarToggle(double width, bool visible)
    {
        SidebarToggleSlot.Width = Math.Max(102, width);
        var label = visible ? "Hide sidebar" : "Show sidebar";
        ToolTipService.SetToolTip(SidebarToggle, label);
        AutomationProperties.SetName(SidebarToggle, label);
    }
    void UpdateTitleBarCommands()
    {
        var workspaceVisible = Page?.IsShowingSettings != true;
        ToolbarCommands.Visibility = SidebarToggle.Visibility = workspaceVisible ? Visibility.Visible : Visibility.Collapsed;
        if (!workspaceVisible) return;
        var thread = SelectedThread;
        TemporaryChatButton.Visibility = thread?.CanToggleTemporaryChat == true ? Visibility.Visible : Visibility.Collapsed;
        var isTemporary = thread?.Record.WorkspaceKind == "temporary";
        TemporaryChatButton.IsChecked = isTemporary;
        var temporaryLabel = isTemporary ? "Temporary chat on" : "Make this chat temporary";
        AutomationProperties.SetName(TemporaryChatButton, temporaryLabel);
        ToolTipService.SetToolTip(TemporaryChatButton, temporaryLabel);
        ProjectActionsButton.IsEnabled = thread?.Record.WorkspaceKind == "project";
    }
    void Sidebar_Click(object sender, RoutedEventArgs e) => Page?.ToggleSidebar();
    async void TemporaryChat_Click(object sender, RoutedEventArgs e)
    {
        if (Page is { } page) await page.ToggleTemporaryChatAsync();
        UpdateTitleBarCommands();
    }
    async void ProjectActions_Click(object sender, RoutedEventArgs e)
    {
        if (Page is { } page && sender is FrameworkElement anchor) await page.ShowProjectActionsAsync(anchor);
    }
    async void NewChat_Click(object sender, RoutedEventArgs e) { if (Page is { } page) await page.NewChatAsync(); }
    void Reveal_Click(object sender, RoutedEventArgs e) => Page?.RevealProject();
    void Inspector_Click(object sender, RoutedEventArgs e) => Page?.ToggleInspector();
    async void Terminal_Click(object sender, RoutedEventArgs e) { if (Page is { } page) await page.ShowTerminalAsync(); }
    public void RestorePreferences() { bounds = new(this, App.Workspace); bounds.Restore(); }
    public async Task DisposeSurfacesAsync()
    {
        try { if (bounds is not null) await bounds.DisposeAsync(); }
        finally { if (Page is { } page) await page.DisposeSurfacesAsync(); }
    }
    public Task NavigateToThreadAsync(Veo.Core.ThreadSession session) => Page?.NavigateToThreadAsync(session) ?? Task.CompletedTask;
    public Task QuoteIntoComposerAsync(Veo.Core.QuoteReference reference, string text) => Page?.QuoteIntoComposerAsync(reference, text) ?? Task.CompletedTask;
    public Task HandleActivationAsync(string arguments) => Page?.HandleActivationAsync(arguments) ?? Task.CompletedTask;
    public Task NavigateBrowserAsync(Uri uri) => Page?.OpenBrowserAsync(uri) ?? Task.CompletedTask;
    public Task NavigateQuoteAsync(Veo.Core.QuoteReference reference) => Page?.NavigateQuoteAsync(reference) ?? Task.CompletedTask;
    public Task NavigateThreadIdAsync(string id) { AppWindow.Show(); Activate(); return Page?.NavigateThreadIdAsync(id) ?? Task.CompletedTask; }
    public Task CreateChatAsync() => Page?.NewChatAsync() ?? Task.CompletedTask;
    public Task ShowSettingsAsync() => Page?.OpenSettingsAsync() ?? Task.CompletedTask;
    public Task RunProjectActionAsync(string path, Veo.Infrastructure.Projects.ProjectAction action) =>
        Page?.RunProjectActionAsync(path, action) ?? Task.FromException(new InvalidOperationException("Open the Veo workspace first."));
    public void RefreshAppearance() => Page?.RefreshAppearance();
    async void Voice_Click(object sender, RoutedEventArgs e) { if (Page is { } page) await page.ShowVoiceAsync(); }
    async void Prompts_Click(object sender, RoutedEventArgs e) { if (Page is { } page) await page.ShowPromptLibraryAsync(); }
    async void PullRequests_Click(object sender, RoutedEventArgs e) { if (Page is { } page) await page.ShowPullRequestsAsync(); }
    async void Catalog_Click(object sender, RoutedEventArgs e) { if (Page is { } page) await page.ShowCatalogAsync(); }
    async void History_Click(object sender, RoutedEventArgs e) { if (Page is { } page) await page.ShowHistoryAsync(); }
    async void Worktrees_Click(object sender, RoutedEventArgs e) { if (Page is { } page) await page.ShowWorktreesAsync(); }
    async void Checkpoints_Click(object sender, RoutedEventArgs e) { if (Page is { } page) await page.ShowCheckpointsAsync(); }
    async void Queue_Click(object sender, RoutedEventArgs e) { if (Page is { } page) await page.ShowQueueAsync(); }
}
