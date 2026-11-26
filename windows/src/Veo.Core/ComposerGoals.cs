using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Veo.Protocol;

namespace Veo.Core;

public enum ComposerGoalMode { ProviderManaged, Loop, Gauntlet }

public static partial class ComposerGoals
{
    public static string Title(ComposerGoalMode mode) => mode switch
    {
        ComposerGoalMode.Loop => "Loop",
        ComposerGoalMode.Gauntlet => "Gauntlet",
        _ => "Provider-managed"
    };

    public static string Description(ComposerGoalMode mode) => mode switch
    {
        ComposerGoalMode.Loop => "Repeat until the goal is met.",
        ComposerGoalMode.Gauntlet => "Build, compare, and revise.",
        _ => "Use the provider’s built-in goal."
    };

    [GeneratedRegex(@"\bevery\s+(\d+)\s*(seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h)\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex CadencePattern();

    [GeneratedRegex(@"(?:^|\n)[ \t]*VEO_GOAL: (COMPLETE|WAIT|CONTINUE ([0-9]+))[ \t]*\r?\n?\z", RegexOptions.CultureInvariant)]
    private static partial Regex DirectivePattern();

    internal static int? FixedCadence(string objective)
    {
        var match = CadencePattern().Match(objective);
        if (!match.Success || !double.TryParse(match.Groups[1].Value, CultureInfo.InvariantCulture, out var amount)) return null;
        var unit = char.ToLowerInvariant(match.Groups[2].Value[0]);
        return ClampDelay(amount * (unit == 'h' ? 3600 : unit == 'm' ? 60 : 1));
    }

    static int ClampDelay(double seconds) => (int)Math.Clamp(seconds, 10, 86_400);

    internal static (string Action, int? Delay) Directive(string text)
    {
        var match = DirectivePattern().Match(text.TrimEnd());
        if (!match.Success) return ("", null);
        if (!match.Groups[2].Success) return (match.Groups[1].Value, null);
        return double.TryParse(match.Groups[2].Value, CultureInfo.InvariantCulture, out var seconds)
            ? ("CONTINUE", ClampDelay(seconds)) : ("", null);
    }

    public static string VisibleReply(string text) => DirectivePattern().Replace(text.TrimEnd(), "").TrimEnd();

    // Gauntlet follows Matt Shumer's workflow as packaged by Jay E (RoboNuggets) in gauntlet-loop.
    internal static string Guidance(ComposerGoalMode mode, string objective, bool firstTurn) =>
        (mode == ComposerGoalMode.Loop ? """
        This is a Veo Loop goal. Make one useful pass on the saved objective now. Give the user a concise update and verify any claimed outcome. If further work or observation is needed, select a local delay appropriate to the task. If it needs user input or is blocked, ask for it and wait. Complete only when you verify the requested outcome. For an ongoing monitor with no requested terminal outcome, keep scheduling until the user stops it.
        """ : """
        This is a Veo Gauntlet goal. Before building, use the concrete benchmark the user chose. A valid benchmark is a named, accessible, comparable artifact. If none was chosen, recommend two or three real candidates and ask the user to choose, then wait. Confirm the benchmark can be inspected. Break the work into reviewable pieces and delegate scoped builder work where supported. Use an independent critic with fresh context, separate from the builder, to inspect the real artifacts. Hide which candidate is ours, compare A and B using equivalent conditions, and ask for a binary winner with concrete reasons. When ours loses, continue in 10 seconds unless the work needs a longer delay. Revise using the critique and compare again. Complete only after an independent comparison favors ours and the requested work is verified. If separate reviewer tools or benchmark access are unavailable, explain the blocker and wait. Do not invent a review or use a fixed round count as a success condition.
        """) + (firstTurn ? "" : "\nThe original saved objective follows. The latest user message may supply a benchmark choice or other clarification.\n\n" + objective)
        + "\n\nEnd the final assistant message with one exact standalone control line: VEO_GOAL: COMPLETE, VEO_GOAL: WAIT, or VEO_GOAL: CONTINUE <whole seconds>. Include no text after that line. Follow the requested scope, permissions, and approval requirements. Do not create a separate scheduler.";
}

internal sealed record LocalGoalRun(ComposerGoalMode Mode, string Objective, ComposerSnapshot Settings,
    string Workspace, string? RuntimeThread, int? FixedSeconds, string? PendingClientId = null, string? TurnId = null,
    DateTimeOffset? NextRun = null, string? PausedReason = null);

internal sealed record ComposerGoalState(ComposerGoalMode Mode = ComposerGoalMode.ProviderManaged,
    LocalGoalRun? Run = null, string[]? ManagedTurns = null);

internal sealed class ManagedGoalCoordinator(WorkspaceCoordinator workspace, CancellationToken lifetime)
{
    const string Key = "composer-goal";
    readonly ConcurrentDictionary<string, ThreadSession> running = new(StringComparer.Ordinal);

    public async Task LoadAsync(ThreadSession session)
    {
        if (await workspace.Threads.ReadStateAsync(session.Record.VeoId, Key, lifetime) is not { } saved) return;
        try { session.GoalState = JsonSerializer.Deserialize<ComposerGoalState>(saved) ?? new(); }
        catch (JsonException) { return; }
        if (session.GoalState.Run is not null) running[session.Record.VeoId] = session;
    }

    public Task SelectAsync(ThreadSession session, ComposerGoalMode mode, CancellationToken token) =>
        SaveAsync(session, session.GoalState with { Mode = mode }, token);

    public Task StopAsync(ThreadSession session, CancellationToken token) => session.GoalState.Run is null
        ? Task.CompletedTask : SaveAsync(session, session.GoalState with { Run = null }, token);

    public async Task<LocalGoalRun?> PrepareAsync(ThreadSession session, ComposerSnapshot payload)
    {
        var run = session.GoalState.Run;
        if (run is null && payload is { StartGoal: true, GoalMode: not ComposerGoalMode.ProviderManaged })
            run = new(payload.GoalMode, payload.Text.Trim(), payload.Freeze(), session.Record.Cwd, session.Record.CodexThreadId,
                payload.GoalMode == ComposerGoalMode.Loop ? ComposerGoals.FixedCadence(payload.Text) : null);
        if (run is null) return null;
        if (session.Record.Cwd != run.Workspace || session.Record.CodexThreadId != run.RuntimeThread)
            throw new InvalidOperationException("The goal’s workspace changed. Stop this goal and start a new one in this chat.");
        await SaveAsync(session, session.GoalState with { Run = run with
        {
            PendingClientId = payload.ClientId, TurnId = null, NextRun = null, PausedReason = null
        } }, lifetime);
        return run;
    }

    public async Task AcknowledgeAsync(ThreadSession session, string clientId, string turnId)
    {
        if (session.GoalState.Run is not { } run || run.PendingClientId != clientId) return;
        var recent = (session.GoalState.ManagedTurns ?? []).Append(turnId).Distinct().TakeLast(128).ToArray();
        await SaveAsync(session, session.GoalState with { Run = run with { TurnId = turnId }, ManagedTurns = recent }, lifetime);
    }

    async Task SaveAsync(ThreadSession session, ComposerGoalState state, CancellationToken token)
    {
        await workspace.Threads.SaveStateAsync(session.Record.VeoId, Key, JsonSerializer.Serialize(state), token);
        session.GoalState = state;
        if (state.Run is null) running.TryRemove(session.Record.VeoId, out _);
        else running[session.Record.VeoId] = session;
        workspace.NotifyChanged();
    }

    Task PauseAsync(ThreadSession session, LocalGoalRun run, string reason) => SaveAsync(session,
        session.GoalState with { Run = run with { NextRun = null, PendingClientId = null, TurnId = null, PausedReason = reason } }, lifetime);

    public async Task<bool> ObserveCompletionAsync(ThreadSession session)
    {
        if (session.Timeline.IsRunning || session.GoalState.Run is not { TurnId: { } turnId } run) return false;
        var turn = session.Timeline.Turns.LastOrDefault(item => item.Id == turnId);
        var reply = session.Timeline.Items.LastOrDefault(item => item.TurnId == turnId && item.Kind == "agentMessage");
        if (turn is not { TerminalObserved: true, Status: "completed", ErrorJson: null } || reply is null)
        {
            await PauseAsync(session, run, "The last goal turn did not confirm success. Send a message to continue.");
            return true;
        }
        var verdict = ComposerGoals.Directive(reply.Text);
        if (verdict.Action == "COMPLETE") await StopAsync(session, lifetime);
        else if (verdict.Delay is { } delay)
        {
            var next = (turn.CompletedAt ?? DateTimeOffset.UtcNow).AddSeconds(run.FixedSeconds ?? delay);
            await SaveAsync(session, session.GoalState with { Run = run with { PendingClientId = null, TurnId = null, NextRun = next } }, lifetime);
        }
        else await PauseAsync(session, run, verdict.Action == "WAIT" ? "Waiting for your reply." : "The last turn did not report a next step. Send a message to continue.");
        return true;
    }

    public async Task RunAsync()
    {
        try
        {
            foreach (var (id, json) in await workspace.Threads.ReadStatesAsync(Key, lifetime))
            {
                ComposerGoalState? state;
                try { state = JsonSerializer.Deserialize<ComposerGoalState>(json); }
                catch (JsonException) { continue; }
                if (state?.Run is null || workspace.LoadedSessions.FirstOrDefault(item => item.Record.VeoId == id) is not { } session) continue;
                try { await workspace.LoadAsync(session.Record); }
                catch (Exception ex) when (!lifetime.IsCancellationRequested) { _ = ex; }
            }
            using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
            while (await timer.WaitForNextTickAsync(lifetime))
            {
                foreach (var session in running.Values)
                {
                    if (session.IsSubmitting || session.Timeline.IsRunning || !await session.DispatchGate.WaitAsync(0, lifetime)) continue;
                    try { await ReconcileAsync(session); }
                    catch (Exception error) when (!lifetime.IsCancellationRequested)
                    {
                        if (session.GoalState.Run is { } run) await PauseAsync(session, run, DiagnosticRedactor.Redact(error.Message));
                    }
                    finally { session.DispatchGate.Release(); }
                }
            }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    }

    async Task ReconcileAsync(ThreadSession session)
    {
        if (!session.IsLoaded || session.GoalState.Run is not { PausedReason: null } run) return;
        if (session.Record.IsArchived || session.Record.Cwd != run.Workspace || session.Record.CodexThreadId != run.RuntimeThread)
        {
            await PauseAsync(session, run, "The workspace changed. Stop this goal before starting it in another workspace.");
            return;
        }
        if (workspace.Runtime.RuntimeState != CodexRuntimeState.Ready || session.Timeline.IsRunning) return;
        if (session.DispatchWarning is not null || run is { PendingClientId: not null, TurnId: null })
        {
            await PauseAsync(session, run, "The last goal send is uncertain. Inspect the chat before continuing.");
            return;
        }
        if (await ObserveCompletionAsync(session)) return;
        if (run.NextRun is not { } due || due > DateTimeOffset.UtcNow || session.Queue.Count > 0) return;
        var nextTurn = run.Settings with
        {
            ClientId = Guid.NewGuid().ToString("N"), Text = "Continue this " + ComposerGoals.Title(run.Mode) + " goal.",
            StartGoal = false, Attachments = [], StructuredAttachments = [], PreserveDraft = true
        };
        await workspace.RunManagedGoalTurnAsync(session, nextTurn);
    }
}
