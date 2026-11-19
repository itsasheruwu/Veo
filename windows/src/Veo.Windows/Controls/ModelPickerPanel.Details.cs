using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Veo.Core;

using Metrics = Veo_Windows.Controls.ModelPickerVisuals;

namespace Veo_Windows.Controls;

public sealed partial class ModelPickerPanel
{
    static class DetailsMetrics
    {
        internal const double Width = 340;
        internal const double Height = 360;
        internal const double Inset = 16;
        internal const double SectionGap = 14;
        internal const double LineGap = 5;
        internal const double Heading = 13;
        internal const double BodyText = 12.5;
        internal const double Caption = 11;
    }

    Flyout? advancedDetails;

    void ShowAdvancedDetails(Button anchor)
    {
        if (advancedDetails is { } open) { open.Hide(); return; }

        var sections = new StackPanel { Margin = new(DetailsMetrics.Inset), Spacing = DetailsMetrics.SectionGap };
        var model = Model;
        var speed = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var provider = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch, Visibility = Visibility.Collapsed };
        var catalogStale = selection.CatalogNeedsRefresh;

        if (choice?.RoutingMode is "Family56" or "Family6")
        {
            AddFamilyDetails(sections, choice.FamilyPlan, choice.RoutingMode == "Family56" ? "5.6" : "6");
            model = null;
        }
        else if (model is not null)
        {
            sections.Children.Add(DetailsHeader(model.DisplayName, model.Description));
            if (model.AvailabilityNotice is { Length: > 0 } notice)
                sections.Children.Add(DetailsIconLine(notice, Metrics.InfoMark(primary)));

            speed.Content = DetailsSpeedAvailability(model, null, catalogStale ? "Checking…" : null);
            sections.Children.Add(speed);

            if (model.SupportsPersonality) AddPersonalityDetails(sections);
            if (model.Specialty is { Length: > 0 } specialty)
                sections.Children.Add(DetailsValue("Specialty", specialty));
            if (model.MultiAgentVersion is { Length: > 0 } version && version != "disabled")
                sections.Children.Add(DetailsValue("Multi-agent support", version.ToUpperInvariant()));
            sections.Children.Add(provider);
            AddUpgradeDetails(sections, model);
        }
        else sections.Children.Add(DetailsHeader("No model selected", ""));

