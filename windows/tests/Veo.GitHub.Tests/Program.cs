using System.Text;
using System.Text.Json;
using Veo.Infrastructure.Files;
using Veo.Infrastructure.Git;
using Veo.Infrastructure.GitHub;

var passed = new List<string>();
void Check(bool condition, string name) { if (!condition) throw new Exception("FAILED " + name); passed.Add(name); Console.WriteLine("PASS " + name); }
async Task<Exception> Refuses(Func<Task> action, string name)
{ try { await action(); } catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or ArgumentException or InvalidOperationException) { Check(true, name); return error; } throw new Exception("FAILED accepted " + name); }
var root = Path.Combine(Path.GetTempPath(), "Veo.GitHub.Tests-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(root);
root = new WorkspacePathPolicy(root).RootPath;
const string originalHead = "0123456789012345678901234567890123456789";
var runner = new FakeGitHub(root, originalHead); var github = new GitHubService(root, runner);
var snapshot = new GitRepositorySnapshot("snapshot", root, root, Path.Combine(root, ".git"), Path.Combine(root, ".git"), originalHead, "feature", true, [], [], new Dictionary<string, string>());
Check(GitHubService.ValidReference("123") && GitHubService.ValidReference("https://github.com/owner/repo/pull/12") && GitHubService.ValidReference("https://enterprise.invalid/owner/repo/pull/34"), "PR reference validation supports positive numbers and HTTPS GitHub/enterprise paths");
Check(!GitHubService.ValidReference("--delete") && !GitHubService.ValidReference("https://user:secret@github.com/owner/repo/pull/12") && !GitHubService.ValidReference("https://github.com/owner/repo/pull/12?execute=true") && !GitHubService.ValidReference("0"), "PR reference validation refuses options, credentials, queries and zero");
var requests = await github.ListAsync(root);
Check(requests.Single().Number == 12 && requests[0].Comments![0].Body == "Exact comment\nsecond line" && requests[0].StatusCheckRollup![0].Conclusion == "SUCCESS", "GH list parses actual PR details, comments and checks");
var read = await github.ReadAsync("12", root);
Check(read.Url == "https://github.com/owner/repo/pull/12" && runner.Commands.All(command => command.Arguments[0] != "push" && !command.Arguments.Contains("create")), "PR inspection never pushes or creates remotely");
await Refuses(async () => { await github.ReadAsync("--repo attacker", root); }, "malformed PR reference is refused before invoking gh");
var approval = await github.PrepareDraftAsync(snapshot);
Check(!approval.PushApproved && !approval.DraftCreationApproved && approval.Head == originalHead && approval.Branch == "feature", "draft preparation captures actual branch, HEAD and origin without authorization");
var commandsBefore = runner.Commands.Count;
await Refuses(async () => { await github.CreateDraftAsync(approval, "Title", "Body", "main"); }, "draft PR mutation requires explicit push and creation approvals");
Check(runner.Commands.Count == commandsBefore, "denied draft mutation runs no subprocess");

var approved = approval with { PushApproved = true, DraftCreationApproved = true };
runner.Head = new string('f', 40);
await Refuses(async () => { await github.CreateDraftAsync(approved, "Title", "Body", "main"); }, "draft creation refuses a changed HEAD before push");
Check(runner.Pushes == 0 && runner.Creates == 0, "stale HEAD prevents all remote-write commands"); runner.Head = originalHead;
runner.Origin = "https://github.com/different/repository.git";
await Refuses(async () => { await github.CreateDraftAsync(approved, "Title", "Body", "main"); }, "draft creation refuses an origin change after preview");
Check(runner.Pushes == 0, "changed remote cannot receive an approved push"); runner.Origin = approval.OriginUrl;

const string exactBody = "First line\r\n\r\nLiteral $value and `backticks` and \\\\n stay exact.\nLast line";
var created = await github.CreateDraftAsync(approved, "A quoted \"title\"", exactBody, "main");
Check(created.IsDraft && created.HeadRefName == "feature" && created.BaseRefName == "main" && runner.Pushes == 1 && runner.Creates == 1, "explicit draft action pushes once, creates draft once and reads actual result back");
Check(runner.CapturedBody == exactBody && runner.CapturedTitle == "A quoted \"title\"", "PR body file preserves actual CRLF, newlines, dollar signs and literal escapes");
Check(runner.BodyFile is not null && !File.Exists(runner.BodyFile), "temporary PR body file is removed after command completion");
Check(runner.Commands.Where(command => command.Arguments[0] == "push").Single().Arguments.SequenceEqual(["push", "--set-upstream", "origin", "HEAD:refs/heads/feature"]), "push uses literal fixed arguments and the reviewed branch destination");

var changing = new FakeGitHub(root, originalHead) { ChangeAfterPush = true }; var changingService = new GitHubService(root, changing);
var changed = await Refuses(async () => { await changingService.CreateDraftAsync(approved, "Title", "Body", "main"); }, "branch context is checked again after successful push");
Check(changed is GitHubRemoteActionException { PushCompleted: true, CreationUncertain: false } && changing.Creates == 0, "post-push failure reports completed remote action and prevents PR creation");
var noUrl = new FakeGitHub(root, originalHead) { OmitCreateUrl = true }; var noUrlService = new GitHubService(root, noUrl);
var uncertain = await Refuses(async () => { await noUrlService.CreateDraftAsync(approved, "Title", "Body", "main"); }, "missing create URL is treated as an ambiguous remote result");
Check(uncertain is GitHubRemoteActionException { PushCompleted: true, CreationUncertain: true } && noUrl.Creates == 1, "ambiguous PR creation is never automatically replayed");
var pushFail = new FakeGitHub(root, originalHead) { FailPush = true }; var pushFailService = new GitHubService(root, pushFail);
var pushError = await Refuses(async () => { await pushFailService.CreateDraftAsync(approved, "Title", "Body", "main"); }, "failed push is reported as an unconfirmed remote action");
Check(pushError is GitHubRemoteActionException { PushCompleted: false, PushUncertain: true } && pushFail.Creates == 0, "unconfirmed push never continues to PR creation");
var wrongReadback = new FakeGitHub(root, originalHead) { ReadbackDraft = false }; var wrongReadbackService = new GitHubService(root, wrongReadback);
await Refuses(async () => { await wrongReadbackService.CreateDraftAsync(approved, "Title", "Body", "main"); }, "created PR draft/branch/base state is verified instead of assumed");
Check(!GitHubService.DisplayOrigin("https://secret-token@github.com/owner/repo.git").Contains("secret-token"), "remote preview removes embedded credential userinfo");
runner.FailReads = true;
var readError = await Refuses(async () => { await github.ReadAsync(null, root); }, "GitHub CLI read failure is actionable");
Check(!readError.Message.Contains("redacted-token") && !readError.Message.Contains("private repository message"), "CLI error display does not expose stderr credentials or private payloads");

Console.WriteLine(JsonSerializer.Serialize(new { Passed = passed.Count, Root = root, NoRealRemoteWrites = true, Scenarios = passed }));

sealed class FakeGitHub(string root, string head) : ICommandRunner
{
    public List<CliInvocation> Commands { get; } = [];
    public string Head { get; set; } = head;
    public string Origin { get; set; } = "https://github.com/owner/repo.git";
    public bool ChangeAfterPush { get; init; }
    public bool OmitCreateUrl { get; init; }
    public bool FailPush { get; init; }
    public bool FailReads { get; set; }
    public bool ReadbackDraft { get; init; } = true;
    public int Pushes { get; private set; }
    public int Creates { get; private set; }
    public string? CapturedBody { get; private set; }
    public string? CapturedTitle { get; private set; }
    public string? BodyFile { get; private set; }
    private string Pr => JsonSerializer.Serialize(new { number = 12, title = "Fixture PR", url = "https://github.com/owner/repo/pull/12", state = "OPEN", isDraft = ReadbackDraft,
        headRefName = "feature", baseRefName = "main", body = "Description", comments = new[] { new { body = "Exact comment\nsecond line", author = new { login = "fixture-owner" }, url = "https://github.com/owner/repo/pull/12#comment" } },
        statusCheckRollup = new[] { new { name = "Build", status = "COMPLETED", conclusion = "SUCCESS" } }, reviewDecision = "REVIEW_REQUIRED" });
    public Task<CliResult> RunAsync(CliInvocation command, CancellationToken token = default)
    {
        Commands.Add(command); var args = command.Arguments; string output = ""; var exit = 0;
        if (command.Executable == "git.exe")
        {
            output = args[0] switch { "rev-parse" when args.Contains("--show-toplevel") => root, "rev-parse" => Head, "symbolic-ref" => "feature", "remote" => Origin, _ => "" };
            if (args[0] == "push") { Pushes++; if (FailPush) exit = 1; if (ChangeAfterPush) Head = new string('f', 40); }
        }
        else if (args[0] == "pr" && args[1] == "list") output = "[" + Pr + "]";
        else if (args[0] == "pr" && args[1] == "view") { output = Pr; if (FailReads) exit = 1; }
        else if (args[0] == "pr" && args[1] == "create")
        {
            Creates++; BodyFile = args[args.ToList().IndexOf("--body-file") + 1]; CapturedBody = File.ReadAllText(BodyFile);
            CapturedTitle = args[args.ToList().IndexOf("--title") + 1]; output = OmitCreateUrl ? "Created without URL" : "https://github.com/owner/repo/pull/12\n";
        }
        return Task.FromResult(new CliResult(exit, Encoding.UTF8.GetBytes(output), exit == 0 ? "" : "Bearer redacted-token private repository message"));
    }
}
