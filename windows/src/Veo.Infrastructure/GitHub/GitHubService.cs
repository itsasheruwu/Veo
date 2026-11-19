using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Veo.Infrastructure.Files;
using Veo.Infrastructure.Git;

namespace Veo.Infrastructure.GitHub;

public sealed record PullRequestAuthor(string Login);
public sealed record PullRequestComment(string Body, PullRequestAuthor? Author, string? Url);
public sealed record PullRequestCheck(string? Name, string? Context, string? Status, string? Conclusion, string? State);
public sealed record PullRequestDetails(int Number, string Title, string Url, string State, bool IsDraft,
    string HeadRefName, string BaseRefName, string Body, PullRequestComment[]? Comments,
    PullRequestCheck[]? StatusCheckRollup, string? ReviewDecision)
{ public override string ToString() => "#" + Number + " " + Title; }
public sealed record GitHubRemoteApproval(string RepositoryRoot, string Branch, string Head, string OriginUrl,
    bool PushApproved = false, bool DraftCreationApproved = false)
{ public override string ToString() => "GitHub action for " + Branch; }
public sealed class GitHubRemoteActionException(string message, bool pushCompleted, string? pullRequestUrl = null,
    bool creationUncertain = false, bool pushUncertain = false) : IOException(message)
{
    public bool PushCompleted { get; } = pushCompleted;
    public string? PullRequestUrl { get; } = pullRequestUrl;
    public bool CreationUncertain { get; } = creationUncertain;
    public bool PushUncertain { get; } = pushUncertain;
}
public sealed record CliInvocation(string Executable, IReadOnlyList<string> Arguments, string WorkingDirectory);
public sealed record CliResult(int ExitCode, byte[] Stdout, string Stderr);
public interface ICommandRunner
{ Task<CliResult> RunAsync(CliInvocation command, CancellationToken token = default); }

