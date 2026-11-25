using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Veo.Core;
using Veo.Protocol;
using Veo_Windows.Controls;
using Veo_Windows.Services;
using Veo_Windows.ViewModels;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI.Core;

namespace Veo_Windows;

public sealed partial class MainPage : Page
{
    readonly WorkspaceCoordinator workspace = App.Workspace;
    readonly ObservableCollection<MessageRow> messages = [];
    readonly List<string> attachments = [];
    TerminalPanel? terminalPanel;
    BrowserPanel? browser;
    FilesPanel? files;
    GitReviewPanel? review;
    ThreadSession? current;
    public ThreadSession? CurrentThread => current;
    string? model;
    string? modelCatalogId;
    string? effort;
    string? tier;
    bool? composerDaybreak;
    long? contextTokens;
    string routingMode = "Direct";
    AutoRouterPolicy? routerPolicy;
    FamilyAutoPlan? familyPlan;
    bool loading;
    bool initialized;
    bool updatingCatalog;
    int catalogRefreshRevision;
    ChatRow[] visibleCatalogRows = [];
    bool imeComposing;
    bool viewReady, applyingAppearance;
    readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    string pendingSignature = "";
    string queueSignature = "";
    string presentationSignature = "";
    CancellationTokenSource? draftDelay;
    CancellationTokenSource? searchDelay;
    readonly Windows.UI.ViewManagement.UISettings systemUi = new();
    Microsoft.UI.System.ThemeSettings? themeSettings;
    public MainPage()
    {
        InitializeComponent(); InitializeUtilityLayout(); InitializeComposerControls(); viewReady = true; Timeline.ItemsSource = messages;
        Composer.TextCompositionStarted += (_, _) => { imeComposing = true; CloseCompletions(); };
        Composer.TextCompositionEnded += (_, _) => { imeComposing = false; _ = RefreshCompletionsAsync(); };
        ActualThemeChanged += (_, _) => ApplyTheme();
        systemUi.AdvancedEffectsEnabledChanged += SystemEffectsChanged;
        workspace.Changed += () => DispatcherQueue.TryEnqueue(Render);
        App.Questions.Changed += () => DispatcherQueue.TryEnqueue(Render);
        App.Routing.Changed += () => DispatcherQueue.TryEnqueue(Render);
        App.ThreadSettings.Changed += () => DispatcherQueue.TryEnqueue(RenderComposerGoalControls);
        workspace.OpenBrowser += uri => DispatcherQueue.TryEnqueue(async () => await OpenBrowserAsync(uri));
        Loaded += async (_, _) =>
        {
            if (initialized) return; initialized = true;
            await Run(async () =>
            {
                Task? firstRunTour = null;
                await workspace.InitializeAsync(() =>
                {
                    if (workspace.Preferences.WorkspaceTourStep < VeoPreferences.TourCompleted)
                        firstRunTour = Run(ShowTourAsync);
                });
                await Run(InitializeShortcutsAsync);
                themeSettings = Microsoft.UI.System.ThemeSettings.CreateForWindowId(XamlRoot.ContentIslandEnvironment.AppWindowId);
                themeSettings.Changed += ThemeSettingsChanged;
                RestoreUtilityLayout();
                await App.Catalog.InitializeAsync();
                if (workspace.Runtime.RuntimeState == CodexRuntimeState.Ready) await App.Models.RefreshAsync();
                workspace.PreparePayloadAsync = App.Routing.PrepareAsync;
                await App.Continuation.InitializeAsync();
                await App.QuietWake.InitializeAsync();
                await App.Voice.InitializeAsync();
                App.ApplyTrayPreference();
                ApplyTheme(); await RefreshCatalogAsync();
                var catalog = await workspace.CatalogAsync();
                if (catalog.FirstOrDefault(x => x.VeoId == workspace.Preferences.SelectedThread) is { } selected) await SelectAsync(await workspace.LoadAsync(selected));
                else if (catalog.Count > 0) await SelectAsync(await workspace.LoadAsync(catalog[0]));
                else await NewChatAsync();
                ready.TrySetResult();
                if (firstRunTour is not null) await firstRunTour;
                await ShowModelPickerUpgradeAsync();
                if (App.Main is { PendingActivation.Length: > 0 } main) await HandleActivationAsync(main.PendingActivation);
                if (App.PendingNotificationThread is { } notificationThread) await NavigateThreadIdAsync(notificationThread);
            });
            ready.TrySetResult();
        };
        SizeChanged += (_, _) => ApplyWorkspaceWidth();
        AddAccelerator(VirtualKey.I, VirtualKeyModifiers.Control | VirtualKeyModifiers.Menu, ToggleUtilityPanelAsync);
    }
    void SystemEffectsChanged(Windows.UI.ViewManagement.UISettings sender, object args) => DispatcherQueue.TryEnqueue(ApplyTheme);
    void ThemeSettingsChanged(Microsoft.UI.System.ThemeSettings sender, object args) => DispatcherQueue.TryEnqueue(ApplyTheme);
    void ApplyTheme()
    {
        if (!viewReady || applyingAppearance) return;
        applyingAppearance = true;
        try
        {
        if (App.Main?.Content is FrameworkElement root) { root.RequestedTheme = workspace.Preferences.Appearance switch { "Light" => ElementTheme.Light, "Dark" => ElementTheme.Dark, _ => ElementTheme.Default }; Services.WorkspaceAppearance.ApplyAccent(root, workspace.Preferences.Accent); }
        Shell.Background = WorkspaceAppearance.Region(this, workspace.Preferences.CanvasMaterial, WorkspaceSurface.Canvas);
        SidebarPanel.Background = WorkspaceAppearance.Region(this, workspace.Preferences.SidebarMaterial, WorkspaceSurface.Sidebar);
        UtilityPanel.Background = WorkspaceAppearance.Region(this, workspace.Preferences.UtilityMaterial, WorkspaceSurface.Utility);
        ComposerPanel.Background = WorkspaceAppearance.Region(this, workspace.Preferences.ComposerMaterial, WorkspaceSurface.Composer);
        Notice.Background = WorkspaceAppearance.Region(this, workspace.Preferences.NotificationMaterial, WorkspaceSurface.Notice);
        settingsPanel?.RefreshPalette();
        }
        finally { applyingAppearance = false; }
    }
    public void RefreshAppearance() { ApplyTheme(); presentationSignature = ""; Render(); }
    public Task NewChatAsync() => Run(async () => { await SaveDraftNowAsync(); await SelectAsync(await workspace.CreateAsync()); await RefreshCatalogAsync(); });
    async Task OpenProjectAsync()
    {
        if (await PickProjectFolderAsync() is { } folder) await CreateProjectChatAsync(folder);
    }
    async Task<string?> PickProjectFolderAsync()
    {
        var picker = new Microsoft.Windows.Storage.Pickers.FolderPicker(App.Main!.AppWindow.Id);
        return (await picker.PickSingleFolderAsync())?.Path;
    }
    async Task SelectAsync(ThreadSession session)
    {
        CancelDictation();
        DictationError.IsOpen = false;
        composerModelFlyout?.Hide();
        CloseComposerPill();
        ShowWorkspace();
        loading = true;
        try
        {
            current = session; messages.Clear(); attachments.Clear(); pendingSignature = ""; queueSignature = "";
            ApprovalReviewHost.Content = new ApprovalReviewsPanel(App.RuntimeManagement, session);
            RestoreComposerDraft(session);
            model = workspace.Models.FirstOrDefault()?.Id; effort = workspace.Models.FirstOrDefault()?.DefaultEffort; tier = null;
            modelCatalogId = model;
            contextTokens = null; routingMode = "Direct"; routerPolicy = null; familyPlan = null; composerDaybreak = null;
            if (App.Models.Catalog.Count > 0) ApplyModelChoice(await App.Models.ResolveAsync(session));
            using var options = JsonDocument.Parse(session.Draft.OptionsJson);
            model = options.RootElement.Str("model") ?? model; effort = options.RootElement.Str("effort") ?? effort; tier = options.RootElement.Str("tier");
            modelCatalogId = options.RootElement.Str("modelCatalogId") ?? model;
            if (options.RootElement.TryGetProperty("contextTokens", out var tokens) && tokens.ValueKind == JsonValueKind.Number && tokens.TryGetInt64(out var count)) contextTokens = count;
            routingMode = options.RootElement.Str("routingMode") ?? routingMode;
            if (options.RootElement.TryGetProperty("routerPolicy", out var policy) && policy.ValueKind == JsonValueKind.Object) routerPolicy = policy.Deserialize<AutoRouterPolicy>();
            if (options.RootElement.TryGetProperty("familyPlan", out var family) && family.ValueKind == JsonValueKind.Object) familyPlan = family.Deserialize<FamilyAutoPlan>();
            if (options.RootElement.TryGetProperty("daybreak", out var daybreak)) composerDaybreak = daybreak.ValueKind switch
            {
                JsonValueKind.True => true, JsonValueKind.False => false, _ => null
            };
            composerAccess = options.RootElement.Str("access") ?? workspace.Preferences.DefaultAccess;
            composerMode = options.RootElement.Str("mode") ?? "Agentic";
            workspace.Preferences.SelectedThread = session.Record.VeoId; await workspace.SavePreferencesAsync();
            await App.Plans.ObserveAsync(session); await App.Questions.ObserveAsync(session);
            await App.Routing.ObserveAsync(session);
            await ReconcileGPT56OptInAsync(session);
            await ShowUtilityAsync(); Render();
        }
        finally
        {
            loading = false;
            UpdateDictationControl();
            SyncCatalogSelection();
        }
    }
    async Task RefreshCatalogAsync()
    {
        var revision = ++catalogRefreshRevision;
        var query = SearchBox.Visibility == Visibility.Visible ? SearchBox.Text.Trim() : "";
        var groupByProject = workspace.Preferences.GroupByProject;
        SidebarCatalogLabel.Text = workspace.Preferences.ShowArchived ? "Archived" : "Chats";
        var catalog = await App.Catalog.LoadAsync();
        var rows = catalog.Veo.Concat(catalog.Codex).Where(x => query.Length == 0
            || (x.Thread.Title + "\n" + x.Thread.Preview + "\n" + x.Thread.Cwd).Contains(query, StringComparison.OrdinalIgnoreCase)).Select(x => new ChatRow(x)).ToArray();
        var projectPaths = groupByProject
            ? await App.Projects.RegisteredProjectPathsAsync(rows.Select(row => row.Record.Cwd)) : null;
        if (revision != catalogRefreshRevision) return;
        updatingCatalog = true;
        try
        {
            if (groupByProject)
            {
                var groups = new[] { CatalogOrigin.Veo, CatalogOrigin.Codex }.SelectMany(origin => App.Catalog.Group(rows.Where(x => x.Entry.Origin == origin).Select(x => x.Entry), projectPaths)
                    .Select(group =>
                    {
                        var projectless = group.Entries.All(x => x.Thread.WorkspaceKind is "scratch" or "temporary");
                        var label = (origin == CatalogOrigin.Codex ? "Codex CLI · " : "") + (projectless ? "Projectless Chats" : group.Label);
                        return new ChatGroup(label, group.ProjectPath, origin, projectless, group.IsCollapsed,
                            group.IsCollapsed ? [] : group.Entries.Select(x => new ChatRow(x)));
                    })).ToArray();
                visibleCatalogRows = groups.SelectMany(group => group).ToArray();
                GroupedChats.Source = groups;
                ChatList.ItemsSource = GroupedChats.View;
            }
            else { visibleCatalogRows = rows; ChatList.ItemsSource = rows; }
        }
        finally { updatingCatalog = false; }
        SyncCatalogSelection();
    }
    void SyncCatalogSelection()
    {
        var selected = current?.Record.VeoId ?? workspace.Preferences.SelectedThread;
        var runtimeId = current?.Record.CodexThreadId;
        var row = visibleCatalogRows.FirstOrDefault(x => x.Record.VeoId == selected ||
            runtimeId is not null && x.Entry.Origin == CatalogOrigin.Codex && x.Record.CodexThreadId == runtimeId);
        var wasUpdating = updatingCatalog;
        updatingCatalog = true;
        try { if (!ReferenceEquals(ChatList.SelectedItem, row)) ChatList.SelectedItem = row; }
        finally { updatingCatalog = wasUpdating; }
    }
    void Render()
    {
        ToolbarContextChanged?.Invoke();
        RuntimeLabel.Text = workspace.Status == "Connected · local stdio" ? "Local runtime ready" : workspace.Status;
        if (ToolTipService.GetToolTip(RuntimeLabel) as string != workspace.Status)
            ToolTipService.SetToolTip(RuntimeLabel, workspace.Status);
        ReadyRuntimeDot.Visibility = workspace.Runtime.RuntimeState == CodexRuntimeState.Ready ? Visibility.Visible : Visibility.Collapsed;
        if (current is null) return;
        ChatTitle.Text = current.Record.Title; CwdLabel.Text = current.Record.Cwd;
        StopButton.Visibility = current.Timeline.IsRunning ? Visibility.Visible : Visibility.Collapsed;
        RenderFollowUpSend(current);
        RenderContextIndicator(current);
        UpdateSendAvailability();
        RenderComposerControls();
        UpdateConversationRows(current);
        if (current.DispatchWarning is { } warning) { Notice.Message = warning; Notice.IsOpen = true; }
        else if (App.Routing.Notice(current) is { } routingNotice) { Notice.Severity = InfoBarSeverity.Informational; Notice.Message = routingNotice; Notice.IsOpen = true; }
        RenderPending(); RenderQueue(); UpdateConversationChrome();
    }
    void RenderPending()
    {
        var pending = workspace.PendingRequests.Where(x => x.Parameters.Str("threadId") is not { } id || id == current?.Record.CodexThreadId).ToArray();
        var asyncQuestions = current is null ? [] : App.Questions.Pending(current.Record.VeoId);
        var signature = string.Join("|", pending.Select(x => x.Generation + ":" + x.Id!.Value.GetRawText())) + ":" + string.Join("|", asyncQuestions.Select(x => x.Key)); if (signature == pendingSignature) return; pendingSignature = signature;
        PendingPanel.Children.Clear();
        foreach (var request in pending)
        {
            if (request.Method == "mcpServer/elicitation/request") { PendingPanel.Children.Add(new McpElicitationPanel(App.Integrations, request)); continue; }
            if (request.Method == "item/tool/requestUserInput" && current is not null) { PendingPanel.Children.Add(new QuestionPanel(App.Questions, current, request)); continue; }
            var panel = new StackPanel { Spacing = 8 };
            var method = request.Method ?? ""; var p = request.Parameters;
            if (method is "item/commandExecution/requestApproval" or "item/fileChange/requestApproval")
            {
                panel.Children.Add(new TextBlock { Text = method.Contains("commandExecution") ? "Allow this command?" : "Allow these file changes?", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
                panel.Children.Add(new TextBlock { Text = p.Str("command") ?? p.Str("reason") ?? "Codex requests approval for the current item.", TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
                var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                foreach (var choice in new[] { ("Allow once", "accept"), ("Allow for session", "acceptForSession"), ("Deny", "decline") })
                { var button = new Button { Content = choice.Item1 }; button.Click += async (_, _) => await Run(() => workspace.RespondAsync(request, new { decision = choice.Item2 })); buttons.Children.Add(button); }
                panel.Children.Add(buttons);
            }
            else if (method == "item/tool/requestUserInput" && p.TryGetProperty("questions", out var questions))
            {
                var answers = new Dictionary<string, TextBox>();
                foreach (var question in questions.EnumerateArray())
                {
                    var id = question.Str("id")!; panel.Children.Add(new TextBlock { Text = question.Str("question"), TextWrapping = TextWrapping.Wrap });
                    var answer = new TextBox { PlaceholderText = "Your answer", AcceptsReturn = true }; answers[id] = answer;
                    if (question.TryGetProperty("options", out var choices) && choices.ValueKind == JsonValueKind.Array)
                        foreach (var option in choices.EnumerateArray())
                        { var button = new Button { Content = option.Str("label") }; var label = option.Str("label")!; button.Click += (_, _) => answer.Text = label; panel.Children.Add(button); }
                    panel.Children.Add(answer);
                }
                var send = new Button { Content = "Send answers" }; send.Click += async (_, _) => await Run(() => workspace.RespondAsync(request, new { answers = answers.ToDictionary(x => x.Key, x => new { answers = new[] { x.Value.Text } }) })); panel.Children.Add(send);
            }
            else
            {
                panel.Children.Add(new TextBlock { Text = "Codex requested an action that has no Windows handler: " + method, TextWrapping = TextWrapping.Wrap });
                var reject = new Button { Content = "Decline unsupported request" }; reject.Click += async (_, _) => await Run(() => workspace.RejectUnsupportedAsync(request)); panel.Children.Add(reject);
            }
            PendingPanel.Children.Add(panel);
        }
        if (current is not null)
            foreach (var question in asyncQuestions) PendingPanel.Children.Add(new QuestionPanel(App.Questions, current, question, SettingsSnapshot));
    }
    Task SaveDraftNowAsync() => SaveTypedComposerAsync();
    Task SubmitAsync() => DictationActive ? Task.CompletedTask : SubmitTypedComposerAsync();
    async Task<bool> ExecuteCommandAsync(string invocation)
    {
        var split = invocation[1..].Split(' ', 2); var command = split[0].ToLowerInvariant(); var argument = split.Length > 1 ? split[1] : "";
        switch (command)
        {
            case "new": case "clear": await NewChatAsync(); return true;
            case "rename" when current is not null: await RenameAsync(argument); return true;
            case "temporary" when current is not null: await workspace.ToggleTemporaryChatAsync(current); return true;
            case "archive" when current is not null: await workspace.SetArchivedAsync(current, true); await NewChatAsync(); return true;
            case "delete" when current is not null: await DeleteCurrentAsync(); return true;
            case "model": case "reasoning": Model_Click(ModelTrigger, new RoutedEventArgs()); return true;
            case "permissions": ShowComposerAccess(); return true;
            case "mention": await ChooseFileMentionAsync(); return true;
            case "agentic": await SetComposerModeAsync("Agentic"); return true;
            case "goal" when current is { } goalSession:
                await App.ThreadSettings.SetComposerGoalModeAsync(goalSession, true);
                if (argument.Length == 0) return true;
                if (!ReferenceEquals(current, goalSession)) return true;
                Composer.Text = argument;
                return false;
            case "plan" when argument.Length == 0: await SetComposerModeAsync("Plan"); return true;
            case "debug" when argument.Length == 0: await SetComposerModeAsync("Debug"); return true;
            case "terminal": await ToggleTerminalAsync(); return true;
            case "voice": await ShowVoiceAsync(); return true;
            case "browser": await ShowSettingsAsync("Browser"); return true;
            case "appearance": await ShowSettingsAsync("Appearance"); return true;
            case "runtime": case "status": await ShowSettingsAsync("Runtime"); return true;
            case "usage": await ShowSettingsAsync("Account"); return true;
            case "skills": case "apps": case "mcp": case "plugins": await ShowSettingsAsync("Integrations"); return true;
            case "btw" when current is { } sideThread:
                await OpenUtilityPanelAsync(3);
                if (argument.Length > 0 && ReferenceEquals(current, sideThread)) _ = SideChat().SubmitAsync(argument);
                return true;
            case "diff": case "review": inspectedTurn = null; await OpenUtilityPanelAsync(0); return true;
            case "stop" when current is not null: if (!Agents.Stop(current.Record.VeoId)) await workspace.StopAsync(current); return true;
            case "reconnect": await workspace.ReconnectAsync(); return true;
            case "refresh": await RefreshCatalogAsync(); return true;
            case "reveal": RevealProject(); return true;
            case "copy": var clipboard = new DataPackage(); clipboard.SetText(current?.Timeline.Items.LastOrDefault(x => x.Kind == "agentMessage")?.Text ?? ""); Clipboard.SetContent(clipboard); return true;
            case "compact" when current?.Record.CodexThreadId is { } threadId: await workspace.InspectAsync("thread/compact/start", new { threadId }); return true;
            case "fork": await ShowHistoryAsync(); return true;
            default: return false;
        }
    }
    SideChatPanel? sideChat;
    SideChatPanel SideChat() => sideChat ??= new SideChatPanel(
        (session, question, previous) => App.Routing.AnswerSideQuestionAsync(session, routerPolicy, modelCatalogId, question, previous),
        async (session, text) =>
        {
            if (current?.Record.VeoId != session.Record.VeoId) return;
            InsertAtComposerCaret(text);
            await SaveTypedComposerAsync();
            Composer.Focus(FocusState.Programmatic);
        });

    async Task ShowUtilityAsync()
    {
        if (current is null || UtilityHost is null) return;
        switch (UtilityTabs.SelectedIndex)
        {
            case 1: browser ??= new(workspace); UtilityHost.Content = browser; await browser.LoadAsync(current); break;
            case 2: files ??= new(workspace); UtilityHost.Content = files; await files.LoadAsync(current); break;
            case 3: var side = SideChat(); UtilityHost.Content = side; side.Show(current); break;
            default:
                if (inspectedTurn is { } turn) { UtilityHost.Content = HistoricalDiffPanel(turn); break; }
                review ??= CreateReviewPanel(); UtilityHost.Content = review; await review.LoadAsync(current); break;
        }
    }
    async Task ToggleTerminalAsync()
    {
        if (current is null) return;
        if (TerminalHeight.Height.Value > 0) { ApplyTerminalExpansion(false); TerminalHeight.Height = new GridLength(0); UpdateConversationChrome(); return; }
        if (terminalPanel is null)
        {
            terminalPanel = new(workspace);
            terminalPanel.AddSelectionToChat += text => _ = Run(() => AddTerminalSelectionToComposerAsync(text));
            terminalPanel.ExpandedChanged += ApplyTerminalExpansion;
        }
        TerminalHost.Content = terminalPanel; TerminalHeight.Height = new GridLength(250); UpdateConversationChrome(); await terminalPanel.OpenAsync(current);
    }
    void ApplyTerminalExpansion(bool expanded)
    {
        TimelineHeight.Height = expanded ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        TerminalHeight.Height = expanded ? new GridLength(1, GridUnitType.Star) : new GridLength(250);
        foreach (var surface in new FrameworkElement[] { ChatHeader, Timeline, ApprovalReviewHost, PendingPanel, ComposerPanel }) surface.Visibility = expanded ? Visibility.Collapsed : Visibility.Visible;
        UpdateConversationChrome();
    }
    void UpdateConversationChrome()
    {
        if (current is null) return;
        var welcome = TerminalHeight.Height.Value == 0 && current.Timeline.Items.Count == 0
            && !current.Timeline.IsRunning && current.Queue.Count == 0 && PendingPanel.Children.Count == 0;
        WelcomeHeading.Visibility = welcome ? Visibility.Visible : Visibility.Collapsed;
        WelcomeBottom.Height = welcome ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        ChatIdentity.Visibility = welcome ? Visibility.Collapsed : Visibility.Visible;
        ComposerPanel.MaxWidth = welcome ? 680 : (double)Resources["ConversationMaxWidth"];
        Composer.MinHeight = welcome ? 70 : 34;
        Composer.MaxHeight = welcome ? 130 : 110;
        Composer.FontSize = welcome ? 15 : 14;
        Composer.PlaceholderText = welcome ? $"Message {ComposerProviderName.Text} in this workspace…" : "Send follow-up";
        WelcomeProjectRow.Visibility = welcome && !DictationActive ? Visibility.Visible : Visibility.Collapsed;
        if (DictationActive && !CanDictate()) CancelDictation();
        UpdateDictationControl();
    }
    void UpdateSendAvailability() =>
        SendButton.IsEnabled = !DictationActive && current is { IsSubmitting: false } && (!string.IsNullOrWhiteSpace(Composer.Text) || typedComposerAttachments.Count > 0);
    void ComposerPanel_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateComposerKeyHints();
    public void ToggleInspector() => _ = Run(ToggleUtilityPanelAsync);
    public async Task DisposeSurfacesAsync()
    {
        CloseComposerPill();
        App.Voice.Changed -= DictationRealtimeVoiceChanged;
        CancelDictation();
        if (dictationCleanup is { } cleanup) await cleanup;
        CloseCompletions(); Composer.Paste -= ComposerPaste; Composer.EditorKeyDown -= Composer_KeyDown;
        ShowWorkspace(restoreFocus: false);
        shortcutBindings?.Dispose();
        systemUi.AdvancedEffectsEnabledChanged -= SystemEffectsChanged;
        if (themeSettings is not null) { themeSettings.Changed -= ThemeSettingsChanged; themeSettings = null; }
        try { await SaveDraftNowAsync(); }
        finally
        {
            try { if (browser is not null) await browser.DisposeAsync(); }
            finally { if (terminalPanel is not null) await terminalPanel.DisposeAsync(); }
        }
    }
    public Task NavigateToThreadAsync(ThreadSession session) => Run(async () => { await SaveDraftNowAsync(); await SelectAsync(session); await RefreshCatalogAsync(); });
    public async Task HandleActivationAsync(string arguments)
    {
        await ready.Task;
        var result = await App.Continuation.HandleActivationAsync(arguments);
        if (result.ThreadId is { } threadId && (await workspace.CatalogAsync()).FirstOrDefault(x => x.VeoId == threadId) is { } thread)
            await NavigateToThreadAsync(await workspace.LoadAsync(thread));
    }
    public async Task QuoteIntoComposerAsync(QuoteReference reference, string text)
    {
        ShowWorkspace(restoreFocus: false);
        InsertAtComposerCaret(reference.Markdown(text));
        await SaveDraftNowAsync(); Composer.Focus(FocusState.Programmatic);
    }
    private async Task AppendReviewCommentToDraftAsync(ThreadSession session, string text)
    {
        if (current?.Record.VeoId != session.Record.VeoId || loading)
            throw new InvalidOperationException("Return to the chat whose patch you reviewed before adding a comment.");
        InsertAtComposerCaret(text);
        await SaveDraftNowAsync();
        if (current?.Record.VeoId == session.Record.VeoId) Composer.Focus(FocusState.Programmatic);
    }
    public Task NavigateQuoteAsync(QuoteReference reference) => Run(async () =>
    {
        var record = (await workspace.Threads.ListThreadsAsync(limit: 10000)).Concat(await workspace.Threads.ListThreadsAsync(archived: true, limit: 10000)).FirstOrDefault(x => x.VeoId == reference.ThreadId)
            ?? throw new InvalidOperationException("The source chat was deleted or is unavailable.");
        await SaveDraftNowAsync(); await SelectAsync(await workspace.LoadAsync(record)); await RefreshCatalogAsync();
        if (messages.FirstOrDefault(x => x.Id == reference.ItemId) is { } item) Timeline.ScrollIntoView(item, ScrollIntoViewAlignment.Leading);
        else throw new InvalidOperationException("The source item is not present in the loaded history.");
    });
    public async Task NavigateThreadIdAsync(string id)
    {
        await ready.Task;
        await Run(async () =>
        {
            var record = (await workspace.Threads.ListThreadsAsync(limit: 10000)).Concat(await workspace.Threads.ListThreadsAsync(archived: true, limit: 10000)).FirstOrDefault(x => x.VeoId == id)
                ?? throw new InvalidOperationException("This chat is no longer available.");
            await NavigateToThreadAsync(await workspace.LoadAsync(record));
        });
    }
    ComposerSnapshot SettingsSnapshot() => current is { } session ? CaptureComposerDraft(session).Snapshot(defaults: ComposerDefaults(), includeInput: false) : ComposerDefaults();
    void ApplyModelChoice(ModelSelectionChoice choice)
    {
        model = choice.Model; modelCatalogId = choice.ModelId; effort = choice.Effort; tier = choice.Tier;
        contextTokens = choice.ContextTokens; routingMode = choice.RoutingMode; routerPolicy = choice.RouterPolicy;
        familyPlan = choice.FamilyPlan; composerDaybreak = choice.Daybreak;
    }
    public void RevealProject() { if (current is not null) Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { current.Record.Cwd }, UseShellExecute = true }); }
    public async Task ShowVoiceAsync()
    {
        using var panel = new VoicePanel(App.Voice, () => current, SettingsSnapshot, selected => App.Continuation.Jobs.CancelThreadAsync(selected.Record.VeoId, "Cancelled by voice activity."));
        await new ContentDialog { XamlRoot = XamlRoot, Title = "Realtime voice", Content = panel, CloseButtonText = "Close" }.ShowAsync();
        await App.Voice.StopAsync();
    }
    public Task OpenBrowserAsync(Uri uri) => Run(async () =>
    {
        if (ShowWorkspace(restoreFocus: false)) await RefreshCatalogAsync();
        App.Main?.Activate(); await OpenUtilityPanelAsync(1);
        if (browser is not null) await browser.NavigateAsync(uri.AbsoluteUri);
    });
    public async Task ShowPromptLibraryAsync()
    {
        var panel = new PromptLibraryPanel(workspace, () => current, readCompleteDraft: CaptureComposerDraft, applyCompleteDraft: ApplyCompleteLibraryDraftAsync);
        await new ContentDialog { XamlRoot = XamlRoot, Title = "Saved prompts", Content = panel, CloseButtonText = "Done" }.ShowAsync();
    }
    public async Task ShowPullRequestsAsync()
    {
        var panel = new PullRequestsPanel(workspace, () => current, uri => _ = OpenBrowserAsync(uri));
        if (current is not null) await panel.LoadAsync(current);
        await new ContentDialog { XamlRoot = XamlRoot, Title = "Pull requests", Content = panel, CloseButtonText = "Done" }.ShowAsync();
    }
    public Task ShowCatalogAsync() => Run(async () =>
    {
        var panel = new CatalogOptionsPanel(workspace, App.Catalog, async entry => await NavigateToThreadAsync(await App.Catalog.OpenAsync(entry)), async result =>
        {
            var session = await App.Catalog.OpenAsync(result.Entry); await NavigateToThreadAsync(session);
            if (await App.History.NavigateOccurrenceAsync(session, result) is { } item) FocusTimelineItem(item.Id);
        });
        await ShowWorkspacePanelAsync("Chat catalog and message search", panel); await RefreshCatalogAsync();
    });
    public Task ShowHistoryAsync() => Run(async () =>
    {
        var panel = new HistoryPanel(workspace, App.History, App.Catalog, () => current, NavigateToThreadAsync, FocusTimelineItem, (session, turn) => App.Checkpoints.ForTurnAsync(session, turn));
        if (current is not null) await panel.LoadAsync(current);
        await ShowWorkspacePanelAsync("History and forks", panel);
        if (current is not null) await SelectAsync(current); await RefreshCatalogAsync();
    });
    public Task ShowQueueAsync() => Run(async () =>
    {
        var panel = new Controls.QueuePanel(workspace, App.Queue, () => current); if (current is not null) await panel.LoadAsync(current);
        await ShowWorkspacePanelAsync("Queued prompts", panel); Render();
    });
    Task<ContentDialogResult> ShowWorkspacePanelAsync(string title, UIElement content) => new ContentDialog
    {
        XamlRoot = XamlRoot, Title = title, Content = new ScrollViewer { Content = content, MaxHeight = 600, MinWidth = 500, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }, CloseButtonText = "Done"
    }.ShowAsync().AsTask();
    void FocusTimelineItem(string id)
    {
        if (current is { } session && messages.All(row => row.Id != id))
        {
            var items = session.Timeline.Items;
            if (items.FirstOrDefault(item => item.Id == id) is { TurnId: not null } target
                && items.LastOrDefault(item => item.TurnId == target.TurnId && item.Kind == "userMessage" && item.Order < target.Order) is { } prompt)
                expandedWorkTurns.Add(prompt.Id);
        }
        Render();
        if (messages.FirstOrDefault(row => row.Id == id) is { } match)
            Timeline.ScrollIntoView(match, ScrollIntoViewAlignment.Leading);
    }
    async Task RenameAsync(string argument)
    {
        if (current is null) return; var title = argument;
        if (string.IsNullOrWhiteSpace(title)) { var text = new TextBox { Text = current.Record.Title }; var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Rename chat", Content = text, PrimaryButtonText = "Save", CloseButtonText = "Cancel" }; if (await dialog.ShowAsync() != ContentDialogResult.Primary) return; title = text.Text; }
        if (!string.IsNullOrWhiteSpace(title)) await App.Catalog.RenameAsync(new(current.Record.VeoId, CatalogOrigin.Veo, current.Record), title); await RefreshCatalogAsync();
    }
    async Task DeleteCurrentAsync()
    {
        if (current is null) return;
        var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Delete this chat?", Content = "Its local conversation and local fork family will be removed. Project files remain on disk.", PrimaryButtonText = "Delete", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) { await App.Catalog.DeleteAsync(new(current.Record.VeoId, CatalogOrigin.Veo, current.Record)); current = null; await NewChatAsync(); }
    }
    async Task Run(Func<Task> action) { try { await action(); } catch (Exception e) { ShowError(e); } }
    void ShowError(Exception error)
    {
        Notice.Severity = InfoBarSeverity.Error;
        Notice.Message = DiagnosticRedactor.Redact(error.Message);
        Notice.IsOpen = true;
    }
    void AddAccelerator(VirtualKey key, VirtualKeyModifiers modifiers, Func<Task> action)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers };
        accelerator.Invoked += async (_, e) =>
        {
            if (IsShowingSettings) return;
            e.Handled = true;
            await Run(action);
        };
        KeyboardAccelerators.Add(accelerator);
    }
    async void New_Click(object sender, RoutedEventArgs e) => await NewChatAsync();
    async void OpenProject_Click(object sender, RoutedEventArgs e) => await Run(OpenProjectAsync);
    async void Send_Click(object sender, RoutedEventArgs e) => await Run(SubmitAsync);
    async void Stop_Click(object sender, RoutedEventArgs e) => await Run(async () => { if (current is not null) if (!Agents.Stop(current.Record.VeoId)) await workspace.StopAsync(current); });
    async void Settings_Click(object sender, RoutedEventArgs e) => await Run(() => ShowSettingsAsync());
    public Task ShowTerminalAsync() => Run(ToggleTerminalAsync);
    async void SidebarOptions_Click(object sender, RoutedEventArgs e) => await ShowCatalogAsync();
    async void Chat_Changed(object sender, SelectionChangedEventArgs e)
    {
        foreach (var old in e.RemovedItems.OfType<ChatRow>()) old.SetSelected(false);
        foreach (var added in e.AddedItems.OfType<ChatRow>()) added.SetSelected(true);
        if (!updatingCatalog && !loading && ChatList.SelectedItem is ChatRow row && row.Record.VeoId != current?.Record.VeoId)
            await Run(async () => { await SaveDraftNowAsync(); await SelectAsync(await App.Catalog.OpenAsync(row.Entry)); });
    }
    async void ProjectGroup_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string path }) return;
        await Run(async () => { var paths = (App.Catalog.Options.CollapsedProjects ?? []).ToHashSet(StringComparer.OrdinalIgnoreCase); if (!paths.Remove(path)) paths.Add(path); await App.Catalog.SaveOptionsAsync(App.Catalog.Options with { CollapsedProjects = paths.ToArray() }); await RefreshCatalogAsync(); });
    }
    async void Search_Changed(object sender, TextChangedEventArgs e)
    {
        searchDelay?.Cancel(); var cts = searchDelay = new();
        try { await Task.Delay(180, cts.Token); if (initialized) await Run(RefreshCatalogAsync); } catch (OperationCanceledException) { }
    }
    void SidebarSearch_Click(object sender, RoutedEventArgs e) =>
        ShowSidebarSearch(SearchBox.Visibility == Visibility.Collapsed);

    void SidebarSearch_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Escape) return;
        e.Handled = true;
        ShowSidebarSearch(false);
    }

    void ShowSidebarSearch(bool visible)
    {
        SearchBox.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(SidebarSearchToggle, visible ? "Hide chat search" : "Search chats");
        if (visible)
        {
            DispatcherQueue.TryEnqueue(() => SearchBox.Focus(FocusState.Programmatic));
        }
        else
        {
            SearchBox.Text = "";
            searchDelay?.Cancel();
            _ = Run(RefreshCatalogAsync);
            SidebarSearchToggle.Focus(FocusState.Programmatic);
        }
    }
    async void Composer_Changed(object sender, RoutedEventArgs e)
    {
        if (loading || !initialized) return;
        if (dictationDraft is { } snapshot && Composer.Text != snapshot.Text) CancelDictation();
        UpdateSendAvailability(); composerRevision++; _ = RefreshCompletionsAsync(); draftDelay?.Cancel(); var cts = draftDelay = new();
        try { await Task.Delay(180, cts.Token); await Run(SaveDraftNowAsync); } catch (OperationCanceledException) { }
    }
    async void Composer_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (DictationActive && e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            CancelDictation(restoreFocus: true);
            return;
        }
        if (DictationActive && e.Key == VirtualKey.Enter) { e.Handled = true; return; }
        if (!imeComposing && composerSuggestions.Visibility == Visibility.Visible && e.Key is VirtualKey.Escape or VirtualKey.Up or VirtualKey.Down or VirtualKey.Enter or VirtualKey.Tab) { e.Handled = true; await Run(async () => await HandleCompletionKeyAsync(e.Key)); return; }
        if (!imeComposing && (e.Key is VirtualKey.Up or VirtualKey.Down) && RecallPrompt(e.Key == VirtualKey.Up ? -1 : 1)) { e.Handled = true; return; }
        if (!imeComposing && e.Key == VirtualKey.Enter && !Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down)) { e.Handled = true; await Run(SubmitAsync); }
    }
    void Composer_DragOver(object sender, DragEventArgs e) => e.AcceptedOperation = e.DataView.Contains(StandardDataFormats.StorageItems) ? DataPackageOperation.Copy : DataPackageOperation.None;
    async void Composer_Drop(object sender, DragEventArgs e) => await Run(() => DropComposerAttachmentsAsync(e));
    void Chat_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var source = e.OriginalSource as FrameworkElement; while (source is not null && source.DataContext is not ChatRow) source = source.Parent as FrameworkElement;
        if (source?.DataContext is not ChatRow row) return;
        var menu = new MenuFlyout();
        void Item(string label, Func<Task> action) { var item = new MenuFlyoutItem { Text = label }; item.Click += async (_, _) => await Run(async () => { await SaveDraftNowAsync(); await SelectAsync(await App.Catalog.OpenAsync(row.Entry)); await action(); await RefreshCatalogAsync(); }); menu.Items.Add(item); }
        Item("Rename", () => RenameAsync("")); Item(row.Record.IsPinned ? "Unpin" : "Pin", () => workspace.SetPinnedAsync(current!, !row.Record.IsPinned));
        Item(row.Record.IsArchived ? "Unarchive" : "Archive", () => App.Catalog.SetArchivedAsync(row.Entry, !row.Record.IsArchived));
        if (row.Entry.Origin == CatalogOrigin.Veo) { Item("Make temporary", () => workspace.MakeTemporaryAsync(current!)); Item("Delete…", DeleteCurrentAsync); }
        else Item("Delete Codex chat…", async () => { var dialog = new ContentDialog { XamlRoot = XamlRoot, Title = "Delete this Codex CLI chat?", Content = "Codex will remove this runtime chat. This also affects other local CLI clients.", PrimaryButtonText = "Delete", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close }; if (await dialog.ShowAsync() == ContentDialogResult.Primary) { await App.Catalog.DeleteAsync(row.Entry); current = null; await NewChatAsync(); } });
        menu.ShowAt(source, e.GetPosition(source)); e.Handled = true;
    }
}
