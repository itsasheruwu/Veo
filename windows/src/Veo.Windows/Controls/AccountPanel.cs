using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Veo.Protocol;

namespace Veo_Windows.Controls;

public sealed class AccountPanel : StackPanel
{
    readonly AccountCoordinator accounts;
    readonly Action<Uri> navigate;
    readonly StackPanel body = new() { Spacing = 12 };
    readonly InfoBar notice = new() { IsClosable = true };
    readonly ProgressBar progress = new() { IsIndeterminate = true, Visibility = Visibility.Collapsed };
    string resetAttempt = Guid.NewGuid().ToString();
    bool busy;
    public AccountPanel(AccountCoordinator accounts, Action<Uri> navigate)
    {
        this.accounts = accounts; this.navigate = navigate; Spacing = 12;
        Children.Add(Text("Codex owns this PC's account credentials. Signing in or out here changes the account shared with other local Codex clients."));
        Children.Add(Button("Refresh account and usage", async () => { await accounts.RefreshAsync(); Render(); }, "AccountRefresh")); Children.Add(progress); Children.Add(notice); Children.Add(body);
        Loaded += (_, _) => { accounts.Navigate -= OnNavigate; accounts.Navigate += OnNavigate; accounts.Changed -= OnChanged; accounts.Changed += OnChanged; Run(async () => { await accounts.RefreshAsync(); Render(); }); };
        Unloaded += (_, _) => { accounts.Navigate -= OnNavigate; accounts.Changed -= OnChanged; };
    }
    void OnNavigate(Uri uri) => DispatcherQueue.TryEnqueue(() => navigate(uri));
    void OnChanged() => DispatcherQueue.TryEnqueue(Render);
    void Render()
    {
        body.Children.Clear(); var state = accounts.State;
        foreach (var issue in state.Issues) body.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Title = issue.Unavailable ? "Not available in this runtime" : "Account read failed", Message = issue.Method + ": " + issue.Message });
        body.Children.Add(Text(state.Identity is { } identity ? (identity.Type == "apiKey" ? "API key account" : identity.Type == "chatgpt" ? "ChatGPT account" : identity.Type) + (identity.Email is null ? "" : "\n" + identity.Email) + (identity.Plan is null ? "" : " · " + identity.Plan) + (identity.Workspace is null ? "" : "\nWorkspace: " + identity.Workspace) : state.Issues.Any(x => x.Method == "account/read") ? "Account state could not be verified." : "Signed out"));
        if (accounts.Login is { } flow)
        {
            var login = new StackPanel { Spacing = 6 }; login.Children.Add(Text("Sign-in: " + flow.Status + (flow.Error is null ? "" : "\n" + flow.Error)));
            if (flow.UserCode is { } code) { var display = Text("Enter this one-time code: " + code); AutomationProperties.SetAutomationId(display, "AccountDeviceCode"); login.Children.Add(display); }
            if (flow.Status == "Awaiting user") { login.Children.Add(Button("Open sign-in in Veo's browser", () => { accounts.OpenLoginBrowser(); return Task.CompletedTask; }, "AccountOpenLogin")); login.Children.Add(Button("Cancel sign-in", async () => await accounts.CancelLoginAsync(), "AccountCancelLogin")); }
            body.Children.Add(login);
        }
        var signin = new StackPanel { Spacing = 8 };
        signin.Children.Add(Button("Sign in with ChatGPT", async () => await accounts.StartLoginAsync("chatgpt"), "AccountChatGptLogin"));
        signin.Children.Add(Button("Sign in with a device code", async () => await accounts.StartLoginAsync("chatgptDeviceCode"), "AccountDeviceLogin"));
        var key = new PasswordBox { Header = "OpenAI API key", PlaceholderText = "Stored by Codex" }; AutomationProperties.SetAutomationId(key, "AccountApiKey"); signin.Children.Add(key);
        signin.Children.Add(Button("Sign in with API key", async () => { var value = key.Password; key.Password = ""; await accounts.StartLoginAsync("apiKey", value); }, "AccountApiLogin")); body.Children.Add(Section("Sign in", signin));
        if (state.Identity is not null) body.Children.Add(Button("Sign out of local Codex…", async () => { if (await Confirm("Sign out of local Codex?", "This signs out the shared local Codex account, including other local clients. Running work may lose authentication. Your local Veo chats remain on this PC.", "Sign out")) await accounts.LogoutAsync(); }, "AccountLogout"));
        var usage = new StackPanel { Spacing = 8 }; usage.Children.Add(Text(state.OrdinaryUsageAllowed is { } allowed ? allowed ? "Included usage is allowed by the backend." : "The backend currently blocks ordinary included usage." : "Included-usage permission has not been reported. Percentages and reset times do not establish permission."));
        foreach (var bucket in state.Usage)
        {
            var group = new StackPanel { Spacing = 5 }; if (bucket.Primary is { } primary) AddWindow(group, "Primary", primary); if (bucket.Secondary is { } secondary) AddWindow(group, "Secondary", secondary);
            if (bucket.Unlimited) group.Children.Add(Text("Credits: unlimited")); else if (bucket.Balance is not null) group.Children.Add(Text("Credit balance: " + bucket.Balance));
            if (bucket.LimitReason is not null) group.Children.Add(Text("Limit: " + bucket.LimitReason.Replace('_', ' '))); usage.Children.Add(Section(bucket.Title, group));
        }
        if (state.Tokens is { } tokens)
        {
            if (tokens.LifetimeTokens is { } lifetime) usage.Children.Add(Text($"Lifetime tokens: {lifetime:N0}")); if (tokens.CurrentStreak is { } streak) usage.Children.Add(Text($"Current streak: {streak:N0} days")); if (tokens.PeakDailyTokens is { } peak) usage.Children.Add(Text($"Peak daily tokens: {peak:N0}"));
            foreach (var day in tokens.Daily.TakeLast(14)) usage.Children.Add(Text(day.Date + $" · {day.Tokens:N0} tokens"));
        }
        if (state.AvailableResetCredits is { } count)
        {
            usage.Children.Add(Text($"Available usage-reset credits: {count:N0}"));
            foreach (var credit in state.ResetCredits.Where(x => x.Status == "available")) usage.Children.Add(Button("Use “" + credit.Title + "”…", () => Redeem(credit.Id, credit.Description), "ResetCredit_" + Uri.EscapeDataString(credit.Id)));
            if (count > 0 && state.ResetCredits.Length == 0) usage.Children.Add(Button("Use next available reset credit…", () => Redeem(null, null), "AccountResetNext"));
        }
        body.Children.Add(Section("Usage", usage));
        var sessions = new StackPanel { Spacing = 8 };
        foreach (var saved in state.Sessions)
        {
            var group = new StackPanel { Spacing = 6 }; foreach (var workspace in saved.Workspaces)
            {
                var active = saved.Active && saved.SelectedWorkspace == workspace.AccountId; var item = Button(workspace.Name + (active ? " · selected" : " · switch…"), async () => { if (await Confirm("Switch the shared Codex workspace?", "New work will use this saved login and workspace in other local Codex clients too. If this workspace needs sign-in, Veo will open its authorization page.", "Switch")) await accounts.SwitchAsync(saved.SessionId, workspace.AccountId, allowBrowserLogin: true); }, "AccountWorkspace_" + Uri.EscapeDataString(saved.SessionId + "_" + workspace.AccountId)); item.IsEnabled = !active; group.Children.Add(item);
            }
            sessions.Children.Add(Section(saved.Name, group));
        }
        if (sessions.Children.Count > 0) body.Children.Add(Section("Saved logins and workspaces", sessions));
    }
    async Task Redeem(string? creditId, string? description)
    {
        if (!await Confirm("Use a usage-reset credit?", description ?? "This consumes an earned reset credit when eligible usage windows can be reset. Codex will report the outcome.", "Use credit")) return;
        var outcome = await accounts.RedeemResetCreditAsync(resetAttempt, creditId); resetAttempt = Guid.NewGuid().ToString(); notice.Message = outcome switch { "reset" => "Credit consumed and eligible windows reset. Current usage permission was refreshed.", "alreadyRedeemed" => "This attempt had already redeemed a credit. Current usage was refreshed.", "noCredit" => "No earned reset credit is available.", _ => "No current usage window is eligible for reset." }; notice.Severity = InfoBarSeverity.Informational; notice.IsOpen = true;
    }
    static void AddWindow(StackPanel parent, string title, AccountUsageWindow window) { parent.Children.Add(Text(title + $" · {window.UsedPercent}% used" + (window.DurationMinutes is { } mins ? $" · {mins:N0} minutes" : "") + (window.ResetsAt is { } reset ? "\nResets: " + reset.ToLocalTime().ToString("g") : ""))); parent.Children.Add(new ProgressBar { Minimum = 0, Maximum = 100, Value = window.UsedPercent }); }
    async Task<bool> Confirm(string title, string message, string primary) => await new ContentDialog { Title = title, Content = message, PrimaryButtonText = primary, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close, XamlRoot = XamlRoot }.ShowAsync() == ContentDialogResult.Primary;
    Button Button(string text, Func<Task> action, string automation) { var button = new Button { Content = text }; AutomationProperties.SetAutomationId(button, automation); button.Click += (_, _) => Run(action); return button; }
    async void Run(Func<Task> action) { if (busy) return; busy = true; progress.Visibility = Visibility.Visible; try { notice.IsOpen = false; await action(); } catch (Exception ex) { notice.Message = DiagnosticRedactor.Redact(ex.Message); notice.Severity = InfoBarSeverity.Error; notice.IsOpen = true; } finally { busy = false; progress.Visibility = Visibility.Collapsed; } }
    static TextBlock Text(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    static Expander Section(string title, object content) => new() { Header = title, Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
}
