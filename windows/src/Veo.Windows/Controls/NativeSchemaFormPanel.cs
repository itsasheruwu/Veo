using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;

namespace Veo_Windows.Controls;

public sealed class NativeSchemaFormPanel : StackPanel
{
    readonly Dictionary<string, Func<string>> values = new(StringComparer.Ordinal);
    public NativeSchemaForm Form { get; }
    public NativeSchemaFormPanel(NativeSchemaForm form)
    {
        Form = form; Spacing = 10;
        if (!form.IsSupported) { Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Message = form.UnavailableReason }); return; }
        foreach (var field in form.Fields)
        {
            var title = field.Title + (field.Required ? " *" : ""); FrameworkElement control;
            if (field.Kind == "boolean")
            {
                var toggle = new ToggleSwitch { Header = title, IsOn = bool.TryParse(field.Default, out var value) && value }; values[field.Key] = () => toggle.IsOn ? "true" : "false"; control = toggle;
            }
            else if (field.Kind == "array" && field.Choices.Length > 0)
            {
                var choices = new ListView { ItemsSource = field.Choices, SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 180, ItemContainerTransitions = new() };
                foreach (var value in (field.Default ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries)) if (field.Choices.Contains(value)) choices.SelectedItems.Add(value);
                var wrapper = new StackPanel { Spacing = 4 }; wrapper.Children.Add(new TextBlock { Text = title }); wrapper.Children.Add(choices); values[field.Key] = () => string.Join("\n", choices.SelectedItems.Cast<string>()); control = wrapper;
            }
            else if (field.Choices.Length > 0)
            {
                var choice = new ComboBox { Header = title, ItemsSource = field.Choices, SelectedItem = field.Default, HorizontalAlignment = HorizontalAlignment.Stretch }; values[field.Key] = () => choice.SelectedItem as string ?? ""; control = choice;
            }
            else if (field.Secret)
            {
                var secret = new PasswordBox { Header = title, Password = field.Default ?? "" }; values[field.Key] = () => secret.Password; control = secret;
            }
            else
            {
                var text = new TextBox { Header = title, Text = field.Default ?? "", AcceptsReturn = field.Kind == "array", TextWrapping = TextWrapping.Wrap, MaxHeight = 160, PlaceholderText = field.Kind == "array" ? "One value per line" : "" }; values[field.Key] = () => text.Text; control = text;
            }
            AutomationProperties.SetAutomationId(control, "IntegrationForm_" + Uri.EscapeDataString(field.Key)); AutomationProperties.SetName(control, title); Children.Add(control);
            if (field.Description.Length > 0) Children.Add(new TextBlock { Text = field.Description, FontSize = 12, TextWrapping = TextWrapping.Wrap });
        }
    }
    public IReadOnlyDictionary<string, string> Values() => values.ToDictionary(x => x.Key, x => x.Value(), StringComparer.Ordinal);
}
