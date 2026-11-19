using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Veo.Infrastructure.PromptLibrary;

namespace Veo_Windows.Controls;

public sealed class PromptLibraryPanel : UserControl
{
    private readonly WorkspaceCoordinator workspace;
    private readonly PromptLibraryService library;
    private readonly Func<ThreadSession?> selected;
    private readonly Func<string>? draftText;
    private readonly Func<string[]>? attachmentPaths;
    private readonly Func<ThreadSession, string, string[], Task> applyDraft;
    private readonly Func<ThreadSession, string, IReadOnlyList<PromptAttachment>, Task>? applyTypedDraft;
    private readonly Func<ThreadSession, ComposerDraft>? readCompleteDraft;
    private readonly Func<ThreadSession, ComposerDraft, Task>? applyCompleteDraft;
    private readonly ListView prompts = new() { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 280, ItemContainerTransitions = new() };
    private readonly TextBox search = new() { PlaceholderText = "Search saved prompts" };
    private readonly TextBox preview = new() { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 200 };
    private readonly TextBlock details = new() { TextWrapping = TextWrapping.Wrap };
    private readonly InfoBar notice = new() { IsOpen = false, IsClosable = true };
    private readonly CheckBox deleteConfirmation = new() { Content = "Delete this saved prompt and its library media copies", Visibility = Visibility.Collapsed };
    private readonly ProgressBar progress = new() { IsIndeterminate = true, Visibility = Visibility.Collapsed };
    private readonly SemaphoreSlim gate = new(1, 1);
    public PromptLibraryPanel(WorkspaceCoordinator workspace, Func<ThreadSession?> selected, Func<string>? draftText = null,
        Func<string[]>? attachmentPaths = null, Func<ThreadSession, string, string[], Task>? applyDraft = null,
        Func<ThreadSession, string, IReadOnlyList<PromptAttachment>, Task>? applyTypedDraft = null,
        Func<ThreadSession, ComposerDraft>? readCompleteDraft = null, Func<ThreadSession, ComposerDraft, Task>? applyCompleteDraft = null)
    {
        this.workspace = workspace; this.selected = selected; this.draftText = draftText; this.attachmentPaths = attachmentPaths;
        this.applyDraft = applyDraft ?? ((session, text, paths) => workspace.SaveDraftAsync(session, text, paths));
        this.applyTypedDraft = applyTypedDraft;
        this.readCompleteDraft = readCompleteDraft; this.applyCompleteDraft = applyCompleteDraft;
        library = new(workspace.DataRoot);
        var body = new StackPanel { Spacing = 10 };
        var bar = new CommandBar { DefaultLabelPosition = CommandBarDefaultLabelPosition.Right };
        var save = new AppBarButton { Label = "Save current draft", Icon = new SymbolIcon(Symbol.Save) };
        var restore = new AppBarButton { Label = "Add selected to draft", Icon = new SymbolIcon(Symbol.Add) };
        var delete = new AppBarButton { Label = "Delete selected prompt", Icon = new SymbolIcon(Symbol.Delete) };
        var refresh = new AppBarButton { Label = "Refresh library", Icon = new SymbolIcon(Symbol.Refresh) };
        bar.PrimaryCommands.Add(save); bar.PrimaryCommands.Add(restore); bar.SecondaryCommands.Add(delete); bar.SecondaryCommands.Add(refresh);
        save.Click += async (_, _) => await RunAsync(SaveAsync);
        restore.Click += async (_, _) => await RunAsync(RestoreAsync);
        refresh.Click += async (_, _) => await RunAsync(RefreshAsync);
        delete.Click += async (_, _) => await RunAsync(DeleteAsync);
        search.TextChanged += async (_, _) => await RunAsync(RefreshAsync);
        prompts.SelectionChanged += (_, _) =>
        {
            deleteConfirmation.IsChecked = false; deleteConfirmation.Visibility = Visibility.Collapsed;
            if (prompts.SelectedItem is SavedPrompt prompt) { preview.Text = prompt.Text; details.Text = prompt.WorkspacePath + " · " + prompt.Attachments.Count + " attachment(s) · " + prompt.CreatedAt.ToLocalTime().ToString("g"); }
            else { preview.Text = ""; details.Text = ""; }
        };
        AutomationProperties.SetName(prompts, "Saved prompts"); AutomationProperties.SetName(search, "Search saved prompts");
        body.Children.Add(bar); body.Children.Add(progress); body.Children.Add(search); body.Children.Add(prompts); body.Children.Add(details);
        body.Children.Add(preview); body.Children.Add(deleteConfirmation); body.Children.Add(notice);
        Content = body; Loaded += async (_, _) => await RunAsync(RefreshAsync);
    }
    private async Task RefreshAsync()
    {
        prompts.ItemsSource = await library.ListAsync(search.Text);
        if (prompts.Items.Count == 0) details.Text = "No saved prompts. Save the current draft to keep it for later.";
    }
    private async Task SaveAsync()
    {
        var session = selected() ?? throw new InvalidOperationException("Open a chat before saving its draft.");
        if (readCompleteDraft is not null)
        {
            await SaveCompleteDraftAsync(library, session, readCompleteDraft, ApplyCompleteAsync);
            await RefreshAsync(); return;
        }
        var text = draftText?.Invoke() ?? session.Draft.Text;
        var paths = attachmentPaths?.Invoke() ?? JsonSerializer.Deserialize<string[]>(session.Draft.AttachmentsJson) ?? [];
        var attachments = paths.Select(path => new PromptAttachment(IsAudio(path) ? PromptAttachmentKind.LocalAudio : PromptAttachmentKind.LocalImage, path, Path.GetFileName(path))).ToArray();
        await library.SaveAsync(text, attachments, session.Record.Cwd);
        var currentText = selected() == session && draftText is not null ? draftText() : session.Draft.Text;
        var currentPaths = selected() == session && attachmentPaths is not null ? attachmentPaths() : JsonSerializer.Deserialize<string[]>(session.Draft.AttachmentsJson) ?? [];
        if (currentText == text && currentPaths.SequenceEqual(paths)) await applyDraft(session, "", []);
        await RefreshAsync();
    }

