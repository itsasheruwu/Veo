#nullable enable
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Veo.Core;
using Veo.Protocol;
using Veo_Windows.ViewModels;

namespace Veo_Windows.Controls;

public sealed partial class TimelineMessageView
{
    internal bool InlineRobloxTool { get; init; }
    TextBlock? robloxTitle;
    TextBlock? robloxDuration;
    TextBlock? robloxResult;
    TextBlock? robloxArguments;
    Expander? robloxInputs;

    void BuildRobloxToolStep(StackPanel column)
    {
        robloxTitle = Caption("");
        robloxTitle.FontSize = 11;
        robloxDuration = Caption("");
        robloxDuration.FontSize = 10;
        var heading = new Grid { ColumnSpacing = 7 };
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        heading.ColumnDefinitions.Add(new());
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        heading.Children.Add(Caption("•"));
        Grid.SetColumn(robloxTitle, 1);
        Grid.SetColumn(robloxDuration, 2);
        heading.Children.Add(robloxTitle);
        heading.Children.Add(robloxDuration);
        column.Children.Add(heading);

        var output = robloxResult = ToolText(maxLines: 4);
        column.Children.Add(output);
        var show = new HyperlinkButton { Content = "Show full output", FontSize = 11, Padding = new(0), Margin = new(15, 0, 0, 0), Visibility = Visibility.Collapsed };
        output.IsTextTrimmedChanged += (_, _) => show.Visibility = output.IsTextTrimmed || output.MaxLines == 0 ? Visibility.Visible : Visibility.Collapsed;
        show.Click += (_, _) =>
        {
            var expand = output.MaxLines != 0;
            output.MaxLines = expand ? 0 : 4;
            show.Content = expand ? "Show less" : "Show full output";
        };
        column.Children.Add(show);

        robloxArguments = ToolText();
        robloxInputs = new Expander { Header = "Inputs", Content = robloxArguments, Margin = new(15, 0, 0, 0), HorizontalAlignment = HorizontalAlignment.Left };
        column.Children.Add(robloxInputs);
    }

    TextBlock ToolText(int maxLines = 0) => new()
    {
        FontSize = 11.5, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap,
        TextTrimming = maxLines == 0 ? TextTrimming.None : TextTrimming.CharacterEllipsis, MaxLines = maxLines,
        Foreground = SecondaryForeground, Margin = new(15, 0, 0, 0)
    };

    void UpdateRobloxToolStep(MessageRow row, TimelineItemPresentation shown)
    {
        var call = row.Item;
        var running = row.Session.Timeline.IsRunning && TimelinePresentation.IsInProgress(call);
        var failed = TimelinePresentation.RobloxToolFailed(call);
        robloxTitle!.Text = shown.Title.ReplaceLineEndings(" ") + (failed ? " · Failed" : "");
        robloxDuration!.Text = call.Raw.TryGetProperty("durationMs", out var duration) && duration.ValueKind == JsonValueKind.Number && duration.TryGetDouble(out var milliseconds)
            ? milliseconds < 1000 ? $"{milliseconds:0} ms" : $"{milliseconds / 1000:0.0} s" : "";
        robloxResult!.Text = running ? "Running…" : call.Raw.Str("error") ?? shown.Body;
        robloxResult.Visibility = robloxResult.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        robloxArguments!.Text = call.Raw.TryGetProperty("arguments", out var arguments) && arguments.ValueKind is not (JsonValueKind.Undefined or JsonValueKind.Null)
            ? arguments.GetRawText() : "";
        robloxInputs!.Visibility = robloxArguments.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    bool RenderSpecialActivity(MessageRow row)
    {
        var item = row.Item;
        if (item.Kind is not ("veoRobloxGroup" or "imageGeneration") && !TimelinePresentation.IsResearch(item)) return false;
        var identity = row.Session.Record.VeoId + "|special|" + row.Id;
        if (item.Kind == "veoRobloxGroup")
        {
            var group = presentationKey == identity && Content is RobloxActivityGroup existing
                ? existing : new RobloxActivityGroup(SecondaryForeground);
            group.Update(row);
            if (!ReferenceEquals(Content, group)) Content = group;
        }
        else
        {
            var finish = !row.Session.Timeline.IsRunning || !TimelinePresentation.IsInProgress(item);
            var research = TimelinePresentation.IsResearch(item);
            var signature = identity + "|" + finish + "|" + item.Status + "|" + item.Raw.GetRawText().GetHashCode(StringComparison.Ordinal);
            if (presentationKey == signature) return true;
            identity = signature;
            if (!finish && !research) Content = new GeneratedImageSweep();
            else
            {
                var presentation = TimelinePresentation.Item(item);
                var failed = item.Status is "failed" or "error" || item.Raw.TryGetProperty("failure", out var failure) && failure.ValueKind == JsonValueKind.Object;
                var canceled = item.Status is "canceled" or "cancelled" or "aborted" or "interrupted"
                    || finish && TimelinePresentation.IsInProgress(item);
                var label = research ? canceled ? "Reference canceled" : failed ? "Reference failed" :
                    finish ? item.Kind == "imageGeneration" ? "Referenced generation" : "Referenced" :
                    item.Kind == "imageGeneration" ? "Generating reference" : "Referencing"
                    : canceled ? "Image generation interrupted" : failed ? "Image generation failed" : "Generated image";
                var box = new StackPanel { Spacing = 7 };
                if (research)
                {
                    var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                    title.Children.Add(ModelPickerVisuals.WildIcon(new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(255, 218, 100, 152))));
                    title.Children.Add(Caption(label));
                    box.Children.Add(title);
                    if (!finish) GeneratedImageSweep.Shimmer(title);
                }
                else box.Children.Add(Caption(label));
                if (presentation.Artifacts.Length > 0)
                    foreach (var artifact in presentation.Artifacts)
                        box.Children.Add(new ConversationArtifactView(row.Session, artifact, expanded: !research));
                else if (presentation.Body.Length > 0 && (failed || research))
                    box.Children.Add(new TextBlock { Text = presentation.Body, TextWrapping = TextWrapping.Wrap });
                Content = box;
            }
        }
        presentationKey = identity;
        return true;
    }
}
