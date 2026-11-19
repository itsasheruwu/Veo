using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Veo.Core;
using Windows.System;
using Windows.UI.Core;

namespace Veo_Windows.Controls;

public sealed class ShortcutSettingsPanel : UserControl
{
    readonly CommandRegistry registry;
    readonly Func<string, bool> available;
    readonly TextBox search = new() { PlaceholderText = "Search commands", IsSpellCheckEnabled = false };
    readonly ListView commands = new() { MaxHeight = 340, SelectionMode = ListViewSelectionMode.Single, ItemContainerTransitions = new() };
    readonly Button capture = new() { Content = "Capture shortcut" };
    readonly Button save;
    readonly Button clear;
    readonly Button reset;
    readonly TextBlock noCommands = SettingsGroup.Note("No matching commands.");
    readonly TextBlock proposed = SettingsGroup.Note("");
    readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    CommandKeyBinding? pending;
    bool capturing;
    public bool IsCapturing => capturing;
    public event Action<bool>? CapturingChanged;
    public ShortcutSettingsPanel(CommandRegistry registry, Func<string, bool> available)
    {
        this.registry = registry;
        this.available = available;
        AutomationProperties.SetName(search, "Search commands");
        AutomationProperties.SetAutomationId(search, "ShortcutSearch");
        AutomationProperties.SetName(commands, "Available commands");
        AutomationProperties.SetAutomationId(commands, "ShortcutCommands");
        AutomationProperties.SetLiveSetting(proposed, AutomationLiveSetting.Polite);
        AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
        commands.ItemTemplate = (DataTemplate)XamlReader.Load("""
            <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
              <Grid ColumnSpacing="14" Padding="4,7">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Text="{Binding Name}" FontSize="13" TextWrapping="Wrap" MaxLines="2" VerticalAlignment="Center"/>
                <Border Grid.Column="1" Padding="8,3" CornerRadius="5" VerticalAlignment="Center" Background="{ThemeResource ControlFillColorSecondaryBrush}">
                  <TextBlock Text="{Binding Binding}" FontSize="11.5" Foreground="{ThemeResource TextFillColorSecondaryBrush}"/>
                </Border>
              </Grid>
            </DataTemplate>
            """);
        commands.ItemContainerStyle = (Style)XamlReader.Load("""
            <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="ListViewItem">
              <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
              <Setter Property="MinHeight" Value="39"/>
            </Style>
            """);
        capture.Click += (_, _) =>
        {
            Capture(true);
            if (!capture.Focus(FocusState.Keyboard)) Capture(false);
        };
        capture.LostFocus += (_, _) => Capture(false);
        capture.PreviewKeyDown += (_, e) =>
        {
            if (!capturing) return; e.Handled = true;
            if (e.Key == VirtualKey.Escape) { Capture(false); return; }
            if (e.Key is VirtualKey.Control or VirtualKey.Shift or VirtualKey.Menu or VirtualKey.LeftControl or VirtualKey.RightControl or VirtualKey.LeftShift or VirtualKey.RightShift or VirtualKey.LeftMenu or VirtualKey.RightMenu) return;
            var modifiers = (Down(VirtualKey.Control) ? ShortcutModifiers.Control : 0) | (Down(VirtualKey.Shift) ? ShortcutModifiers.Shift : 0) | (Down(VirtualKey.Menu) ? ShortcutModifiers.Alt : 0);
            pending = new((int)e.Key, modifiers); Capture(false);
        };
        save = ActionButton("Save", async () =>
        {
            if (pending is null) throw new InvalidOperationException("Capture a shortcut first.");
            await registry.SetBindingAsync(Selected(), pending); Refresh();
        });
        AutomationProperties.SetName(save, "Save captured shortcut");
        clear = ActionButton("Clear", async () => { await registry.SetBindingAsync(Selected(), null); Refresh(); });
        AutomationProperties.SetName(clear, "Clear selected shortcut");
        reset = ActionButton("Reset", async () => { await registry.ResetAsync(Selected()); Refresh(); });
        AutomationProperties.SetName(reset, "Reset selected shortcut");
        var resetAll = ActionButton("Reset all shortcuts", async () => { await registry.ResetAsync(); Refresh(); });
        noCommands.Margin = new Thickness(12, 10, 12, 10);
        var editor = new StackPanel
        {
            Spacing = 8,
            Children =
            {
                capture, proposed,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { save, clear, reset } },
                SettingsGroup.Divider(0), resetAll
            }
        };
        Content = new StackPanel
        {
            Spacing = 14,
            Children =
            {
                search,
                SettingsGroup.Note("Choose a command and capture Ctrl plus a letter, number, or punctuation key. Press Escape to cancel capture."),
                SettingsGroup.Section("Commands", new StackPanel { Children = { commands, noCommands } }, new Thickness(4)),
                SettingsGroup.Section("Selected shortcut", editor, new Thickness(16)),
                status
            }
        };
        Loaded += (_, _) => Refresh();
        Unloaded += (_, _) => Capture(false);
        search.TextChanged += (_, _) => Refresh();
        commands.SelectionChanged += (_, _) =>
        {
            pending = null;
            proposed.Text = "";
            proposed.Visibility = Visibility.Collapsed;
            Capture(false);
            UpdateActions();
        };
        proposed.Visibility = Visibility.Collapsed;
        UpdateActions();
    }
    public void Refresh()
    {
        var id = (commands.SelectedItem as Row)?.Id;
        var query = search.Text.Trim();
        var rows = CommandRegistry.Definitions
            .Where(definition => available(definition.Id) && definition.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase))
            .Select(definition => new Row(definition.Id, definition.Title, registry.Binding(definition.Id)?.Display ?? "No shortcut"))
            .ToArray();
        commands.ItemsSource = rows;
        commands.SelectedItem = rows.FirstOrDefault(row => row.Id == id);
        commands.Visibility = rows.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        noCommands.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateActions();
    }
    string Selected() => (commands.SelectedItem as Row)?.Id ?? throw new InvalidOperationException("Select a command first.");
    void Capture(bool value)
    {
        if (capturing == value) return;
        capturing = value;
        capture.Content = value ? "Press a shortcut…" : "Capture shortcut";
        proposed.Visibility = value || pending is not null ? Visibility.Visible : Visibility.Collapsed;
        proposed.Text = value ? "Press Escape to cancel capture." : pending?.Display ?? "";
        UpdateActions();
        CapturingChanged?.Invoke(value);
    }
    void UpdateActions()
    {
        var selected = commands.SelectedItem is Row;
        capture.IsEnabled = selected;
        clear.IsEnabled = reset.IsEnabled = selected && !capturing;
        save.IsEnabled = selected && !capturing && pending is not null;
    }
    Button ActionButton(string title, Func<Task> action)
    {
        var button = new Button { Content = title };
        button.Click += async (_, _) =>
        {
            try { await action(); status.Text = "Shortcut settings saved."; }
            catch (Exception error) { status.Text = Veo.Protocol.DiagnosticRedactor.Redact(error.Message); }
        };
        return button;
    }
    static bool Down(VirtualKey key) => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);
    public sealed record Row(string Id, string Name, string Binding)
    {
        public override string ToString() => $"{Name}, {Binding}";
    }
}

