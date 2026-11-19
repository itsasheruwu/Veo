using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Veo.Core;
using Windows.System;
using Windows.UI.Core;

namespace Veo_Windows.Controls;

/// <summary>Native pointer and keyboard suggestions; root calls HandleKey before its composer send handler.</summary>
public sealed class ComposerSuggestions : UserControl, IDisposable
{
    readonly TextBox composer; readonly Func<ThreadSession?> selected; readonly Func<ThreadSession, ComposerAttachment, Task> addAttachment;
    readonly Func<CommandInvocation, Task> execute; readonly IntegrationCoordinator? integrations; readonly ComposerSuggestionService service;
    readonly ListView list = new() { MaxHeight = 268, IsItemClickEnabled = true, SelectionMode = ListViewSelectionMode.Single };
    readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
    CancellationTokenSource? operation; ComposerCompletionToken? token; ThreadSession? source; bool composing; bool disposed; bool accepting;
    public bool IsOpen => Visibility == Visibility.Visible && list.Items.Count > 0;
    public ComposerSuggestions(TextBox composer, CommandRegistry commands, Func<ThreadSession?> selected,
        Func<ThreadSession, ComposerAttachment, Task> addAttachment, Func<CommandInvocation, Task> executeCommand,
        IntegrationCoordinator? integrations = null, ICoordinatorRpc? transport = null)
    {
        this.composer = composer; this.selected = selected; this.addAttachment = addAttachment; execute = executeCommand; this.integrations = integrations; service = new(commands, transport);
        list.ItemTemplate = (DataTemplate)XamlReader.Load("""<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><StackPanel Spacing="2"><TextBlock Text="{Binding Title}" FontWeight="SemiBold"/><TextBlock Text="{Binding Description}" FontSize="12" Foreground="{ThemeResource TextFillColorSecondaryBrush}" TextTrimming="CharacterEllipsis"/></StackPanel></DataTemplate>""");
        var body = new StackPanel { Spacing = 4 }; body.Children.Add(list); body.Children.Add(new TextBlock { Text = "↑↓ Select   Tab Next   Enter Use   Escape Close", FontSize = 11 }); body.Children.Add(status); Content = body; Visibility = Visibility.Collapsed;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(list, "Composer command, file, and skill suggestions");
        composer.TextChanged += TextChanged; composer.SelectionChanged += SelectionChanged;
        composer.TextCompositionStarted += CompositionStarted; composer.TextCompositionEnded += CompositionEnded;
        list.ItemClick += async (_, e) => { if (e.ClickedItem is ComposerSuggestion row) await AcceptAsync(row); };
        list.KeyDown += (_, e) => HandleKey(e);
    }
    public void ContextChanged() { Dismiss(); _ = RefreshAsync(); }
    void TextChanged(object sender, TextChangedEventArgs e) { if (!accepting) _ = RefreshAsync(); }
    void SelectionChanged(object sender, RoutedEventArgs e) { if (!accepting && composer.SelectionStart != composer.Text.Length) Dismiss(); }
    void CompositionStarted(TextBox sender, TextCompositionStartedEventArgs e) { composing = true; Dismiss(); }
    void CompositionEnded(TextBox sender, TextCompositionEndedEventArgs e) { composing = false; _ = RefreshAsync(); }
    public async Task RefreshAsync()
    {
        operation?.Cancel(); operation?.Dispose(); operation = new(); var cancellation = operation.Token;
        token = ComposerCompletionToken.Parse(composer.Text, composer.SelectionStart, composer.SelectionLength, composing); source = selected();
        if (disposed || token is null || source is null) { Visibility = Visibility.Collapsed; return; }
        var captured = token; var session = source;
        try
        {
            if (captured.Trigger == '@') await Task.Delay(160, cancellation);
            var suggestions = await service.QueryAsync(session, captured, integrations?.Snapshot(IntegrationContext.For(session)).Skills, cancellation);
            if (cancellation.IsCancellationRequested || selected() != session || composer.Text != captured.Text || composing) return;
            list.ItemsSource = suggestions; list.SelectedIndex = suggestions.Count == 0 ? -1 : 0; status.Text = ""; Visibility = suggestions.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!cancellation.IsCancellationRequested) { status.Text = Veo.Protocol.DiagnosticRedactor.Redact(error.Message); Visibility = Visibility.Collapsed; } }
    }
    public bool HandleKey(KeyRoutedEventArgs e)
    {
        if (composing || accepting || !IsOpen || InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down) || InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu).HasFlag(CoreVirtualKeyStates.Down)) return false;
        switch (e.Key)
        {
            case VirtualKey.Up: Move(-1); break;
            case VirtualKey.Down: Move(1); break;
            case VirtualKey.Tab: Move(InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down) ? -1 : 1); break;
            case VirtualKey.Escape: Dismiss(); break;
            case VirtualKey.Enter: if (list.SelectedItem is ComposerSuggestion row) _ = AcceptAsync(row); break;
            default: return false;
        }
        e.Handled = true; return true;
    }
    void Move(int delta) { list.SelectedIndex = (Math.Max(0, list.SelectedIndex) + delta + list.Items.Count) % list.Items.Count; list.ScrollIntoView(list.SelectedItem); }
    async Task AcceptAsync(ComposerSuggestion suggestion)
    {
        if (accepting || disposed || composing || token is null || source is null) return;
        var captured = token; var session = source; accepting = true;
        try
        {
            if (selected() != session || composer.Text != captured.Text) throw new InvalidOperationException("The selected chat or composer text changed; the stale suggestion was kept unapplied.");
            if (suggestion.Command is { } command) { await execute(new(command, "", false)); }
            else
            {
                var attachment = ComposerSuggestionService.ValidateAttachment(session, suggestion, integrations?.Snapshot(IntegrationContext.For(session)).Skills);
                await addAttachment(session, attachment);
                if (selected() == session && composer.Text == captured.Text) { composer.Text = captured.RemoveFrom(composer.Text); composer.SelectionStart = composer.Text.Length; }
            }
            Dismiss(); composer.Focus(FocusState.Programmatic);
        }
        catch (Exception error) { status.Text = Veo.Protocol.DiagnosticRedactor.Redact(error.Message); }
        finally { accepting = false; }
    }
    public void Dismiss() { operation?.Cancel(); Visibility = Visibility.Collapsed; list.ItemsSource = null; token = null; source = null; }
    public void Dispose()
    {
        if (disposed) return; disposed = true; Dismiss(); operation?.Dispose(); composer.TextChanged -= TextChanged; composer.SelectionChanged -= SelectionChanged;
        composer.TextCompositionStarted -= CompositionStarted; composer.TextCompositionEnded -= CompositionEnded;
    }
}