/// <summary>Uses the existing GitHub CLI account. Only CreateDraftAsync can push or create remotely.</summary>
public sealed class GitHubService
{
    private const string Fields = "number,title,url,state,isDraft,headRefName,baseRefName,body,comments,statusCheckRollup,reviewDecision";
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    private readonly ICommandRunner runner;
    private readonly string temporaryDirectory;
    private readonly string gh;
    private readonly string git;
    private readonly SemaphoreSlim remoteGate = new(1, 1);
    public GitHubService(string dataRoot, ICommandRunner? runner = null, string ghExecutable = "gh.exe", string gitExecutable = "git.exe")
    {
        this.runner = runner ?? new OwnedCommandRunner(); gh = ghExecutable; git = gitExecutable;
        temporaryDirectory = Path.Combine(dataRoot, "GitHub", "Temporary"); Directory.CreateDirectory(temporaryDirectory);
    }
    public async Task<IReadOnlyList<PullRequestDetails>> ListAsync(string directory, CancellationToken token = default)
    {
        var bytes = await RequiredAsync(gh, ["pr", "list", "--state", "open", "--limit", "100", "--json", Fields], directory, token);
        return JsonSerializer.Deserialize<PullRequestDetails[]>(bytes, JsonOptions) ?? throw new InvalidDataException("GitHub CLI returned an unreadable pull-request list.");
    }
    public async Task<PullRequestDetails> ReadAsync(string? reference, string directory, CancellationToken token = default)
    {
        if (reference is not null && !ValidReference(reference)) throw new ArgumentException("Enter a GitHub pull-request URL or positive number.");
        var args = new List<string> { "pr", "view" }; if (reference is not null) args.Add(reference); args.Add("--json"); args.Add(Fields);
        return JsonSerializer.Deserialize<PullRequestDetails>(await RequiredAsync(gh, args, directory, token), JsonOptions)
            ?? throw new InvalidDataException("GitHub CLI returned an unreadable pull request.");
    }
    public async Task<GitHubRemoteApproval> PrepareDraftAsync(GitRepositorySnapshot expected, CancellationToken token = default)
    {
        await ValidateContextAsync(expected.RootPath, expected.Branch, expected.Head, token);
        if (expected.Branch is null || expected.Head is null) throw new InvalidOperationException("Create a committed branch before making a draft pull request.");
        var origin = Text(await RequiredAsync(git, ["remote", "get-url", "origin"], expected.RootPath, token));
        if (!SupportedRemote(origin)) throw new NotSupportedException("Draft PR push requires an HTTPS or SSH origin remote.");
        return new(expected.RootPath, expected.Branch, expected.Head, origin);
    }
    public async Task<PullRequestDetails> CreateDraftAsync(GitHubRemoteApproval approval, string title, string body,
        string baseBranch, CancellationToken token = default)
    {
        if (!approval.PushApproved || !approval.DraftCreationApproved) throw new UnauthorizedAccessException("Explicitly approve the push and draft pull-request creation before continuing.");
        if (string.IsNullOrWhiteSpace(title) || title.Contains('\0') || body.Contains('\0') || string.IsNullOrWhiteSpace(baseBranch) || baseBranch.StartsWith('-') || baseBranch == approval.Branch)
            throw new ArgumentException("Enter a title and a base branch different from the current branch.");
        await remoteGate.WaitAsync(token); string? bodyFile = null; var pushSent = false; var pushed = false; var createSent = false; string? url = null;
        try
        {
            await ValidateApprovalAsync(approval, token);
            await RequiredAsync(git, ["check-ref-format", "--branch", baseBranch], approval.RepositoryRoot, token);
            pushSent = true; await RequiredAsync(git, ["push", "--set-upstream", "origin", "HEAD:refs/heads/" + approval.Branch], approval.RepositoryRoot, token); pushed = true;
            await ValidateApprovalAsync(approval, token);
            bodyFile = new WorkspacePathPolicy(temporaryDirectory).Resolve("veo-pr-" + Guid.NewGuid().ToString("N") + ".txt", mustExist: false);
            await File.WriteAllTextAsync(bodyFile, body, new UTF8Encoding(false, true), token);
            createSent = true;
            var output = Text(await RequiredAsync(gh, ["pr", "create", "--draft", "--title", title, "--body-file", bodyFile, "--base", baseBranch, "--head", approval.Branch], approval.RepositoryRoot, token));
            url = output.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).LastOrDefault(value => value.StartsWith("https://", StringComparison.OrdinalIgnoreCase) && ValidReference(value));
            if (url is null) throw new GitHubRemoteActionException("The branch was pushed, but GitHub CLI returned no PR URL. Check GitHub before retrying; creation may have completed.", true, creationUncertain: true);
            var readback = await ReadAsync(url, approval.RepositoryRoot, token);
            if (!Uri.TryCreate(readback.Url, UriKind.Absolute, out var readUri) || readUri != new Uri(url) || !readback.IsDraft || readback.HeadRefName != approval.Branch || readback.BaseRefName != baseBranch)
                throw new GitHubRemoteActionException("A PR was created but its returned branch, base or draft state differs. Inspect it before continuing.", true, url);
            return readback;
        }
        catch (GitHubRemoteActionException) { throw; }
        catch (Exception error) when (pushSent || createSent)
        {
            throw new GitHubRemoteActionException(createSent
                ? "The branch was pushed and PR creation was attempted. Check GitHub before retrying. " + error.Message
                : pushed ? "The branch push completed, but a later check failed. Refresh before creating a PR. " + error.Message
                : "The push was attempted but could not be confirmed. Check the remote before retrying; no PR creation was attempted. " + error.Message,
                pushed, url, createSent, pushSent && !pushed);
        }
        finally { if (bodyFile is not null && File.Exists(bodyFile)) File.Delete(bodyFile); remoteGate.Release(); }
    }
    private async Task ValidateApprovalAsync(GitHubRemoteApproval approval, CancellationToken token)
    {
        await ValidateContextAsync(approval.RepositoryRoot, approval.Branch, approval.Head, token);
        var origin = Text(await RequiredAsync(git, ["remote", "get-url", "origin"], approval.RepositoryRoot, token));
        if (origin != approval.OriginUrl || !SupportedRemote(origin)) throw new StaleGitSnapshotException();
    }
    private async Task ValidateContextAsync(string root, string? branch, string? head, CancellationToken token)
    {
        var actualRoot = new WorkspacePathPolicy(Text(await RequiredAsync(git, ["rev-parse", "--show-toplevel"], root, token))).RootPath;
        var actualHead = Text(await RequiredAsync(git, ["rev-parse", "--verify", "HEAD"], root, token));
        var actualBranch = Text(await RequiredAsync(git, ["symbolic-ref", "--quiet", "--short", "HEAD"], root, token));
        if (actualRoot != new WorkspacePathPolicy(root).RootPath || actualHead != head || actualBranch != branch) throw new StaleGitSnapshotException();
    }
    private async Task<byte[]> RequiredAsync(string executable, IReadOnlyList<string> args, string directory, CancellationToken token)
    {
        CliResult result;
        try { result = await runner.RunAsync(new(executable, args, Path.GetFullPath(directory)), token); }
        catch (System.ComponentModel.Win32Exception) { throw new IOException("Install Git for Windows and GitHub CLI, then sign in with gh auth login before using this action."); }
        if (result.ExitCode != 0)
        {
            var message = Path.GetFileName(executable).StartsWith("gh", StringComparison.OrdinalIgnoreCase)
                ? "GitHub CLI failed (exit " + result.ExitCode + "). Check gh auth status and repository access."
                : "Git failed (exit " + result.ExitCode + "). Refresh Review and check repository/remote access.";
            throw new IOException(message); // CLI stderr may include private tokens, URLs or user content.
        }
        return result.Stdout;
    }
    public static bool ValidReference(string value)
    {
        if (int.TryParse(value, out var number) && number > 0 && value.All(char.IsAsciiDigit)) return true;
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0) return false;
        var parts = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length == 4 && parts[0] is not ("." or "..") && parts[1] is not ("." or "..") && parts[2] == "pull" && int.TryParse(parts[3], out number) && number > 0 && parts[3].All(char.IsAsciiDigit);
    }
    public static string DisplayOrigin(string origin)
    {
        if (Uri.TryCreate(origin, UriKind.Absolute, out var uri) && uri.Scheme is "https" or "ssh")
        { var safe = new UriBuilder(uri) { UserName = "", Password = "" }; return safe.Uri.ToString(); }
        return origin;
    }
    private static bool SupportedRemote(string origin) =>
        (Uri.TryCreate(origin, UriKind.Absolute, out var uri) && uri.Scheme is "https" or "ssh") ||
        Regex.IsMatch(origin, "^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[^\\r\\n]+$", RegexOptions.CultureInvariant);
    private static string Text(byte[] data) => new UTF8Encoding(false, true).GetString(data).TrimEnd('\r', '\n');
}