/// <summary>Owns only accelerators it installs, and rebuilds them after persisted binding edits.</summary>
public sealed class CommandAcceleratorBinder : IDisposable
{
    readonly UIElement owner; readonly CommandRegistry registry; readonly CommandDispatcher dispatcher; readonly Action<Exception>? failed;
    readonly Func<CommandDefinition, bool>? canInvoke;
    readonly List<KeyboardAccelerator> installed = []; bool disposed;
    public bool IsSuspended { get; set; }
    public CommandAcceleratorBinder(UIElement owner, CommandRegistry registry, CommandDispatcher dispatcher, Action<Exception>? failed = null,
        Func<CommandDefinition, bool>? canInvoke = null)
    { this.owner = owner; this.registry = registry; this.dispatcher = dispatcher; this.failed = failed; this.canInvoke = canInvoke; registry.Changed += Changed; Rebuild(); }
    void Changed() => owner.DispatcherQueue.TryEnqueue(() => { if (!disposed) Rebuild(); });
    public void Rebuild()
    {
        foreach (var old in installed) owner.KeyboardAccelerators.Remove(old); installed.Clear();
        foreach (var definition in CommandRegistry.Definitions)
        {
            if (!dispatcher.IsAvailable(definition.Id) || registry.Binding(definition.Id) is not { } binding) continue;
            var flags = (binding.Modifiers.HasFlag(ShortcutModifiers.Control) ? VirtualKeyModifiers.Control : 0) | (binding.Modifiers.HasFlag(ShortcutModifiers.Shift) ? VirtualKeyModifiers.Shift : 0) | (binding.Modifiers.HasFlag(ShortcutModifiers.Alt) ? VirtualKeyModifiers.Menu : 0);
            var accelerator = new KeyboardAccelerator { Key = (VirtualKey)binding.VirtualKey, Modifiers = flags };
            accelerator.Invoked += async (_, e) => { if (IsSuspended || disposed || canInvoke?.Invoke(definition) == false) return; e.Handled = true; try { await dispatcher.ExecuteAsync(new(definition, "", true)); } catch (Exception error) { failed?.Invoke(error); } };
            owner.KeyboardAccelerators.Add(accelerator); installed.Add(accelerator);
        }
    }
    public void Dispose() { if (disposed) return; disposed = true; registry.Changed -= Changed; foreach (var old in installed) owner.KeyboardAccelerators.Remove(old); installed.Clear(); }
}