    internal static async Task SaveCompleteDraftAsync(PromptLibraryService library, ThreadSession session,
        Func<ThreadSession, ComposerDraft> readDraft, Func<ThreadSession, ComposerDraft, Task> applyDraft)
    {
        var captured = readDraft(session);
        await library.SaveAsync(captured.Text, captured.Attachments.Select(attachment => attachment.ToPromptAttachment()).ToArray(), session.Record.Cwd);
        var latest = readDraft(session);
        if (latest.Text == captured.Text && latest.Attachments.SequenceEqual(captured.Attachments))
            await applyDraft(session, latest with { Text = "", Attachments = [], UpdatedAt = DateTimeOffset.UtcNow });
    }

    internal static async Task RestoreCompleteDraftAsync(PromptLibraryService library, SavedPrompt prompt, ThreadSession session,
        Func<ThreadSession, ComposerDraft> readDraft, Func<ThreadSession, ComposerDraft, Task> applyDraft)
    {
        var restored = await library.RestoreAsync(prompt.Id, session.Record.Cwd);
        var latest = readDraft(session);
        await applyDraft(session, latest.Append(restored.Text, restored.Attachments.Select(ComposerAttachment.FromPromptAttachment)));
    }

    private async Task RestoreAsync()
    {
        var prompt = prompts.SelectedItem as SavedPrompt ?? throw new InvalidOperationException("Choose a saved prompt.");
        var session = selected() ?? throw new InvalidOperationException("Open a chat before restoring a prompt.");
        if (readCompleteDraft is not null)
        {
            await RestoreCompleteDraftAsync(library, prompt, session, readCompleteDraft, ApplyCompleteAsync);
            return;
        }
        if (applyTypedDraft is null && prompt.Attachments.Any(a => a.Kind is not (PromptAttachmentKind.LocalImage or PromptAttachmentKind.LocalAudio)))
            throw new NotSupportedException("This prompt contains structured file/skill references or remote media. This composer requires typed-attachment support before it can restore the complete prompt.");
        var restored = await library.RestoreAsync(prompt.Id, session.Record.Cwd);
        var text = selected() == session && draftText is not null ? draftText() : session.Draft.Text;
        var paths = selected() == session && attachmentPaths is not null ? attachmentPaths() : JsonSerializer.Deserialize<string[]>(session.Draft.AttachmentsJson) ?? [];
        var media = restored.Attachments.Where(a => a.Kind is PromptAttachmentKind.LocalImage or PromptAttachmentKind.LocalAudio).Select(a => a.Source);
        if (applyTypedDraft is not null)
        { await applyTypedDraft(session, text + (text.Length == 0 ? "" : "\n\n") + restored.Text, restored.Attachments); return; }
        await applyDraft(session, text + (text.Length == 0 ? "" : "\n\n") + restored.Text, paths.Concat(media).ToArray());
    }
    private async Task DeleteAsync()
    {
        var prompt = prompts.SelectedItem as SavedPrompt ?? throw new InvalidOperationException("Choose a saved prompt.");
        if (deleteConfirmation.IsChecked != true)
        {
            deleteConfirmation.Visibility = Visibility.Visible; notice.Severity = InfoBarSeverity.Informational; notice.Title = "Confirm removal";
            notice.Message = "Confirm below, then choose Delete selected prompt again. Copies already restored to drafts are kept."; notice.IsOpen = true; return;
        }
        await library.RemoveAsync(prompt.Id); deleteConfirmation.IsChecked = false; deleteConfirmation.Visibility = Visibility.Collapsed; await RefreshAsync();
    }
    private Task ApplyCompleteAsync(ThreadSession session, ComposerDraft draft) => applyCompleteDraft is not null ? applyCompleteDraft(session, draft) : ComposerDraft.SaveAsync(workspace, session, draft);
    private async Task RunAsync(Func<Task> action)
    {
        if (!await gate.WaitAsync(0)) return;
        progress.Visibility = Visibility.Visible; notice.IsOpen = false;
        try { await action(); }
        catch (Exception error) { notice.Title = "Prompt library action failed"; notice.Message = error.Message; notice.Severity = InfoBarSeverity.Error; notice.IsOpen = true; }
        finally { progress.Visibility = Visibility.Collapsed; gate.Release(); }
    }
    private static bool IsAudio(string path) => new[] { ".mp3", ".wav", ".m4a", ".flac", ".ogg", ".aac" }.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);
}
