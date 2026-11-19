using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Veo.Infrastructure.Git;
using Veo.Infrastructure.GitHub;

namespace Veo_Windows.Controls;

public sealed class PullRequestsPanel : UserControl
{
    private readonly WorkspaceCoordinator workspace;
    private readonly Func<ThreadSession?> selected;
    private readonly Action<Uri>? navigate;
    private readonly GitHubService github;
    private readonly LocalGitService git;
    private readonly ListView list = new() { MaxHeight = 220, SelectionMode = ListViewSelectionMode.Single, ItemContainerTransitions = new() };
    private readonly TextBox reference = new() { Header = "PR URL or number", PlaceholderText = "Current branch if blank" };
    private readonly TextBlock context = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private readonly TextBox detail = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 280 };
    private readonly TextBox title = new() { Header = "Draft PR title" };
    private readonly TextBox body = new() { Header = "Draft PR description", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 180 };
    private readonly TextBox baseBranch = new() { Header = "Base branch" };
    private readonly CheckBox approve = new() { Content = "I approve pushing the displayed branch to origin and creating a draft PR", IsChecked = false };
    private readonly Button create = new() { Content = "Push branch and create draft PR", IsEnabled = false };
    private readonly HyperlinkButton open = new() { Content = "Open selected pull request", IsEnabled = false };
    private readonly InfoBar notice = new() { IsOpen = false, IsClosable = true };
    private readonly SemaphoreSlim gate = new(1, 1);
    private GitHubRemoteApproval? prepared;
    private ThreadSession? explicitSession;
    private bool remoteUncertain;
    private IReadOnlyList<PullRequestDetails> requests = [];
    public PullRequestsPanel(WorkspaceCoordinator workspace, Func<ThreadSession?> selected, Action<Uri>? navigate = null)
    {
        this.workspace = workspace; this.selected = selected; this.navigate = navigate;
        github = new(workspace.DataRoot); git = new(Path.Combine(workspace.DataRoot, "Recovery"));
        var controls = new StackPanel { Spacing = 10 };
        var refresh = new Button { Content = "Refresh pull requests" }; refresh.Click += async (_, _) => await RunAsync(RefreshAsync);
        var read = new Button { Content = "Load pull request" }; read.Click += async (_, _) => await RunAsync(ReadAsync);
        create.Click += async (_, _) => await RunAsync(CreateAsync);
        approve.Checked += (_, _) => UpdateCreate(); approve.Unchecked += (_, _) => UpdateCreate();
        baseBranch.TextChanged += (_, _) => approve.IsChecked = false;
        list.SelectionChanged += (_, _) => Show(list.SelectedItem as PullRequestDetails);
        open.Click += async (_, _) =>
        {
            if (list.SelectedItem is PullRequestDetails pr && Uri.TryCreate(pr.Url, UriKind.Absolute, out var uri))
            { if (navigate is not null) navigate(uri); else await Windows.System.Launcher.LaunchUriAsync(uri); }
        };
        AutomationProperties.SetName(list, "Pull requests"); AutomationProperties.SetName(approve, "Approve branch push and draft PR creation");
        foreach (var control in new FrameworkElement[] { refresh, context, list, reference, read, open, detail, title, body, baseBranch, approve, create, notice }) controls.Children.Add(control);
        Content = controls; Loaded += async (_, _) => await RunAsync(RefreshAsync);
    }
    public async Task LoadAsync(ThreadSession session)
    { explicitSession = session; await RunAsync(RefreshAsync); }
    private ThreadSession Session() => explicitSession ?? selected() ?? throw new InvalidOperationException("Open a project chat before using GitHub.");
    private async Task RefreshAsync()
    {
        prepared = null; approve.IsChecked = false; create.IsEnabled = false;
        var session = Session(); GitRepositorySnapshot snapshot;
        try { snapshot = await git.SnapshotAsync(session.Record.Cwd); }
        catch (NotGitRepositoryException) { list.ItemsSource = Array.Empty<PullRequestDetails>(); detail.Text = ""; context.Text = "This workspace has no Git repository."; return; }
        requests = await github.ListAsync(session.Record.Cwd); list.ItemsSource = requests;
        if (snapshot.Head is not null && snapshot.Branch is not null)
        {
            prepared = await github.PrepareDraftAsync(snapshot); context.Text = snapshot.Branch + " · " + snapshot.Head[..Math.Min(12, snapshot.Head.Length)] + "\n" + GitHubService.DisplayOrigin(prepared.OriginUrl);
        }
        else context.Text = "Create a committed branch before starting a draft PR.";
        remoteUncertain = false; UpdateCreate();
    }
    private async Task ReadAsync()
    {
        var pr = await github.ReadAsync(string.IsNullOrWhiteSpace(reference.Text) ? null : reference.Text.Trim(), Session().Record.Cwd);
        requests = requests.Where(existing => existing.Url != pr.Url).Prepend(pr).ToArray(); list.ItemsSource = requests; list.SelectedItem = pr; Show(pr);
    }
    private async Task CreateAsync()
    {
        if (prepared is null || approve.IsChecked != true || remoteUncertain) throw new UnauthorizedAccessException("Refresh and explicitly approve the displayed branch push and draft PR creation.");
        var approval = prepared with { PushApproved = true, DraftCreationApproved = true }; approve.IsChecked = false;
        try
        {
            var pr = await github.CreateDraftAsync(approval, title.Text, body.Text, baseBranch.Text.Trim());
            requests = requests.Where(existing => existing.Url != pr.Url).Prepend(pr).ToArray(); list.ItemsSource = requests; list.SelectedItem = pr; Show(pr);
            notice.Severity = InfoBarSeverity.Success; notice.Title = "Draft PR created"; notice.Message = pr.Url; notice.IsOpen = true;
        }
        catch (GitHubRemoteActionException) { remoteUncertain = true; throw; }
        finally { UpdateCreate(); }
    }
    private void Show(PullRequestDetails? pr)
    {
        open.IsEnabled = pr is not null;
        if (pr is null) { detail.Text = ""; return; }
        var checks = string.Join("\n", (pr.StatusCheckRollup ?? []).Select(check => (check.Name ?? check.Context ?? "Check") + ": " + (check.Conclusion ?? check.State ?? check.Status ?? "Status unavailable")));
        var comments = string.Join("\n\n", (pr.Comments ?? []).Select(comment => (comment.Author?.Login ?? "Author unavailable") + ":\n" + comment.Body));
        detail.Text = "#" + pr.Number + " " + pr.Title + "\n" + pr.State + (pr.IsDraft ? " · Draft" : "") + " · " + pr.HeadRefName + " → " + pr.BaseRefName
            + "\n" + pr.Url + "\n\n" + pr.Body + (checks.Length == 0 ? "" : "\n\nChecks:\n" + checks) + (comments.Length == 0 ? "" : "\n\nComments:\n" + comments);
        UpdateCreate();
    }
    private void UpdateCreate() => create.IsEnabled = prepared is not null && approve.IsChecked == true && !remoteUncertain && !requests.Any(pr => pr.HeadRefName == prepared.Branch && pr.State == "OPEN");
    private async Task RunAsync(Func<Task> action)
    {
        if (!await gate.WaitAsync(0)) return; notice.IsOpen = false;
        try { await action(); }
        catch (Exception error) { notice.Severity = InfoBarSeverity.Error; notice.Title = "GitHub action failed"; notice.Message = error.Message; notice.IsOpen = true; }
        finally { gate.Release(); }
    }
}
