using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Veo.Protocol;

namespace Veo_Windows.Controls;

/// <summary>Native question forms. Dismiss, Skip and Send are distinct actions.</summary>
public sealed class QuestionPanel : UserControl
{
    readonly QuestionCoordinator questions;
    readonly ThreadSession session;
    readonly RuntimeEvent? blocking;
    readonly AsyncQuestionRequest? asynchronous;
    readonly Func<ComposerSnapshot>? settings;
    readonly StackPanel body = new() { Spacing = 10 };
    readonly InfoBar error = new() { Severity = InfoBarSeverity.Error, IsClosable = true };
    readonly TextBlock countdown = new() { FontSize = 12 };
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    bool initializing = true;
    public QuestionPanel(QuestionCoordinator questions, ThreadSession session, RuntimeEvent request)
    { this.questions = questions; this.session = session; blocking = request; Initialize(); }
    public QuestionPanel(QuestionCoordinator questions, ThreadSession session, AsyncQuestionRequest request, Func<ComposerSnapshot> settings)
    { this.questions = questions; this.session = session; asynchronous = request; this.settings = settings; Initialize(); }
    void Initialize()
    {
        AutomationProperties.SetName(this, "Questions from Codex");
        var expander = new Expander { Header = "Questions from Codex", IsExpanded = true, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, Content = body };
        Content = expander;
        Loaded += (_, _) => Run(async () =>
        {
            if (blocking is { } request) await questions.OpenBlockingAsync(session, request);
            Build(); initializing = false; timer.Start();
        });
        timer.Tick += (_, _) => RefreshCountdown();
        Unloaded += (_, _) => timer.Stop();
    }
    void Build()
    {
        body.Children.Clear();
        var fields = blocking is { } request ? QuestionCoordinator.ParseBlocking(request) : asynchronous!.Questions;
        var draft = blocking is { } b ? questions.BlockingDraft(b).Answers : questions.Pending(session.Record.VeoId).FirstOrDefault(x => x.Key == asynchronous!.Key)?.Answers ?? asynchronous!.Answers;
        foreach (var question in fields)
        {
            TextBox? answerField = null; PasswordBox? secretField = null; var changing = false;
            var notesOnly = blocking is not null && question.Options.Length > 0 && !question.AllowsOther;
            var radios = new List<(RadioButton Radio, string Label)>();
            body.Children.Add(new TextBlock { Text = question.Title, TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            var value = draft.GetValueOrDefault(question.Id) ?? (blocking is null ? question.Options.FirstOrDefault()?.Label ?? "" : "");
            var group = "question-" + Guid.NewGuid().ToString("N");
            foreach (var option in question.Options)
            {
                var label = new StackPanel { Spacing = 2 }; label.Children.Add(new TextBlock { Text = option.Label, TextWrapping = TextWrapping.Wrap });
                if (option.Description.Length > 0) label.Children.Add(new TextBlock { Text = option.Description, FontSize = 12, TextWrapping = TextWrapping.Wrap });
                var radio = new RadioButton { Content = label, GroupName = group, IsChecked = value == option.Label, HorizontalAlignment = HorizontalAlignment.Stretch };
                AutomationProperties.SetName(radio, option.Description.Length == 0 ? option.Label : option.Label + ". " + option.Description);
                radio.GotFocus += (_, _) => { if (!initializing && blocking is { } pending) Run(() => questions.KeepOpenAsync(session, pending)); };
                radio.Checked += (_, _) =>
                {
                    if (initializing || changing) return;
                    changing = true;
                    if (!notesOnly) { if (answerField is not null) answerField.Text = option.Label; if (secretField is not null) secretField.Password = option.Label; }
                    changing = false; Run(() => SetAnswer(question.Id, option.Label));
                };
                radios.Add((radio, option.Label));
                body.Children.Add(radio);
            }
            if (question.Secret)
            {
                var field = secretField = new PasswordBox { Password = notesOnly && blocking is { } secretRequest ? questions.BlockingDraft(secretRequest).Notes?.GetValueOrDefault(question.Id) ?? "" : value, PlaceholderText = notesOnly ? "Optional details" : "Your answer" }; AutomationProperties.SetName(field, (notesOnly ? "Optional details for " : "Answer to ") + question.Title);
                field.PasswordChanged += (_, _) => { if (!initializing && !changing) Run(() => notesOnly ? questions.NoteBlockingAsync(session, blocking!, question.Id, field.Password) : SetAnswer(question.Id, field.Password)); }; body.Children.Add(field);
                field.GotFocus += (_, _) => { if (!initializing && blocking is { } focusedRequest) Run(() => questions.KeepOpenAsync(session, focusedRequest)); };
            }
            else
            {
                var field = answerField = new TextBox { Text = notesOnly && blocking is { } textRequest ? questions.BlockingDraft(textRequest).Notes?.GetValueOrDefault(question.Id) ?? "" : value, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, PlaceholderText = notesOnly ? "Optional details" : question.Options.Length == 0 ? "Your answer" : "Or write your own answer", MaxHeight = 120 };
                AutomationProperties.SetName(field, (notesOnly ? "Optional details for " : "Answer to ") + question.Title);
                field.TextChanged += (_, _) =>
                {
                    if (initializing || changing) return;
                    if (!notesOnly) { changing = true; foreach (var choice in radios) choice.Radio.IsChecked = choice.Label == field.Text; changing = false; }
                    Run(() => notesOnly ? questions.NoteBlockingAsync(session, blocking!, question.Id, field.Text) : SetAnswer(question.Id, field.Text));
                }; body.Children.Add(field);
                field.GotFocus += (_, _) => { if (!initializing && blocking is { } focusedRequest) Run(() => questions.KeepOpenAsync(session, focusedRequest)); };
            }
        }
        body.Children.Add(countdown); body.Children.Add(error);
        var commands = new CommandBar { DefaultLabelPosition = CommandBarDefaultLabelPosition.Right };
        var send = new AppBarButton { Label = "Send answers", Icon = new SymbolIcon(Symbol.Send) };
        send.Click += (_, _) => Run(async () =>
        {
            if (blocking is { } request) await questions.SendBlockingAsync(session, request);
            else await questions.SendAsync(session, asynchronous!, settings!());
            Visibility = Visibility.Collapsed;
        });
        commands.PrimaryCommands.Add(send);
        if (blocking is { } pending)
        {
            var keep = new AppBarButton { Label = "Keep open" }; keep.Click += (_, _) => Run(() => questions.KeepOpenAsync(session, pending)); commands.PrimaryCommands.Add(keep);
            var skip = new AppBarButton { Label = "Skip" }; skip.Click += (_, _) => Run(async () => { await questions.SendBlockingAsync(session, pending, true); Visibility = Visibility.Collapsed; }); commands.SecondaryCommands.Add(skip);
        }
        else
        {
            var dismiss = new AppBarButton { Label = "Dismiss" }; dismiss.Click += (_, _) => Run(async () => { await questions.DismissAsync(asynchronous!); Visibility = Visibility.Collapsed; }); commands.SecondaryCommands.Add(dismiss);
        }
        body.Children.Add(commands); RefreshCountdown();
    }
    Task SetAnswer(string id, string answer) => blocking is { } request ? questions.AnswerBlockingAsync(session, request, id, answer) : questions.AnswerAsync(asynchronous!, id, answer);
    void RefreshCountdown()
    {
        countdown.Text = blocking is { } request && questions.CountdownDeadline(request) is { } deadline ? "Skipping in " + Math.Max(0, (int)Math.Ceiling((deadline - DateTimeOffset.UtcNow).TotalSeconds)) + "s · choose Keep open to continue" : "";
    }
    async void Run(Func<Task> action)
    {
        try { await action(); error.IsOpen = false; }
        catch (Exception exception) { error.Message = DiagnosticRedactor.Redact(exception.Message); error.IsOpen = true; }
    }
}
