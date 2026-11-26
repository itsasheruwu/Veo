using System.Diagnostics;

namespace Veo.Core;

public static class ComposerModePolicy
{
    static readonly SemaphoreSlim RefreshGate = new(1, 1);
    static readonly Dictionary<string, DateTimeOffset> LastRefresh = new(StringComparer.OrdinalIgnoreCase);
    const string Repository = "https://github.com/MSayib/roblox-dev-skill.git";
    public static bool IsProtected(ComposerSnapshot snapshot) => snapshot.Mode == "Ask" || snapshot.Mode == "Plan" && snapshot.Wild;
    public static bool RequiresNewTurn(ComposerSnapshot snapshot) => snapshot.Wild || snapshot.Mode is "Ask" or "Roblox";

    public static async Task<string?> GuidanceAsync(ComposerSnapshot snapshot, string profile, CancellationToken token)
    {
        var parts = new List<string>();
        if (snapshot.Mode == "Ask")
            parts.Add("Investigate and answer using read-only actions. Do not write files, request additional permissions, delegate execution, or call tools that modify external state.");
        if (snapshot.Mode == "Roblox")
        {
            var skill = await ResolveSkillAsync(Path.Combine(profile, "Cache", "RobloxDevSkill"), token);
            parts.Add($"Read the Roblox Dev Skill at {skill} and follow its routing to the relevant references. Use Roblox Studio MCP only if already configured and available.");
        }
        if (snapshot.Wild)
        {
            parts.Add("Research existing implementations and design references within the task's scope and current permissions. Respect third-party licenses.");
            if (snapshot.Mode == "Roblox")
                parts.Add("Focus on Roblox and Luau implementations, suitable Creator Store assets, and visual references for the experience.");
            if (IsProtected(snapshot))
                parts.Add("Keep research read-only. Do not generate files or implement changes.");
            else if (snapshot.Mode is "Agentic" or "Roblox")
                parts.Add("When supported, generate visual references when useful. Include requested image deliverables in the reply and keep internal reference images in activity.");
        }
        return parts.Count == 0 ? null : string.Join("\n\n", parts);
    }

    static async Task<string> ResolveSkillAsync(string folder, CancellationToken token)
    {
        await RefreshGate.WaitAsync(token);
        try
        {
            Directory.CreateDirectory(folder);
            var marker = Path.Combine(folder, "current");
            var previous = File.Exists(marker) ? SkillAt(await File.ReadAllTextAsync(marker, token)) : null;
            var now = DateTimeOffset.UtcNow;
            if (previous is not null)
            {
                var cachedAt = File.GetLastWriteTimeUtc(marker);
                if (now - LastRefresh.GetValueOrDefault(folder) < TimeSpan.FromMinutes(15)
                    || cachedAt <= now && now - cachedAt < TimeSpan.FromMinutes(15))
                    return previous;
            }
            var stage = Path.Combine(folder, "staging-" + Guid.NewGuid().ToString("N"));
            try
            {
                LastRefresh[folder] = now;
                await GitAsync(folder, token, "clone", "--quiet", "--depth=1", "--no-tags", Repository, stage);
                var revision = await GitAsync(stage, token, "rev-parse", "HEAD");
                if (!Revision(revision) || !Usable(stage))
                    throw new InvalidDataException("The upstream skill is incomplete.");
                var checkout = Path.Combine(folder, revision);
                if (!Directory.Exists(checkout)) Directory.Move(stage, checkout);
                var skill = SkillAt(revision) ?? throw new InvalidDataException("The cached skill is incomplete.");
                var pending = marker + ".tmp";
                await File.WriteAllTextAsync(pending, revision, token);
                File.Move(pending, marker, overwrite: true);
                return skill;
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
            catch (Exception error) when (error is IOException or InvalidOperationException or System.ComponentModel.Win32Exception or OperationCanceledException or UnauthorizedAccessException)
            { return previous ?? throw new InvalidOperationException("The Roblox Dev Skill is unavailable. Check Git and your GitHub connection, then try again.", error); }
            finally { if (Directory.Exists(stage)) try { Directory.Delete(stage, recursive: true); } catch (IOException) { } }

            string? SkillAt(string sha) => Revision(sha) && Usable(Path.Combine(folder, sha)) ? Path.Combine(folder, sha, "SKILL.md") : null;
        }
        finally { RefreshGate.Release(); }
    }

    static bool Revision(string value) => value.Length == 40 && value.All(char.IsAsciiHexDigitLower);
    static bool Usable(string path)
    {
        var skill = Path.Combine(path, "SKILL.md");
        return Directory.Exists(Path.Combine(path, "references")) && File.Exists(skill)
            && File.ReadLines(skill).Take(12).Any(line => line.Trim() == "name: roblox-dev-skill");
    }

    static async Task<string> GitAsync(string folder, CancellationToken token, params string[] arguments)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        var start = new ProcessStartInfo("git") { WorkingDirectory = folder, UseShellExecute = false,
            CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        start.Environment["GIT_TERMINAL_PROMPT"] = "0";
        start.Environment["GCM_INTERACTIVE"] = "never";
        foreach (var arg in new[] { "-c", "core.hooksPath=NUL", "-c", "core.symlinks=false", "-c", "credential.helper=" }.Concat(arguments))
            start.ArgumentList.Add(arg);
        using var process = Process.Start(start) ?? throw new IOException("Git did not start.");
        var output = process.StandardOutput.ReadToEndAsync(timeout.Token);
        var errors = process.StandardError.ReadToEndAsync(timeout.Token);
        try { await process.WaitForExitAsync(timeout.Token); }
        catch (OperationCanceledException) { if (!process.HasExited) process.Kill(entireProcessTree: true); throw; }
        await errors;
        if (process.ExitCode != 0) throw new IOException("Could not update the Roblox skill.");
        return (await output).Trim();
    }
}
