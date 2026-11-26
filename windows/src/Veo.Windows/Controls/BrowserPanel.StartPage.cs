using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;

namespace Veo_Windows.Controls;

public sealed partial class BrowserPanel
{
    sealed class BrowserStartPage : Grid
    {
        const string Layout = """
            <StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                        VerticalAlignment="Center" MaxWidth="400" Margin="16" Spacing="12">
                <TextBlock Text="What should we look up?" FontSize="20" FontWeight="SemiBold"
                           TextAlignment="Center" TextWrapping="Wrap"
                           HorizontalAlignment="Center" />
                <Border Background="{ThemeResource CardBackgroundFillColorDefaultBrush}"
                        BorderBrush="{ThemeResource DividerStrokeColorDefaultBrush}"
                        BorderThickness="1" CornerRadius="12" Padding="10,4,5,4">
                    <Grid ColumnSpacing="6">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <FontIcon Glyph="&#xE721;" FontSize="14" IsHitTestVisible="False" VerticalAlignment="Center"
                                  Foreground="{ThemeResource TextFillColorSecondaryBrush}" />
                        <TextBox x:Name="SearchInput" Grid.Column="1" MinWidth="0" MinHeight="32"
                                 Background="Transparent" BorderThickness="0" Padding="4,5"
                                 IsSpellCheckEnabled="False" IsTextPredictionEnabled="False"
                                 UseSystemFocusVisuals="True" />
                        <Button x:Name="GoButton" Grid.Column="2" VerticalAlignment="Center"
                                MinWidth="0" MinHeight="0" Width="28" Height="28" Padding="0"
                                CornerRadius="14" IsEnabled="False" ToolTipService.ToolTip="Search or open address">
                            <FontIcon Glyph="&#xE72A;" FontSize="13" />
                        </Button>
                    </Grid>
                </Border>
            </StackPanel>
            """;

        readonly TextBox search;
        readonly Func<string> searchEngine;
        bool focusOnLoad;

        public event Action<string>? Submit;

        public BrowserStartPage(Func<string> searchEngine)
        {
            this.searchEngine = searchEngine;
            var layout = (StackPanel)XamlReader.Load(Layout);
            search = (TextBox)layout.FindName("SearchInput");
            var go = (Button)layout.FindName("GoButton");
            AutomationProperties.SetAutomationId(search, "BrowserStartSearch");
            AutomationProperties.SetName(search, "Start page search or address");
            AutomationProperties.SetAutomationId(go, "BrowserStartGo");
            AutomationProperties.SetName(go, "Search or open address");

            RefreshSearchEngine();
            search.Loaded += (_, _) =>
            {
                RefreshSearchEngine();
                if (focusOnLoad)
                {
                    focusOnLoad = false;
                    search.Focus(FocusState.Programmatic);
                }
            };
            search.GotFocus += (_, _) => RefreshSearchEngine();
            search.TextChanged += (_, _) => go.IsEnabled = !string.IsNullOrWhiteSpace(search.Text);
            search.KeyDown += (_, e) =>
            {
                if (e.Key == Windows.System.VirtualKey.Enter && go.IsEnabled)
                {
                    e.Handled = true;
                    Submit?.Invoke(search.Text);
                }
            };
            go.Click += (_, _) => Submit?.Invoke(search.Text);
            Children.Add(layout);
        }

        public void FocusSearch()
        {
            if (search.IsLoaded)
                search.Focus(FocusState.Programmatic);
            else
                focusOnLoad = true;
        }

        public void RefreshSearchEngine() => search.PlaceholderText = $"Search {searchEngine()} or URL";
    }
}
