using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Veo.Core;
using Veo.Infrastructure.Files;
using Veo.Protocol;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace Veo_Windows;

public sealed partial class MainPage
{
    readonly List<ComposerAttachment> typedComposerAttachments = [];
    readonly StackPanel composerAttachmentRows = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    readonly ScrollViewer composerAttachmentStrip = new()
    {
        HorizontalScrollMode = ScrollMode.Enabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Visibility = Visibility.Collapsed
    };
    readonly ListView composerSuggestions = new()
    {
        SelectionMode = ListViewSelectionMode.Single, MaxHeight = 175, Visibility = Visibility.Collapsed, ItemContainerTransitions = new()
    };
    readonly SemaphoreSlim composerWrites = new(1, 1);
    readonly SemaphoreSlim composerSubmits = new(1, 1);
    ComposerSuggestionService? suggestionService;
    ComposerCompletionToken? displayedCompletion;
    CancellationTokenSource? completionCancellation;
    string? composerThreadId;
    long composerRevision;
    bool composerControlsReady;
    string? skillCacheKey;
    DateTimeOffset skillCacheAt;

    void InitializeComposerControls()
    {
        if (composerControlsReady) return; composerControlsReady = true;
        suggestionService = new(App.Commands, new WorkspaceCoordinatorRpc(workspace));
        InitializeComposerModePills();
        composerAttachmentStrip.Content = composerAttachmentRows;
        ComposerInputs.Children.Add(composerSuggestions);
        ComposerInputs.Children.Add(composerAttachmentStrip);
        AutomationProperties.SetAutomationId(composerSuggestions, "ComposerSuggestions"); AutomationProperties.SetName(composerSuggestions, "Composer suggestions");
        Composer.SelectionChanged += (_, _) => { if (!loading) _ = RefreshCompletionsAsync(); };
        Composer.Paste += ComposerPaste;
    }
    /// <summary>Selection owns model/access resolution; this only restores text and typed inputs.</summary>
    void RestoreComposerDraft(ThreadSession session)
    {
        var draft = ComposerDraft.Read(session.Draft); composerThreadId = session.Record.VeoId; composerRevision++;
        typedComposerAttachments.Clear(); typedComposerAttachments.AddRange(draft.Attachments); SyncLegacyAttachments();
        Composer.Text = draft.Text; CloseCompletions(); RefreshAttachmentRows();
    }
    ComposerSnapshot ComposerDefaults() => new(Guid.NewGuid().ToString("N"), "", model, effort, tier,
        composerAccess, composerMode, [],
        ContextTokens: contextTokens, RoutingMode: routingMode, RouterPolicy: routerPolicy, FamilyPlan: familyPlan,
        CatalogModelId: modelCatalogId, Daybreak: composerDaybreak);
    ComposerDraft CaptureComposerDraft(ThreadSession session)
    {
        var saved = ComposerDraft.Read(session.Draft);
        if (current?.Record.VeoId != session.Record.VeoId) return saved.Freeze();
        if (composerThreadId != session.Record.VeoId) { composerThreadId = session.Record.VeoId; typedComposerAttachments.Clear(); typedComposerAttachments.AddRange(saved.Attachments); SyncLegacyAttachments(); }
        return (saved with { Text = Composer.Text, Attachments = typedComposerAttachments.ToArray(), UpdatedAt = DateTimeOffset.UtcNow }).WithSettings(ComposerDefaults()).Freeze();
    }
    async Task SaveTypedComposerAsync()
    {
        draftDelay?.Cancel(); if (current is not { } session || loading) return;
        var captured = CaptureComposerDraft(session); await SaveCompleteDraftAsync(session, captured);
    }
    async Task SaveCompleteDraftAsync(ThreadSession session, ComposerDraft draft)
    {
        await composerWrites.WaitAsync(); try { await ComposerDraft.SaveAsync(workspace, session, draft.Freeze()); } finally { composerWrites.Release(); }
    }
    async Task ApplyCompleteLibraryDraftAsync(ThreadSession session, ComposerDraft draft)
    {
        await SaveCompleteDraftAsync(session, draft);
        if (current?.Record.VeoId != session.Record.VeoId) return;
        var wasLoading = loading; loading = true; try { RestoreComposerDraft(session); } finally { loading = wasLoading; } Render();
    }
    async Task SubmitTypedComposerAsync()
    {
        if (!await composerSubmits.WaitAsync(0)) return;
        try
        {
            if (current is not { } session) return; var captured = CaptureComposerDraft(session);
            if (string.IsNullOrWhiteSpace(captured.Text) && captured.Attachments.Length == 0) return;
            var revision = composerRevision;
            if (captured.Text.StartsWith('/'))
            {
                if (await ExecuteCommandAsync(captured.Text))
                {
                    if (current?.Record.VeoId == session.Record.VeoId && Composer.Text == captured.Text) { Composer.Text = ""; await SaveTypedComposerAsync(); }
                    return;
                }
                if (current?.Record.VeoId != session.Record.VeoId) return;
                // Commands such as /plan with prompt text can update settings before ordinary submission.
                captured = CaptureComposerDraft(session); revision = composerRevision;
            }
            // UI owns conditional clearing, so edits made while routing/sending cannot be erased by the runtime coordinator.
            var snapshot = captured.Snapshot(defaults: ComposerDefaults()) with
            {
                PreserveDraft = true,
                StartGoal = session.ComposerGoalArmed && App.ThreadSettings.ActiveGoal(session) is null
            };
            await SaveCompleteDraftAsync(session, captured);
            await workspace.SubmitAsync(session, snapshot);
            if (current?.Record.VeoId == session.Record.VeoId)
            {
                if (revision == composerRevision && Composer.Text == captured.Text && typedComposerAttachments.SequenceEqual(captured.Attachments))
                {
                    var wasLoading = loading; loading = true; try { Composer.Text = ""; typedComposerAttachments.Clear(); SyncLegacyAttachments(); composerRevision++; RefreshAttachmentRows(); } finally { loading = wasLoading; }
                    await SaveCompleteDraftAsync(session, captured with { Text = "", Attachments = [], UpdatedAt = DateTimeOffset.UtcNow });
                }
                else await SaveTypedComposerAsync();
            }
            else
            {
                var latest = ComposerDraft.Read(session.Draft);
                if (latest.Text == captured.Text && latest.Attachments.SequenceEqual(captured.Attachments)) await SaveCompleteDraftAsync(session, latest with { Text = "", Attachments = [], UpdatedAt = DateTimeOffset.UtcNow });
            }
            CloseCompletions(); Render(); await RefreshCatalogAsync();
        }
        finally { composerSubmits.Release(); }
    }
    void SyncLegacyAttachments() { attachments.Clear(); attachments.AddRange(typedComposerAttachments.Where(x => x.Kind == ComposerAttachmentKind.LocalImage).Select(x => x.Source)); }
    void RefreshAttachmentRows()
    {
        composerAttachmentRows.Children.Clear();
        foreach (var attachment in typedComposerAttachments.ToArray())
        {
            var kind = AttachmentKind(attachment.Kind);
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            row.Children.Add(new FontIcon { Glyph = "\uE8A5", FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
            var label = new TextBlock { Text = attachment.Name, FontSize = 12, MaxWidth = 200, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetName(label, attachment.Name + ", " + kind);
            row.Children.Add(label);
            var remove = new Button
            {
                Content = new FontIcon { Glyph = "\uE711", FontSize = 9 },
                Width = 24, Height = 24, MinWidth = 0, MinHeight = 0, Padding = new Thickness(0)
            };
            if (Application.Current.Resources.TryGetValue("SubtleButtonStyle", out var style) && style is Style subtle)
                remove.Style = subtle;
            AutomationProperties.SetName(remove, "Remove " + attachment.Name);
            AutomationProperties.SetAutomationId(remove, "RemoveAttachment_" + attachment.Id);
            row.Children.Add(remove);
            remove.Click += async (_, _) => await Run(async () =>
            {
                if (!typedComposerAttachments.Remove(attachment)) return;
                composerRevision++; SyncLegacyAttachments(); RefreshAttachmentRows(); await SaveTypedComposerAsync();
            });
            var chip = new Border { Child = row, Style = (Style)Resources["ComposerAttachmentChip"] };
            ToolTipService.SetToolTip(chip, kind + " · " + attachment.Source);
            composerAttachmentRows.Children.Add(chip);
        }
        composerAttachmentStrip.Visibility = typedComposerAttachments.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateComposerInputStrip();
        UpdateSendAvailability();
    }
    static string AttachmentKind(ComposerAttachmentKind kind) => kind switch { ComposerAttachmentKind.LocalImage or ComposerAttachmentKind.Image => "Image", ComposerAttachmentKind.LocalAudio or ComposerAttachmentKind.Audio => "Audio", ComposerAttachmentKind.Skill => "Skill", _ => "File reference" };
    void CancelCompletionQuery() { var previous = completionCancellation; completionCancellation = null; previous?.Cancel(); previous?.Dispose(); }
    void CloseCompletions()
    {
        CancelCompletionQuery(); displayedCompletion = null; composerSuggestions.Items.Clear(); composerSuggestions.Visibility = Visibility.Collapsed;
        UpdateComposerInputStrip();
    }
    void UpdateComposerInputStrip() => ComposerInputs.Visibility =
        composerSuggestions.Visibility == Visibility.Visible || composerAttachmentStrip.Visibility == Visibility.Visible
            ? Visibility.Visible : Visibility.Collapsed;
    async Task RefreshCompletionsAsync()
    {
        CancelCompletionQuery(); if (loading || !initialized || current is not { } session || suggestionService is null) { CloseCompletions(); return; }
        var token = ComposerCompletionToken.Parse(Composer.Text, Composer.SelectionStart, Composer.SelectionLength, imeComposing); if (token is null) { CloseCompletions(); return; }
        var cancellation = completionCancellation = new();
        try
        {
            await Task.Delay(140, cancellation.Token); var context = IntegrationContext.For(session); var skills = App.Integrations.Snapshot(context).Skills;
            var skillKey = context.Key + "|" + workspace.Runtime.Generation;
            if (token.Trigger == '$' && (skillCacheKey != skillKey || DateTimeOffset.UtcNow - skillCacheAt > TimeSpan.FromSeconds(15))) { skills = await App.Integrations.RefreshSkillsAsync(context, cancellation.Token); skillCacheKey = skillKey; skillCacheAt = DateTimeOffset.UtcNow; }
            var suggestions = await suggestionService.QueryAsync(session, token, skills, cancellation.Token);
            if (cancellation.IsCancellationRequested || current?.Record.VeoId != session.Record.VeoId || Composer.Text != token.Text || imeComposing) return;
            displayedCompletion = token; composerSuggestions.Items.Clear(); var index = 0;
            foreach (var suggestion in suggestions)
            {
                var content = new StackPanel { Spacing = 2 };
                content.Children.Add(new TextBlock { Text = suggestion.Title, FontSize = 12.5, FontWeight = Microsoft.UI.Text.FontWeights.Medium });
                var hasDetail = !string.IsNullOrWhiteSpace(suggestion.Description) && suggestion.Description != suggestion.Title;
                if (hasDetail)
                    content.Children.Add(new TextBlock { Text = suggestion.Description, TextWrapping = TextWrapping.Wrap, FontSize = 10.5, Opacity = .72 });
                var button = new Button
                {
                    Content = content,
                    Style = (Style)Resources["ComposerChromeButton"],
                    Padding = new Thickness(9, 4, 9, 4),
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Left,
                    AllowFocusOnInteraction = false
                };
                AutomationProperties.SetName(button, hasDetail ? suggestion.Title + ". " + suggestion.Description : suggestion.Title);
                AutomationProperties.SetAutomationId(button, "ComposerSuggestion_" + index++);
                button.Click += async (_, _) => await Run(() => ApplyCompletionAsync(suggestion, token));
                composerSuggestions.Items.Add(new ListViewItem
                {
                    Content = button, Tag = suggestion, Padding = new Thickness(0),
                    HorizontalContentAlignment = HorizontalAlignment.Stretch, AllowFocusOnInteraction = false
                });
            }
            composerSuggestions.Visibility = suggestions.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            if (suggestions.Count > 0) composerSuggestions.SelectedIndex = 0;
            UpdateComposerInputStrip();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception error) { if (!cancellation.IsCancellationRequested) { CloseCompletions(); Notice.Severity = InfoBarSeverity.Warning; Notice.Message = DiagnosticRedactor.Redact(error.Message); Notice.IsOpen = true; } }
    }
    async Task ApplyCompletionAsync(ComposerSuggestion suggestion, ComposerCompletionToken token)
    {
        if (current is not { } session || !ReferenceEquals(displayedCompletion, token) || Composer.Text != token.Text || imeComposing) return;
        if (suggestion.Kind == ComposerSuggestionKind.Command)
        { var invocation = suggestion.Command?.SlashName is { } slash ? "/" + slash : throw new InvalidOperationException("This command suggestion is unavailable."); if (await ExecuteCommandAsync(invocation) && current?.Record.VeoId == session.Record.VeoId && Composer.Text == token.Text) { Composer.Text = ""; await SaveTypedComposerAsync(); } CloseCompletions(); return; }
        var skills = suggestion.Kind == ComposerSuggestionKind.Skill ? await App.Integrations.RefreshSkillsAsync(IntegrationContext.For(session)) : App.Integrations.Snapshot(IntegrationContext.For(session)).Skills;
        if (current?.Record.VeoId != session.Record.VeoId || !ReferenceEquals(displayedCompletion, token) || Composer.Text != token.Text || imeComposing) return;
        var attachment = ComposerSuggestionService.ValidateAttachment(session, suggestion, skills); var text = token.RemoveFrom(Composer.Text);
        if (!typedComposerAttachments.Any(x => x.Kind == attachment.Kind && x.Source == attachment.Source))
        {
            if (typedComposerAttachments.Count >= 32) throw new InvalidOperationException("A draft supports up to 32 attachments and references.");
            typedComposerAttachments.Add(attachment);
        }
        Composer.Text = text; Composer.SelectionStart = text.Length; composerRevision++; SyncLegacyAttachments(); CloseCompletions(); RefreshAttachmentRows();
        Composer.Focus(FocusState.Programmatic);
        await SaveTypedComposerAsync();
    }
    async Task<bool> HandleCompletionKeyAsync(VirtualKey key)
    {
        if (imeComposing || displayedCompletion is not { } token || composerSuggestions.Visibility != Visibility.Visible || composerSuggestions.Items.Count == 0) return false;
        if (key == VirtualKey.Escape) { CloseCompletions(); return true; }
        if (key is VirtualKey.Down or VirtualKey.Up) { composerSuggestions.SelectedIndex = Math.Clamp(composerSuggestions.SelectedIndex + (key == VirtualKey.Down ? 1 : -1), 0, composerSuggestions.Items.Count - 1); return true; }
        if (key is VirtualKey.Enter or VirtualKey.Tab && composerSuggestions.SelectedItem is ListViewItem { Tag: ComposerSuggestion suggestion }) { await ApplyCompletionAsync(suggestion, token); return true; }
        return false;
    }
    public async Task ChooseFileMentionAsync()
    {
        var session = current ?? throw new InvalidOperationException("Open a chat before mentioning a file.");
        var picker = Picker();
        picker.FileTypeFilter.Add("*");
        var files = await picker.PickMultipleFilesAsync();
        if (files.Count == 0) return;
        if (CaptureComposerDraft(session).Attachments.Length + files.Count > 32)
            throw new InvalidOperationException("A draft supports up to 32 attachments and references.");

        var mentions = new List<ComposerAttachment>(files.Count);
        var appManaged = session.Record.WorkspaceKind is "scratch" or "temporary";
        var policy = new WorkspacePathPolicy(session.Record.Cwd);
        foreach (var file in files)
        {
            var source = file.Path;
            if (appManaged)
            {
                try { source = policy.Resolve(source); }
                catch (UnauthorizedAccessException)
                {
                    var folder = policy.Resolve(Path.Combine("Imports", Guid.NewGuid().ToString("N")), mustExist: false);
                    Directory.CreateDirectory(folder);
                    source = policy.Resolve(Path.Combine(folder, file.Name), mustExist: false);
                    var target = await Windows.Storage.StorageFolder.GetFolderFromPathAsync(folder);
                    await file.CopyAsync(target, file.Name, Windows.Storage.NameCollisionOption.FailIfExists);
                }
            }
            mentions.Add(ComposerAttachment.FileMention(session.Record.Cwd, source));
        }
        await AddAttachmentsAsync(session, mentions);
    }

    async Task PickComposerAttachmentsAsync()
    {
        var session = current ?? throw new InvalidOperationException("Open a chat before attaching media.");
        var picker = Picker();
        foreach (var extension in ImageExtensions.Concat(AudioExtensions)) picker.FileTypeFilter.Add(extension);
        var files = await picker.PickMultipleFilesAsync();
        if (CaptureComposerDraft(session).Attachments.Length + files.Count > 32)
            throw new InvalidOperationException("A draft supports up to 32 attachments and references.");
        foreach (var file in files) await ImportPickedFileAsync(session, file);
    }
    static Windows.Storage.Pickers.FileOpenPicker Picker() { var picker = new Windows.Storage.Pickers.FileOpenPicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(App.Main!)); return picker; }
    static readonly HashSet<string> ImageExtensions = new([".png", ".jpg", ".jpeg", ".webp", ".gif"], StringComparer.OrdinalIgnoreCase);
    static readonly HashSet<string> AudioExtensions = new([".wav", ".mp3", ".m4a", ".flac", ".ogg", ".aac"], StringComparer.OrdinalIgnoreCase);
    async Task ImportPickedFileAsync(ThreadSession session, Windows.Storage.StorageFile file)
    {
        var extension = Path.GetExtension(file.Path); if (!ImageExtensions.Contains(extension) && !AudioExtensions.Contains(extension)) { await AddAttachmentsAsync(session, [ComposerAttachment.FileMention(session.Record.Cwd, file.Path)]); return; }
        if (new FileInfo(file.Path).Length > 64 * 1024 * 1024) throw new InvalidOperationException("This attachment exceeds Veo's 64 MiB local import limit.");
        var directory = Path.Combine(workspace.DataRoot, "Attachments"); Directory.CreateDirectory(directory); var destination = Path.Combine(directory, Guid.NewGuid().ToString("N") + extension.ToLowerInvariant());
        await using (var source = File.OpenRead(file.Path)) await using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.Asynchronous)) await source.CopyToAsync(output);
        await AddAttachmentsAsync(session, [new(AudioExtensions.Contains(extension) ? ComposerAttachmentKind.LocalAudio : ComposerAttachmentKind.LocalImage, destination, file.Name, Guid.NewGuid().ToString("N"))]);
    }
    async Task AddAttachmentsAsync(ThreadSession session, IReadOnlyList<ComposerAttachment> added)
    {
        var latest = CaptureComposerDraft(session); if (latest.Attachments.Length + added.Count > 32) throw new InvalidOperationException("A draft supports up to 32 attachments and references.");
        var merged = latest with { Attachments = latest.Attachments.Concat(added).ToArray(), UpdatedAt = DateTimeOffset.UtcNow };
        if (current?.Record.VeoId == session.Record.VeoId) { typedComposerAttachments.Clear(); typedComposerAttachments.AddRange(merged.Attachments); composerRevision++; SyncLegacyAttachments(); RefreshAttachmentRows(); await SaveTypedComposerAsync(); }
        else await SaveCompleteDraftAsync(session, merged);
    }
    async void ComposerPaste(object sender, TextControlPasteEventArgs args)
    {
        try
        {
            if (current is not { } session) return; var data = Clipboard.GetContent();
            if (data.Contains(StandardDataFormats.StorageItems)) { args.Handled = true; await Run(async () => await ImportStorageItemsAsync(session, await data.GetStorageItemsAsync())); }
            else if (data.Contains(StandardDataFormats.Bitmap)) { args.Handled = true; await Run(async () => await ImportClipboardBitmapAsync(session, await data.GetBitmapAsync())); }
        }
        catch (Exception error) { Notice.Severity = InfoBarSeverity.Warning; Notice.Message = DiagnosticRedactor.Redact(error.Message); Notice.IsOpen = true; }
    }
    async Task ImportStorageItemsAsync(ThreadSession session, IReadOnlyList<Windows.Storage.IStorageItem> items)
    { foreach (var item in items) { if (item is Windows.Storage.StorageFile file) await ImportPickedFileAsync(session, file); else if (item is Windows.Storage.StorageFolder folder) await AddAttachmentsAsync(session, [ComposerAttachment.FileMention(session.Record.Cwd, folder.Path)]); } }
    async Task ImportClipboardBitmapAsync(ThreadSession session, Windows.Storage.Streams.IRandomAccessStreamReference reference)
    {
        using var source = await reference.OpenReadAsync(); if (source.Size > 64 * 1024 * 1024) throw new InvalidOperationException("The pasted image exceeds Veo's 64 MiB import limit.");
        var decoder = await Windows.Graphics.Imaging.BitmapDecoder.CreateAsync(source); if ((ulong)decoder.PixelWidth * decoder.PixelHeight > 32_000_000) throw new InvalidOperationException("The pasted image exceeds Veo's 32 megapixel decode limit.");
        using var bitmap = await decoder.GetSoftwareBitmapAsync(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied);
        var directory = Path.Combine(workspace.DataRoot, "Attachments"); Directory.CreateDirectory(directory); var folder = await Windows.Storage.StorageFolder.GetFolderFromPathAsync(directory); var file = await folder.CreateFileAsync(Guid.NewGuid().ToString("N") + ".png", Windows.Storage.CreationCollisionOption.FailIfExists);
        using (var output = await file.OpenAsync(Windows.Storage.FileAccessMode.ReadWrite)) { var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, output); encoder.SetSoftwareBitmap(bitmap); await encoder.FlushAsync(); }
        await AddAttachmentsAsync(session, [new(ComposerAttachmentKind.LocalImage, file.Path, "Pasted image", Guid.NewGuid().ToString("N"))]);
    }
    async Task DropComposerAttachmentsAsync(DragEventArgs args)
    {
        var deferral = args.GetDeferral(); args.Handled = true;
        try { var session = current ?? throw new InvalidOperationException("Open a chat first."); await ImportStorageItemsAsync(session, await args.DataView.GetStorageItemsAsync()); }
        finally { deferral.Complete(); }
    }
}
