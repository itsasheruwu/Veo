using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Veo_Windows.Services;

namespace Veo_Windows.Controls;

public sealed partial class SettingsPanel
{
    void ShowProviders()
    {
        var navigation = new SelectorBar();
        var connections = new SelectorBarItem { Text = "Connections", IsSelected = true };
        var enabledModels = new SelectorBarItem { Text = "Enabled models" };
        navigation.Items.Add(connections);
        navigation.Items.Add(enabledModels);
        Sections.Children.Add(navigation);
        var directory = new AgentDirectory(workspace);
        Sections.Children.Add(directory);
        var api = new Expander
        {
            Header = "API connections",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = new ProvidersPanel(workspace, uri => _ = App.Main?.NavigateBrowserAsync(uri))
        };
        Sections.Children.Add(api);
        var models = Section("Enabled models");
        var search = new TextBox { PlaceholderText = "Find a model", Margin = new Thickness(12, 8, 12, 4) };
        var rows = new StackPanel { Spacing = 2, Padding = new Thickness(10) };
        models.Children.Add(search);
        models.Children.Add(new ScrollViewer { Content = rows, MaxHeight = 370 });
        // Section adds the titled container to the settings document.
        var modelSection = Sections.Children.Last();
        void Refresh()
        {
            rows.Children.Clear();
            void Add(string title, bool enabled, Func<bool, Task> change)
            {
                if (!title.Contains(search.Text, StringComparison.OrdinalIgnoreCase)) return;
                var toggle = new ToggleSwitch { IsOn = enabled, OnContent = "", OffContent = "", MinWidth = 0, HorizontalAlignment = HorizontalAlignment.Right };
                AutomationProperties.SetName(toggle, title);
                toggle.Toggled += async (_, _) => { await RunAsync(() => change(toggle.IsOn)); Refresh(); };
                var row = new Grid { ColumnSpacing=12, Padding=new Thickness(8,3,8,3) };
                row.ColumnDefinitions.Add(new()); row.ColumnDefinitions.Add(new(){ Width=GridLength.Auto });
                row.Children.Add(new TextBlock { Text=title, VerticalAlignment=VerticalAlignment.Center, TextTrimming=TextTrimming.CharacterEllipsis });
                Grid.SetColumn(toggle,1);
                row.Children.Add(toggle);
                rows.Children.Add(row);
            }
            void Group(string name) => rows.Children.Add(new TextBlock { Text=name,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold, Margin=new Thickness(8,10,0,3) });
            Group("Codex and API models");
            foreach (var model in App.Models.Catalog.Where(m => !m.IsStandaloneDaybreak))
                Add(model.DisplayName, App.Models.Visible.Any(m => m.Id == model.Id), on => App.Models.SetEnabledAsync(model.Id,on));
            var agents = AgentConnections.For(workspace);
            foreach (var (id, connection) in agents.Connections)
            {
                Group(AgentConnections.Catalog.First(a => a.Id == id).Name);
                foreach (var model in connection.PickerModels)
                    Add(model.Name, !connection.Hidden.Contains(model.Id), on => { agents.Toggle(id,model.Id,on); return Task.CompletedTask; });
            }
        }
        void CatalogChanged() => DispatcherQueue.TryEnqueue(() => {
            if (navigation.IsLoaded && navigation.SelectedItem == enabledModels) Refresh();
        });
        navigation.Loaded += (_, _) => App.Models.Changed += CatalogChanged;
        navigation.Unloaded += (_, _) => App.Models.Changed -= CatalogChanged;
        search.TextChanged += (_, _) => Refresh();
        navigation.SelectionChanged += (_, _) =>
        {
            bool showModels = navigation.SelectedItem == enabledModels;
            directory.Visibility = api.Visibility = showModels ? Visibility.Collapsed : Visibility.Visible;
            modelSection.Visibility = showModels ? Visibility.Visible : Visibility.Collapsed;
            if (showModels) Refresh();
        };
        modelSection.Visibility = Visibility.Collapsed;
    }
}