public sealed class OwnedCommandRunner : ICommandRunner
{
    public async Task<CliResult> RunAsync(CliInvocation command, CancellationToken token = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromMinutes(2));
        var start = new ProcessStartInfo(command.Executable) { WorkingDirectory = command.WorkingDirectory, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true };
        foreach (var key in start.Environment.Keys.Where(key => key.StartsWith("GIT_", StringComparison.OrdinalIgnoreCase)).ToArray()) start.Environment.Remove(key);
        start.Environment["GH_PROMPT_DISABLED"] = "1"; start.Environment["GIT_TERMINAL_PROMPT"] = "0"; start.Environment["LC_ALL"] = "C";
        foreach (var argument in command.Arguments) start.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = start }; if (!process.Start()) throw new IOException("The local CLI could not be started."); process.StandardInput.Close();
        using var registration = timeout.Token.Register(() => { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } });
        var stdout = ReadAsync(process.StandardOutput.BaseStream, 16 * 1024 * 1024, timeout);
        var stderr = ReadAsync(process.StandardError.BaseStream, 64 * 1024, timeout);
        await Task.WhenAll(stdout, stderr, process.WaitForExitAsync(timeout.Token));
        return new(process.ExitCode, await stdout, Encoding.UTF8.GetString(await stderr));
    }
    private static async Task<byte[]> ReadAsync(Stream input, int maximum, CancellationTokenSource timeout)
    {
        using var output = new MemoryStream(); var buffer = new byte[8192];
        while (await input.ReadAsync(buffer, timeout.Token) is var count && count > 0)
        {
            if (output.Length + count > maximum) { timeout.Cancel(); throw new InvalidDataException("The CLI output exceeded the supported bound."); }
            await output.WriteAsync(buffer.AsMemory(0, count), timeout.Token);
        }
        return output.ToArray();
    }
}
