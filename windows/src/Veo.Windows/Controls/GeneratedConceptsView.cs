using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Veo.Core;
using Windows.UI.ViewManagement;

namespace Veo_Windows.Controls;

sealed class GeneratedConceptsView : StackPanel
{
    readonly ConversationArtifact[] images;
    readonly Grid tiles = new() { ColumnSpacing = 10, RowSpacing = 10 };
    readonly Button compare = new() { Content = "Compare selected" };
    readonly TextBlock count = new() { FontSize = 12 };
    readonly TextBox feedback = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
        Header = "Feedback", MinHeight = 69 };
    readonly Button add = new() { Content = "Add feedback to draft" };
    readonly HashSet<int> selected = [];
    readonly Border[] cards;
    bool comparing;
    int columns;

    public GeneratedConceptsView(ThreadSession session, ConversationArtifact[] images,
        Func<IReadOnlyList<(int, ConversationArtifact)>, string, Task>? addToDraft)
    {
        this.images = images;
        Padding = new(12);
        Spacing = 10;
        var heading = new Grid();
        heading.ColumnDefinitions.Add(new());
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        heading.Children.Add(new TextBlock { Text = "Generated concepts", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        Grid.SetColumn(compare, 1);
        heading.Children.Add(compare);
        Children.Add(heading);
        Children.Add(tiles);
        Children.Add(feedback);
        Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { count, add } });
        cards = images.Select((image, index) =>
        {
            var check = new CheckBox { Content = $"Concept {index + 1}" };
            var card = new Border { BorderThickness = new(1), CornerRadius = new(8), Padding = new(7) };
            var tile = new StackPanel { Spacing = 5 };
            tile.Children.Add(new ConversationArtifactView(session, image with { Name = $"Concept {index + 1}" }, expanded: true, galleryThumbnail: true));
            tile.Children.Add(check);
            card.Child = tile;
            check.Checked += (_, _) => { selected.Add(index); SetState(); Mark(card, true); };
            check.Unchecked += (_, _) =>
            {
                selected.Remove(index);
                if (comparing && selected.Count < 2) ChangeComparison(false);
                else if (comparing) Arrange();
                SetState(); Mark(card, false);
            };
            Mark(card, false);
            return card;
        }).ToArray();
        compare.Click += (_, _) => ChangeComparison(!comparing);
        feedback.TextChanged += (_, _) => SetState();
        add.Click += async (_, _) =>
        {
            if (addToDraft is null || selected.Count == 0 || string.IsNullOrWhiteSpace(feedback.Text)) return;
            await addToDraft(selected.Order().Select(index => (index + 1, images[index])).ToArray(), feedback.Text.Trim());
            feedback.Text = "";
            count.Text = "Added to draft";
        };
        SizeChanged += (_, _) =>
        {
            var proposed = Math.Max(1, (int)(ActualWidth / (comparing ? 270 : 205)));
            if (proposed != columns) Arrange();
        };
        SetState();
        Arrange();
    }

    void ChangeComparison(bool enabled)
    {
        comparing = enabled;
        Arrange();
        SetState();
        if (!new UISettings().AnimationsEnabled) return;
        var fade = new DoubleAnimation { From = .2, To = 1, Duration = new Duration(TimeSpan.FromMilliseconds(175)) };
        var storyboard = new Storyboard();
        storyboard.Children.Add(fade);
        Storyboard.SetTarget(fade, tiles);
        Storyboard.SetTargetProperty(fade, "Opacity");
        storyboard.Begin();
    }

    void Arrange()
    {
        columns = Math.Max(1, (int)(ActualWidth / (comparing ? 270 : 205)));
        tiles.Children.Clear();
        tiles.ColumnDefinitions.Clear();
        tiles.RowDefinitions.Clear();
        for (var index = 0; index < columns; index++) tiles.ColumnDefinitions.Add(new());
        var position = 0;
        for (var index = 0; index < cards.Length; index++)
        {
            if (comparing && !selected.Contains(index)) continue;
            if (position % columns == 0) tiles.RowDefinitions.Add(new() { Height = GridLength.Auto });
            Grid.SetColumn(cards[index], position % columns);
            Grid.SetRow(cards[index], position / columns);
            tiles.Children.Add(cards[index]);
            position++;
        }
    }

    static void Mark(Border card, bool active) => card.BorderBrush = new SolidColorBrush(active
        ? Microsoft.UI.Colors.DodgerBlue : Microsoft.UI.ColorHelper.FromArgb(70, 120, 130, 140));

    void SetState()
    {
        compare.Content = comparing ? "Show all concepts" : "Compare selected";
        compare.IsEnabled = comparing || selected.Count >= 2;
        count.Text = $"{selected.Count} selected";
        add.IsEnabled = selected.Count > 0 && !string.IsNullOrWhiteSpace(feedback.Text);
        AutomationProperties.SetName(tiles, comparing ? "Selected concepts" : "All concepts");
    }
}
