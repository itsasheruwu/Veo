using System.Globalization;
using System.Speech.Recognition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Veo_Windows.Services;

namespace Veo_Windows.Controls;

public sealed partial class SettingsPanel
{
    void ShowVoice()
    {
        var preferences = workspace.Preferences;
        var rows = Section("Composer dictation");
        var model = new ComboBox { MinWidth = 155 };
        model.Items.Add(new ComboBoxItem { Content = "Windows Speech" });
        model.Items.Add(new ComboBoxItem { Content = "Whisper (local)" });
        model.Items.Add(new ComboBoxItem { Content = OpenAIDictation.ModelName });
        model.SelectedIndex = preferences.DictationModel switch
        {
            "Whisper (local)" => 1,
            OpenAIDictation.ModelName => 2,
            _ => 0
        };
        AutomationProperties.SetName(model, "Transcription model");
        AutomationProperties.SetAutomationId(model, "SettingTranscriptionModel");
        AddRow(rows, "Transcription model", "Choose a local speech model or OpenAI.", "\uE720", model);

        var systemRows = new StackPanel();
        rows.Children.Add(systemRows);
        var languages = new List<(string Id, string Label)> { ("", "System language") };
        CultureInfo[] installed;
        try { installed = SpeechRecognitionEngine.InstalledRecognizers().Select(item => item.Culture).ToArray(); }
        catch (InvalidOperationException) { installed = []; }
        foreach (var culture in installed.DistinctBy(item => item.Name).OrderBy(item => item.DisplayName))
            languages.Add((culture.Name, culture.DisplayName));
        var language = new ComboBox
        {
            ItemsSource = languages.Select(item => item.Label).ToArray(),
            SelectedIndex = Math.Max(0, languages.FindIndex(item => item.Id == preferences.DictationLanguage)),
            MinWidth = 155
        };
        AutomationProperties.SetName(language, "Dictation language");
        language.SelectionChanged += async (_, _) =>
        {
            if (language.SelectedIndex >= 0)
            {
                var id = languages[language.SelectedIndex].Id;
                await SavePreferenceAsync(() => preferences.DictationLanguage = id);
            }
        };
        AddRow(systemRows, "Dictation language", "Choose an installed Windows desktop speech language.", "\uE774", language);
        AddRow(systemRows, "Live transcription", "Show words while you speak.", "\uE8D5",
            Toggle("Live transcription", preferences.DictationLive, value => preferences.DictationLive = value));

        var whisperRows = new StackPanel();
        rows.Children.Add(whisperRows);
        AddVoiceText(whisperRows, "Whisper language code", "Use a language code or leave blank to auto-detect.",
            preferences.DictationWhisperLanguage, value => preferences.DictationWhisperLanguage = value);
        AddVoiceText(whisperRows, "Whisper executable", "Full path to the local whisper-cli.exe.",
            preferences.DictationWhisperExecutable, value => preferences.DictationWhisperExecutable = value);
        AddVoiceText(whisperRows, "Whisper model file", "Full path to the ggml model. Transcription starts when you finish recording.",
            preferences.DictationWhisperModel, value => preferences.DictationWhisperModel = value);

        var openAIRows = new StackPanel();
        rows.Children.Add(openAIRows);
        var keyButton = ActionButton("Manage key…", EditOpenAIDictationKeyAsync);
        AutomationProperties.SetAutomationId(keyButton, "SettingOpenAIDictationKey");
        AddRow(openAIRows, "OpenAI API key", "After you finish recording, Veo sends audio to OpenAI for transcription with GPT Transcribe. OpenAI API usage is billed separately.", "\uE72E", keyButton);
        AddRow(openAIRows, "Show text as OpenAI transcribes", "Reveal words as they arrive after recording.", "\uE8D5",
            Toggle("Show text as OpenAI transcribes", preferences.DictationOpenAIStream, value => preferences.DictationOpenAIStream = value));

        var help = SettingText("Click the mic or press Ctrl+Shift+D to start or finish. Press Escape to cancel. Veo inserts the transcript at the cursor.", "SettingDetail");
        help.Margin = new Thickness(16, 10, 16, 13);
        rows.Children.Add(help);
        UpdateModelRows();
        model.SelectionChanged += async (_, _) =>
        {
            if (model.SelectedItem is not ComboBoxItem { IsEnabled: true, Content: string selected }) return;
            UpdateModelRows();
            await SavePreferenceAsync(() => preferences.DictationModel = selected);
        };

        void UpdateModelRows()
        {
            systemRows.Visibility = model.SelectedIndex == 0 ? Visibility.Visible : Visibility.Collapsed;
            whisperRows.Visibility = model.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
            openAIRows.Visibility = model.SelectedIndex == 2 ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    async Task EditOpenAIDictationKeyAsync()
    {
        var hasKey = OpenAIDictation.ReadKey() is not null;
        var key = new PasswordBox { Header = hasKey ? "Replace saved API key" : "OpenAI API key", MaxLength = 512 };
        var dialog = new ContentDialog
        {
            Title = "OpenAI dictation", Content = key, XamlRoot = XamlRoot,
            PrimaryButtonText = "Save key", IsPrimaryButtonEnabled = false,
            SecondaryButtonText = hasKey ? "Remove key" : "", CloseButtonText = "Cancel"
        };
        key.PasswordChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(key.Password);
        try
        {
            var result = await dialog.ShowAsync();
            if (result == ContentDialogResult.Primary)
            {
                OpenAIDictation.SaveKey(key.Password.Trim());
                ShowFeedback("OpenAI key saved in Windows Credential Manager.", InfoBarSeverity.Success);
            }
            else if (result == ContentDialogResult.Secondary)
            {
                OpenAIDictation.RemoveKey();
                ShowFeedback("OpenAI key removed.", InfoBarSeverity.Success);
            }
        }
        finally { key.Password = ""; }
    }

    void AddVoiceText(StackPanel rows, string title, string detail, string current, Action<string> set)
    {
        var field = new TextBox { Text = current, MaxLength = 2048 };
        AutomationProperties.SetName(field, title);
        AutomationProperties.SetAutomationId(field, SettingId(title));
        field.LostFocus += async (_, _) => await SavePreferenceAsync(() => set(field.Text.Trim()));
        AddRow(rows, title, detail, "\uE8A5", field, fullWidth: true);
    }
}