        var scroll = new ScrollViewer
        {
            Width = DetailsMetrics.Width,
            Height = Math.Min(DetailsMetrics.Height, Math.Max(100, (XamlRoot?.Size.Height ?? DetailsMetrics.Height) - 24)),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = sections
        };
        AutomationProperties.SetName(scroll, "Model details");
        AutomationProperties.SetAutomationId(scroll, "AdvancedModelDetails");
        var card = new Border { CornerRadius = new(Metrics.CornerRadius), Background = pickerCard.Background, Child = scroll };
        var flyout = new Flyout
        {
            Content = new StackPanel { Children = { card, Metrics.PickerPointer(card.Background) } },
            Placement = FlyoutPlacementMode.Top,
            ShouldConstrainToRootBounds = false,
            AreOpenCloseAnimationsEnabled = Metrics.MotionEnabled,
            FlyoutPresenterStyle = detailsPresenter
        };
        var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(4));
        flyout.Closed += (_, _) =>
        {
            if (ReferenceEquals(advancedDetails, flyout)) advancedDetails = null;
            cancellation.Cancel();
            cancellation.Dispose();
        };
        advancedDetails = flyout;
        var token = cancellation.Token;
        flyout.ShowAt(anchor);
        if (model is not null)
        {
            _ = LoadSpeedDetailsAsync(flyout, model, speed, catalogStale, token);
            _ = LoadProviderDetailsAsync(flyout, provider, token);
        }
    }

    async Task LoadSpeedDetailsAsync(Flyout flyout, NativeModelDescriptor model, ContentControl speed,
        bool catalogStale, CancellationToken cancellation)
    {
        var identityTask = ReadDetailsMetadataAsync(App.Accounts.ReadIdentityAsync, cancellation);
        string? status = null;
        if (catalogStale)
        {
            try
            {
                await selection.RefreshAsync(cancellation);
                if (selection.Find(model.Id) is { } updated && !selection.CatalogNeedsRefresh) model = updated;
                else status = "Couldn’t verify";
            }
            catch (Exception error) when (IsDetailsReadError(error)) { status = "Couldn’t verify"; }
        }

        var identity = await identityTask;
        if (ReferenceEquals(advancedDetails, flyout))
            speed.Content = DetailsSpeedAvailability(model, identity, status);
    }

    async Task LoadProviderDetailsAsync(Flyout flyout, ContentControl host, CancellationToken cancellation)
    {
        var tools = await ReadDetailsMetadataAsync(selection.ReadProviderToolsAsync, cancellation);
        if (tools is null || !ReferenceEquals(advancedDetails, flyout)) return;
        var section = new StackPanel { Spacing = DetailsMetrics.LineGap };
        section.Children.Add(Label("Provider tools", DetailsMetrics.BodyText, true));
        if (tools.WebSearch) section.Children.Add(DetailsIconLine("Web search", Icon("\uE774", 12, primary)));
        if (tools.ImageGeneration) section.Children.Add(DetailsIconLine("Image generation", Icon("\uEB9F", 12, primary)));
        if (!tools.WebSearch && !tools.ImageGeneration)
            section.Children.Add(DetailsText("No additional tools reported.", muted: true));
        host.Content = section;
        host.Visibility = Visibility.Visible;
    }

    static async Task<T?> ReadDetailsMetadataAsync<T>(Func<CancellationToken, Task<T?>> read, CancellationToken cancellation) where T : class
    {
        try { return await read(cancellation); }
        catch (Exception error) when (IsDetailsReadError(error)) { return null; }
    }

    static bool IsDetailsReadError(Exception error) =>
        error is IOException or InvalidOperationException or NotSupportedException or Veo.Protocol.CodexRpcException or OperationCanceledException;

    StackPanel DetailsSpeedAvailability(NativeModelDescriptor model, AccountIdentity? identity, string? pendingStatus = null)
    {
        var content = new StackPanel { Spacing = DetailsMetrics.LineGap };
        content.Children.Add(Label(!model.IsExternal && identity?.Type == "chatgpt" ? "Speed on your plan" : "Speed availability",
            DetailsMetrics.BodyText, true));

        content.Children.Add(DetailsValue("Fast",
            pendingStatus ?? (!model.IsSpark && model.FastTier is not null ? "Supported" : "Not supported"),
            "DetailsFastAvailability"));
        content.Children.Add(DetailsValue("Ultrafast",
            pendingStatus ?? (model.IsSpark ? "Always on" : model.UltrafastTier is not null ? "Supported" : "Not supported"),
            "DetailsUltraFastAvailability"));
        return content;
    }

    void AddPersonalityDetails(StackPanel sections)
    {
        var support = App.ThreadSettings.PersonalitySupport();
        if (support.Deprecated || support.Choices.Length == 0) return;
        var section = new StackPanel { Spacing = 6 };
        var controls = new RadioButtons
        {
            Header = "Personality",
            ItemsSource = support.Choices.Select(choice => System.Globalization.CultureInfo.CurrentCulture.TextInfo.ToTitleCase(choice)).ToArray(),
            MaxColumns = 3,
            IsEnabled = session.Record.CodexThreadId is not null
        };
        controls.SelectionChanged += (_, _) =>
        {
            if (controls.SelectedIndex is var index && index >= 0 && index < support.Choices.Length)
                Run(() => App.ThreadSettings.SetPersonalityAsync(session, support.Choices[index]));
        };
        section.Children.Add(controls);
        section.Children.Add(DetailsText("Changes apply to the next turn.", muted: true, size: DetailsMetrics.Caption));
        sections.Children.Add(section);
    }

    void AddFamilyDetails(StackPanel sections, FamilyAutoPlan? family, string version)
    {
        sections.Children.Add(DetailsHeader(version + " Auto",
            "Veo coordinates the GPT-" + version + " family, with separate implementation and review when multi-agent support is available."));
        if (family is null)
        {
            sections.Children.Add(DetailsIconLine("Auto routing is unavailable.", Icon("\uE7BA", 12, primary)));
            return;
        }

        void AddLane(string title, FamilyAutoLane lane)
        {
            var row = new StackPanel { Spacing = 3 };
            row.Children.Add(Label(title, DetailsMetrics.BodyText, true));
            row.Children.Add(DetailsText(lane.Name + " · " + new ModelReasoning(lane.Effort, "").Title, muted: true));
            sections.Children.Add(row);
        }

        AddLane("Lead", family.Parent);
        if (family.UsesMultiAgent)
        {
            AddLane("Implementation", family.Routine);
            AddLane("Escalation", family.Escalation);
            AddLane("Review", family.Reviewer);
        }
        if (family.Warnings.Length > 0)
        {
            sections.Children.Add(Rule(new(0)));
            foreach (var warning in family.Warnings) sections.Children.Add(DetailsIconLine(warning, Icon("\uE7BA", 12, primary)));
        }
        sections.Children.Add(DetailsText("The route is fixed when you send a message. Planning requests stay with the lead model.",
            muted: true, size: DetailsMetrics.Caption));
    }

    void AddUpgradeDetails(StackPanel sections, NativeModelDescriptor model)
    {
        if (model.Upgrade is null && model.UpgradeCopy is null && model.RetirementAt is null) return;
        sections.Children.Add(Rule(new(0)));
        var upgrade = new StackPanel { Spacing = 6 };
        if (model.UpgradeCopy is { Length: > 0 } copy)
            upgrade.Children.Add(DetailsText(copy));
        else if (model.Upgrade is { Length: > 0 } suggestion)
            upgrade.Children.Add(DetailsText("Suggested upgrade: " + suggestion));
        if (model.RetirementAt is { } retirement)
            upgrade.Children.Add(DetailsValue("Scheduled retirement", retirement.ToString("MMM d, yyyy")));
        if (model.MigrationMarkdown is { Length: > 0 } migration)
            upgrade.Children.Add(new MarkdownView { Markdown = migration, Session = session, Opacity = .75 });
        if (Uri.TryCreate(model.UpgradeLink, UriKind.Absolute, out var link) && link.Scheme == Uri.UriSchemeHttps)
            upgrade.Children.Add(new HyperlinkButton { Content = "Upgrade information", NavigateUri = link, Padding = new(0) });
        sections.Children.Add(upgrade);
    }

    StackPanel DetailsHeader(string title, string description)
    {
        var header = new StackPanel { Spacing = DetailsMetrics.LineGap };
        var text = DetailsText(title, size: DetailsMetrics.Heading);
        text.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        header.Children.Add(text);
        if (description.Length > 0) header.Children.Add(DetailsText(description, muted: true));
        return header;
    }

    StackPanel DetailsValue(string title, string value, string? id = null)
    {
        var status = DetailsText(value);
        if (id is not null) AutomationProperties.SetAutomationId(status, id);
        return new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Children = { DetailsText(title), status }
        };
    }

    Grid DetailsIconLine(string text, FrameworkElement icon)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(14) });
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(icon);
        var label = DetailsText(text);
        Grid.SetColumn(label, 1);
        row.Children.Add(label);
        return row;
    }

    TextBlock DetailsText(string text, bool muted = false, double size = DetailsMetrics.BodyText) => new()
    {
        Text = text, FontSize = size, Foreground = muted ? secondary : primary, TextWrapping = TextWrapping.Wrap
    };
}
