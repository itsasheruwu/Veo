using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Veo.Protocol;

namespace Veo_Windows.Controls;

internal sealed class SideChatPanel : Grid
{
    sealed record Exchange(string Question, string? Answer = null);
    sealed class Conversation
    {
        public List<Exchange> Exchanges { get; } = [];
        public bool Working;
        public string? Error;
        public string Draft = "";
    }

    readonly Dictionary<string, Conversation> conversations = new(StringComparer.Ordinal);
    readonly StackPanel messages = new() { Spacing = 14, Padding = new(12) };
    readonly ScrollViewer scroll;
    readonly TextBox question = new() { PlaceholderText = "Ask a side question", MaxHeight = 100, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
    readonly Button send = new() { Content = "Ask", VerticalAlignment = VerticalAlignment.Bottom };
    readonly Func<ThreadSession, string, string, Task<string>> answer;
    readonly Func<ThreadSession, string, Task> bringBack;
    ThreadSession? session;
    bool loading;

    public SideChatPanel(Func<ThreadSession, string, string, Task<string>> answer, Func<ThreadSession, string, Task> bringBack)
    {
        this.answer = answer;
        this.bringBack = bringBack;
        RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        RowDefinitions.Add(new() { Height = GridLength.Auto });
        scroll = new ScrollViewer { Content = messages };
        Children.Add(scroll);
        var input = new Grid { ColumnSpacing = 8, Padding = new(12) };
        input.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        input.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        input.Children.Add(question);
        SetColumn(send, 1);
        input.Children.Add(send);
        SetRow(input, 1);
        Children.Add(input);
        send.Click += async (_, _) => await SubmitAsync(question.Text);
        question.TextChanged += (_, _) =>
        {
            if (session is { } selected && !loading) conversations[selected.Record.VeoId].Draft = question.Text;
            UpdateSend();
        };
    }

    public void Show(ThreadSession selected)
    {
        if (session?.Record.VeoId == selected.Record.VeoId) return;
        session = selected;
        if (!conversations.TryGetValue(selected.Record.VeoId, out var conversation))
        {
            conversation = new();
            conversations[selected.Record.VeoId] = conversation;
        }
        loading = true;
        try { question.Text = conversation.Draft; } finally { loading = false; }
        Render();
    }

    public async Task SubmitAsync(string prompt)
    {
        if (session is not { } captured || string.IsNullOrWhiteSpace(prompt)) return;
        var state = conversations[captured.Record.VeoId];
        if (state.Working) return;
        var history = string.Join("\n\n", state.Exchanges.TakeLast(5).Select(x => "Question: " + x.Question + "\nAnswer: " + x.Answer));
        var index = state.Exchanges.Count;
        state.Exchanges.Add(new(prompt.Trim()));
        state.Working = true;
        state.Error = null;
        question.Text = "";
        Render();
        try
        {
            var result = await answer(captured, prompt.Trim(), history);
            state.Exchanges[index] = state.Exchanges[index] with { Answer = result };
        }
        catch (Exception error) { state.Error = DiagnosticRedactor.Redact(error.Message); }
        finally
        {
            state.Working = false;
            if (session?.Record.VeoId == captured.Record.VeoId) Render();
        }
    }

    void Render()
    {
        messages.Children.Clear();
        if (session is not { } selected) return;
        var state = conversations[selected.Record.VeoId];
        if (state.Exchanges.Count == 0)
            messages.Children.Add(new TextBlock { Text = "Ask a question about this chat.", Opacity = .72, TextWrapping = TextWrapping.Wrap });
        foreach (var exchange in state.Exchanges)
        {
            var entry = new StackPanel { Spacing = 7 };
            entry.Children.Add(new TextBlock { Text = exchange.Question, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
            if (exchange.Answer is { } response)
            {
                entry.Children.Add(new MarkdownView { Session = selected, Markdown = response });
                var insert = new HyperlinkButton { Content = "Add to main chat" };
                insert.Click += async (_, _) =>
                {
                    try { await bringBack(selected, $"Side question: {exchange.Question}\n\n{response}"); }
                    catch (Exception error) { state.Error = DiagnosticRedactor.Redact(error.Message); Render(); }
                };
                entry.Children.Add(insert);
            }
            messages.Children.Add(entry);
        }
        if (state.Working)
            messages.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8,
                Children = { new ProgressRing { IsActive = true, Width = 16, Height = 16 }, new TextBlock { Text = "Working…" } } });
        if (state.Error is { } errorText)
            messages.Children.Add(new InfoBar { IsOpen = true, Severity = InfoBarSeverity.Warning, Message = errorText, IsClosable = false });
        UpdateSend();
        DispatcherQueue.TryEnqueue(() => scroll.ChangeView(null, scroll.ScrollableHeight, null, disableAnimation: true));
    }

    void UpdateSend() => send.IsEnabled = session is { } selected && !conversations[selected.Record.VeoId].Working
        && !string.IsNullOrWhiteSpace(question.Text);
}
