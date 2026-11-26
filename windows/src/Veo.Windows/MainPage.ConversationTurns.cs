using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Veo.Protocol;
using Veo_Windows.Controls;

namespace Veo_Windows;

public sealed partial class MainPage
{
    readonly HashSet<string> expandedWorkTurns = new(StringComparer.Ordinal);
    string? workThreadId;
    TimelineTurn? inspectedTurn;

    void UpdateConversationRows(ThreadSession session)
    {
        var items = ConversationRows(session);
        var signature = session.Record.VeoId + ":" + session.Timeline.IsRunning + ":" + workspace.Preferences.Streaming + ":" + session.LatestManagedGoalTurn;
        var refreshPresentation = presentationSignature != signature;
        presentationSignature = signature;
        if (messages.Count > 0 && !ReferenceEquals(messages[0].Session, session)) messages.Clear();
        var ids = items.Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
        for (var index = messages.Count - 1; index >= 0; index--)
            if (!ids.Contains(messages[index].Id)) messages.RemoveAt(index);
        var existing = messages.ToDictionary(row => row.Id, StringComparer.Ordinal);
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            if (!existing.TryGetValue(item.Id, out var row))
            {
                messages.Insert(index, new(session, item) { ToggleWork = ToggleWorkTurn, ReviewTurn = ReviewConversationTurnAsync,
                    AddConceptFeedback = (images, text) => AddConceptFeedbackAsync(session, images, text) });
                continue;
            }
            if (messages[index] != row) messages.Move(messages.IndexOf(row), index);
            if (!row.Item.HasSameContent(item)) row.Update(item);
            else if (refreshPresentation) row.RefreshPresentation();
        }
    }

    IReadOnlyList<TimelineItem> ConversationRows(ThreadSession session)
    {
        var items = session.Timeline.Items;
        if (workThreadId != session.Record.VeoId)
        {
            workThreadId = session.Record.VeoId;
            expandedWorkTurns.Clear();
            inspectedTurn = null;
            showEntireQueue = false;
        }
        var turns = session.Timeline.Turns.ToDictionary(turn => turn.Id);
        var groups = items.Where(item => item.TurnId is not null).ToLookup(item => item.TurnId!);
        var rows = new List<TimelineItem>(items.Count + turns.Count * 2);
        var liveTurnId = session.Timeline.IsRunning ? session.Timeline.ActiveTurnId : null;
        var segmentByItem = new Dictionary<string, string>(StringComparer.Ordinal);
        var activityBySegment = new Dictionary<string, List<TimelineItem>>(StringComparer.Ordinal);
        var lastPromptByTurn = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var item in items)
        {
            if (item.TurnId is not { } turnId) continue;
            if (item.Kind == "userMessage") lastPromptByTurn[turnId] = item.Id;
            else if (lastPromptByTurn.TryGetValue(turnId, out var segment) && IsFoldableWork(item))
            {
                segmentByItem[item.Id] = segment;
                if (!activityBySegment.TryGetValue(segment, out var activity)) activityBySegment[segment] = activity = [];
                activity.Add(item);
            }
        }
        var firstPrompts = groups.ToDictionary(group => group.Key, group => group.FirstOrDefault(item => item.Kind == "userMessage")?.Id);
        var lastReplies = groups.ToDictionary(group => group.Key, group => group.LastOrDefault(item => item.Kind == "agentMessage")?.Id);
        foreach (var item in items)
        {
            var turnId = item.TurnId;
            var turn = turnId is null ? null : turns.GetValueOrDefault(turnId);
            if (turn?.TerminalObserved == true && segmentByItem.TryGetValue(item.Id, out var activitySegment)
                && !expandedWorkTurns.Contains(activitySegment) && !IsFailedWork(item))
                continue;
            rows.Add(item);
            if (turn?.TerminalObserved == true && item.Kind == "userMessage")
            {
                var firstPrompt = item.Id == firstPrompts[turn.Id];
                var entries = activityBySegment.GetValueOrDefault(item.Id);
                if (firstPrompt || entries is { Count: > 0 })
                {
                    var status = expandedWorkTurns.Contains(item.Id) ? "expanded" : entries is { Count: > 0 } ? "collapsed" : "";
                    var kind = firstPrompt ? "veoTurnWork" : "veoTurnContinuation";
                    var summary = WorkSummary(entries ?? []);
                    rows.Add(new(kind + "-" + item.Id, turn.Id, kind, summary, status, item.Raw, item.Order));
                }
            }
            if (turn?.TerminalObserved == true && item.Id == lastReplies[turn.Id]
                && TurnPatch(turn, groups[turn.Id]) is { Length: > 0 } patch)
                rows.Add(new("turn-diff-" + turn.Id, turn.Id, "veoTurnDiff", patch, "", default, item.Order));
        }
        if (session.Timeline.IsRunning) rows.Add(ActiveStatus(session, items, liveTurnId));
        return TimelinePresentation.ProjectSpecialRows(rows);
    }

    async Task AddConceptFeedbackAsync(ThreadSession session, IReadOnlyList<(int Number, ConversationArtifact Artifact)> images, string feedback)
    {
        if (!ReferenceEquals(current, session)) return;
        var references = images.Select(image => $"- Concept {image.Number} ({(image.Artifact.Kind == "localImage" ? image.Artifact.Source : image.Artifact.Id)})");
        Composer.Text += (Composer.Text.Length > 0 ? "\n\n" : "") + "Feedback for generated concepts\n"
            + string.Join("\n", references) + "\n\n" + feedback;
        Composer.SelectionStart = Composer.Text.Length;
        Composer.Focus(FocusState.Programmatic);
        await SaveTypedComposerAsync();
    }

    TimelineItem ActiveStatus(ThreadSession session, IReadOnlyList<TimelineItem> items, string? turnId)
    {
        var runtimeId = session.Record.CodexThreadId;
        var request = workspace.PendingRequests.FirstOrDefault(request => runtimeId is not null && request.Parameters.Str("threadId") == runtimeId);
        var label = request?.Method switch
        {
            "item/tool/requestUserInput" => "Waiting for your answer",
            null => "",
            _ => "Waiting for approval"
        };
        var active = label.Length == 0 && turnId is not null
            ? items.Where(item => item.TurnId == turnId && IsFoldableWork(item)
                && item.Status is "inProgress" or "running" or "active" or "pending").ToArray() : [];
        var step = active.LastOrDefault(item => item.Kind != "reasoning") ?? active.LastOrDefault();
        if (step is not null)
        {
            label = step.Kind switch
            {
                "commandExecution" => step.Raw.Str("command") is { Length: > 0 } command
                    ? "Running " + command.ReplaceLineEndings(" ") : "Running a command",
                "fileChange" => "Updating files",
                "webSearch" => "Searching the web",
                "planUpdate" => "Updating the execution plan",
                _ => TimelinePresentation.Item(step).Title.ReplaceLineEndings(" ")
            };
        }
        return new("turn-work-active", turnId, "veoTurnProgress", label,
            step?.Kind ?? (request is null ? "" : "waitingForInput"), default, step?.Order ?? long.MaxValue);
    }

    static bool IsFoldableWork(TimelineItem item) => TimelinePresentation.IsActivity(item.Kind)
        && !TimelinePresentation.IsRoblox(item) && !TimelinePresentation.IsResearch(item) && item.Kind is not ("veoUserInputAnswer" or "plan" or "error") && item.Raw.Str("type") != "contextCompaction";
    static bool IsFailedWork(TimelineItem item) => item.Status is "failed" or "error"
        || item.Raw.ValueKind == System.Text.Json.JsonValueKind.Object && item.Raw.TryGetProperty("exitCode", out var exit) && exit.TryGetInt32(out var code) && code != 0;

    static string WorkSummary(IEnumerable<TimelineItem> entries)
    {
        var items = entries.ToArray();
        var files = items.Where(item => item.Kind == "fileChange").SelectMany(FileChanges)
            .Select(change => change.Str("path")).OfType<string>().Distinct(StringComparer.Ordinal).Count();
        var commands = items.Count(item => item.Kind == "commandExecution");
        var failure = items.FirstOrDefault(IsFailedWork);
        if (failure is not null) return "Failed: " + (failure.Raw.Str("command") ?? TimelinePresentation.Item(failure).Title).ReplaceLineEndings(" ");
        var parts = new List<string>();
        if (files > 0) parts.Add(files == 1 ? "Edited 1 file" : $"Edited {files} files");
        if (commands > 0) parts.Add(commands == 1 ? "Ran 1 command" : $"Ran {commands} commands");
        return string.Join(" · ", parts);
    }

    static IEnumerable<System.Text.Json.JsonElement> FileChanges(TimelineItem item)
    {
        if (item.Raw.ValueKind == System.Text.Json.JsonValueKind.Object && item.Raw.TryGetProperty("changes", out var list)
            && list.ValueKind == System.Text.Json.JsonValueKind.Array)
            return list.EnumerateArray().ToArray();
        return [];
    }

    static string TurnPatch(TimelineTurn turn, IEnumerable<TimelineItem> entries)
    {
        if (!string.IsNullOrWhiteSpace(turn.Diff)) return turn.Diff;
        return string.Join("\n", entries.Where(entry => entry.Kind == "fileChange").SelectMany(FileChanges)
            .Select(change => (Path: change.Str("path"), Patch: change.Str("diff")))
            .Where(change => !string.IsNullOrWhiteSpace(change.Path) && !string.IsNullOrWhiteSpace(change.Patch))
            .Select(change => $"diff --git a/{change.Path} b/{change.Path}\n{change.Patch}"));
    }

    void ToggleWorkTurn(string id)
    {
        if (!expandedWorkTurns.Add(id)) expandedWorkTurns.Remove(id);
        Render();
    }

    async Task ReviewConversationTurnAsync(TimelineItem row)
    {
        if (current?.Timeline.Turns.FirstOrDefault(turn => turn.Id == row.TurnId) is not { } turn) return;
        inspectedTurn = turn with { Diff = row.Text };
        await OpenUtilityPanelAsync(0);
    }

    FrameworkElement HistoricalDiffPanel(TimelineTurn turn)
    {
        var contents = new StackPanel { Spacing = 10, Padding = new(12) };
        var workspaceChanges = new Button { Content = "Workspace changes" };
        workspaceChanges.Click += async (_, _) => await Run(async () => { inspectedTurn = null; await ShowUtilityAsync(); });
        contents.Children.Add(new TextBlock { Text = "Changes from this turn", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        contents.Children.Add(workspaceChanges);
        foreach (var patch in ConversationPatch.Files(turn.Diff ?? ""))
        {
            var text = new TextBox { Text = patch.Text, IsReadOnly = true, AcceptsReturn = true,
                TextWrapping = TextWrapping.NoWrap, FontFamily = new("Cascadia Mono"), FontSize = 11, MaxHeight = 280 };
            ScrollViewer.SetHorizontalScrollBarVisibility(text, ScrollBarVisibility.Auto);
            AutomationProperties.SetName(text, "Diff for " + patch.Name);
            contents.Children.Add(new Expander { Header = patch.Name, Content = text, HorizontalAlignment = HorizontalAlignment.Stretch });
        }
        return new ScrollViewer { Content = contents };
    }
}
