using System.Numerics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Veo.Core;
using Veo.Protocol;
using Windows.Foundation;
using Windows.System;
using Windows.UI;
using Windows.UI.ViewManagement;

using Metrics = Veo_Windows.Controls.ModelPickerVisuals;

namespace Veo_Windows.Controls;

/// <summary>The two model pickers share the live catalog and persistent selection.</summary>
public sealed partial class ModelPickerPanel : UserControl
{
    enum Page { Compact, Advanced, Studio, Models }
    readonly ModelSelectionService selection;
    readonly AutoRoutingCoordinator routing;
    readonly ThreadSession session;
    readonly Func<ComposerSnapshot> current;
    readonly Action<ModelSelectionChoice> apply;
    readonly Style dropdownPresenter;
    readonly Style dropdownItem;
    readonly Style modelOptionsPresenter;
    readonly Style detailsPresenter;
    Flyout? openModelOptions;
    TextBlock? advancedModelValue;
    Button? advancedModelAnchor;
    StackPanel? advancedOptions;
    readonly ContentControl presenter = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    readonly InfoBar error = new() { Severity = InfoBarSeverity.Error, IsClosable = true };
    readonly SemaphoreSlim edits = new(1, 1);
    readonly SolidColorBrush primary = new();
    readonly SolidColorBrush secondary = new();
    readonly SolidColorBrush tertiary = new();
    readonly SolidColorBrush peak = new();
    readonly SolidColorBrush ultrafastColor = new();
    readonly SolidColorBrush fastColor = new();
    readonly SolidColorBrush fallbackSurface = new();
    readonly AcrylicBrush popoverSurface = new() { TintOpacity = .76, TintLuminosityOpacity = .9 };
    readonly SolidColorBrush divider = new();
    readonly SolidColorBrush selectedBrush = new();
    readonly SolidColorBrush faintTrack = new();
    readonly ModelEffortSlider slider = new();
    readonly PathGeometry boltOutline = Metrics.BoltGeometry(outline: true);
    readonly PathGeometry boltFill = Metrics.BoltGeometry();
    readonly PathGeometry boltPair = Metrics.BoltGeometry(pair: true);
    readonly Grid compactActions = new();
    readonly TextBlock hoverLeft = Label("", Metrics.Label);
    readonly TextBlock hoverRight = Label("Smarter", Metrics.Label);
    readonly TextBlock placeholder = Label("", 11.5);
    readonly TextBlock reasoningValue = Label("", Metrics.ReasoningCaption, true);
    Grid? reasoningCaption;
    bool? headerEngaged;
    readonly StackPanel compactPolicy = new() { Spacing = 5 };
    readonly ScrollViewer? studioScroll;
    readonly Border pickerCard;
    readonly Microsoft.UI.Xaml.Shapes.Path pickerPointer;
    ControlTemplate? toggleTemplate;
    StackPanel? compactPage;
    Button? expand;
    Button? bolt;
    Microsoft.UI.Xaml.Shapes.Path? boltIcon;
    Border? placeholderCapsule;
    Page page;
    ModelSelectionChoice? choice;
    bool locked;
    bool initialized;
    bool editingContext;
    string? contextError;
    TextBlock? contextFeedback;
    bool? configuredDaybreak;
    int daybreakRevision;
    string scope = "Global";

    NativeModelDescriptor? Model => selection.Find(choice?.ModelId);
    AutoRouterPolicy Policy => choice?.RouterPolicy ?? selection.RouterPolicy;
    bool Direct => choice?.RoutingMode == "Direct" && !locked;
    bool Auto => choice?.RoutingMode == "FirstPrompt" || locked;
    bool AutoEditable => Auto && !locked;
    ModelContextLimits? Limits => Model is { } model ? selection.Limits(model.Id) : null;
    ModelContextChoice Context => Model is { } model ? selection.ContextChoice(model.Id) : new();
    ModelServiceTier? Fast => Model?.FastTier;
    ModelServiceTier? Ultrafast => Model?.UltrafastTier;
    ModelSpeed SelectedSpeed => Model?.SpeedFor(choice?.Tier) ?? ModelSpeed.Standard;
    bool FastSelected => SelectedSpeed == ModelSpeed.Fast;
    bool UltrafastSelected => SelectedSpeed == ModelSpeed.Ultrafast;
    IReadOnlyList<ModelSpeedChoice> SpeedChoices => Model?.SpeedChoices() ?? [];
    bool CanSetDaybreak => Direct && Model is { SupportsDaybreakBlue: true } && selection.SupportsDaybreakBlue;
    bool CanSetStandard => Direct && Model is { SupportsStandardCyberAccess: true } && selection.SupportsStandardCyberAccess;
    bool DaybreakOn => choice?.Daybreak ?? (Direct && configuredDaybreak == true);
    bool NeedsStandardModel => Direct && choice?.Daybreak == false && Model?.SupportsDaybreakBlue == true && !CanSetStandard;
    bool ProtectDaybreak => choice?.Daybreak == true || CanSetDaybreak && DaybreakOn;
    bool CanToggleDaybreak => !locked && (DaybreakOn ? CanSetDaybreak || CanSetStandard || choice?.Daybreak == true : CanSetDaybreak);
    bool CanChooseModel(NativeModelDescriptor model) => !ProtectDaybreak || model.SupportsDaybreakBlue && selection.SupportsDaybreakBlue;
    const string DaybreakRequired = "Unavailable while Daybreak is on";
    const string StandardModelRequired = "Choose a Standard model to finish turning Daybreak off.";
    string DaybreakUnavailable => !Direct ? "Available with direct model selection"
        : !selection.SupportsDaybreakBlue ? "This Codex runtime does not expose Daybreak Blue"
        : "Choose a model that supports Daybreak Blue";
    string DaybreakHelp => NeedsStandardModel ? StandardModelRequired : CanSetDaybreak ? choice?.Daybreak is not null ? "Daybreak Blue" : configuredDaybreak switch
    {
        true => "On by Codex default",
        false => "Off by Codex default",
        null => "Uses the Codex default until changed"
    } : choice?.Daybreak == true ? "Turn off Daybreak to clear the unavailable selection" : DaybreakUnavailable;
    bool BluePalette => Model?.Names.Select(NativeModelDescriptor.Normalize).Any(Metrics.UsesBluePalette) == true;
    string ModelTitle => choice?.RoutingMode switch
    {
        "FirstPrompt" when !locked => "Auto",
        "Family56" => "5.6 Auto",
        "Family6" => "6 Auto",
        _ => Model?.DisplayName ?? "No model selected"
    };

    public ModelPickerPanel(ModelSelectionService selection, AutoRoutingCoordinator routing, ThreadSession session,
        Func<ComposerSnapshot> current, Action<ModelSelectionChoice> apply, bool advanced, double studioHeight, ResourceDictionary resources)
    {
        this.selection = selection;
        this.routing = routing;
        this.session = session;
        this.current = current;
        this.apply = apply;
        dropdownPresenter = (Style)resources["ModelDropdownPresenter"];
        dropdownItem = (Style)resources["ModelDropdownItem"];
        modelOptionsPresenter = (Style)resources["ModelOptionsPresenter"];
        detailsPresenter = new Style(typeof(FlyoutPresenter))
        {
            BasedOn = (Style)resources["ModelPickerFlyoutPresenter"],
            Setters = { new Setter(MaxWidthProperty, DetailsMetrics.Width) }
        };
        page = advanced ? Page.Compact : Page.Studio;
        Width = advanced ? Metrics.SliderWidth : Metrics.StudioWidth;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;
        AutomationProperties.SetName(this, advanced ? "Model, effort, and speed" : "Model studio");
        AutomationProperties.SetAutomationId(error, "ModelPickerError");
        var surface = new StackPanel();
        surface.Children.Add(presenter);
        surface.Children.Add(error);
        if (!advanced)
        {
            studioScroll = new ScrollViewer
            {
                Height = studioHeight,
                Content = surface,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalContentAlignment = HorizontalAlignment.Stretch
            };
            AutomationProperties.SetName(studioScroll, "Model studio options");
            AutomationProperties.SetAutomationId(studioScroll, "ModelStudioScroll");
        }

        pickerCard = new Border
        {
            CornerRadius = new(Metrics.CornerRadius),
            Child = (UIElement?)studioScroll ?? surface
        };
        pickerPointer = Metrics.PickerPointer(popoverSurface);
        Content = new StackPanel { Children = { pickerCard, pickerPointer } };
        ActualThemeChanged += (_, _) => UpdateTheme();
        Loaded += (_, _) =>
        {
            UpdateTheme();
            if (!initialized) Run(InitializeAsync);
        };
        Unloaded += (_, _) => advancedDetails?.Hide();
        KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Escape) return;
            if (advancedDetails is { } details) { e.Handled = true; details.Hide(); }
            else if (editingContext) { e.Handled = true; EndContextEdit(); Refresh(); }
            else if (page == Page.Advanced) { e.Handled = true; Navigate(Page.Compact); }
            else if (page == Page.Models) { e.Handled = true; Navigate(Page.Studio); }
        };
    }

    async Task InitializeAsync()
    {
        if (initialized) return;
        await selection.InitializeAsync();
        if (selection.CatalogNeedsRefresh) await selection.RefreshAsync();
        await routing.ObserveAsync(session);
        var snapshot = current();
        var saved = await selection.ResolveAsync(session);
        var fixedRoute = routing.LockedRoute(session);
        locked = fixedRoute is not null;
        var live = selection.Find(snapshot.CatalogModelId) ?? selection.Find(snapshot.Model);
        choice = fixedRoute?.Choice ?? (live is null || selection.RequiresGPT56OptIn(live.Id, snapshot.RoutingMode) ? saved :
            new(live.Id, live.Model, snapshot.Effort, snapshot.Tier, snapshot.ContextTokens,
                snapshot.RoutingMode, snapshot.RouterPolicy, snapshot.FamilyPlan) { Daybreak = snapshot.Daybreak });
        initialized = true;
        Refresh();
        if (page == Page.Compact) FocusCompact();
        _ = ReadDaybreakDefaultAsync();
    }

    async Task ReadDaybreakDefaultAsync()
    {
        var revision = daybreakRevision;
        var value = await selection.ReadConfiguredDaybreakAsync(session.Record.Cwd);
        if (!IsLoaded || revision != daybreakRevision || choice?.Daybreak is not null || !value.HasValue) return;
        configuredDaybreak = value;
        if (page is Page.Studio or Page.Models && !editingContext) Refresh();
    }

    void Navigate(Page destination)
    {
        if (destination == page) return;
        EndContextEdit();
        page = destination;
        Refresh();
        studioScroll?.ChangeView(null, 0, null, true);
        if (presenter.Content is FrameworkElement content)
        {
            var studioPage = destination is Page.Studio or Page.Models;
            var translation = studioPage
                ? new Vector3(destination == Page.Models ? 16 : -16, 0, 0)
                : new Vector3(0, destination == Page.Advanced ? 6 : -4, 0);
            Metrics.Reveal(content, translation, studioPage ? 200 : 160);
        }
        if (destination == Page.Compact) FocusCompact();
        else if (presenter.Content is Panel panel && panel.Children.OfType<Button>().FirstOrDefault(button => button.IsEnabled) is { } first)
            DispatcherQueue.TryEnqueue(() => first.Focus(FocusState.Programmatic));
    }

    void FocusCompact() => DispatcherQueue.TryEnqueue(() =>
    {
        if (slider.Visibility == Visibility.Visible && slider.IsEnabled) slider.Focus(FocusState.Programmatic);
        else expand?.Focus(FocusState.Programmatic);
    });

    void Refresh()
    {
        UpdateTheme();
        if (page == Page.Compact)
        {
            compactPage ??= MakeCompact();
            if (!ReferenceEquals(presenter.Content, compactPage)) presenter.Content = compactPage;
            UpdateCompact();
            return;
        }
        if (page == Page.Advanced && openModelOptions is not null &&
            advancedModelValue is { } modelValue && advancedModelAnchor is { } modelAnchor && advancedOptions is { } options)
        {
            // A live flyout stays attached to its existing anchor as its switches change the rest of Advanced.
            modelValue.Text = ModelTitle;
            AutomationProperties.SetItemStatus(modelAnchor, ModelTitle);
            FillAdvancedOptions(options);
            return;
        }
        presenter.Content = page switch { Page.Advanced => MakeAdvanced(), Page.Models => MakeModelList(), _ => MakeStudio() };
    }

    StackPanel MakeCompact()
    {
        expand = PageButton("Advanced", "\uE76C", () => Navigate(Page.Advanced), "ShowAdvancedModelPicker");
        expand.HorizontalAlignment = HorizontalAlignment.Left;
        compactActions.Children.Add(expand);
        boltIcon = new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = boltOutline, Width = 10, Height = 14, Fill = secondary, Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
        };
        var boltSlot = new Grid { Width = 16, Height = 16, Children = { boltIcon }, IsHitTestVisible = false };
        bolt = ButtonFor(boltSlot, "Speed", OpenCompactSpeed, Metrics.HeaderHeight, new(6, 0, 6, 0), "CompactFastMode");
        bolt.HorizontalAlignment = HorizontalAlignment.Right;
        compactActions.Children.Add(bolt);
        var header = new Grid { Height = Metrics.HeaderHeight, Margin = new(6, 0, 6, 0) };
        header.Children.Add(compactActions);
        foreach (var text in new[] { hoverLeft, hoverRight })
        {
            text.Foreground = secondary;
            text.Margin = new(6, 0, 6, 0);
            text.IsHitTestVisible = false;
            AutomationProperties.SetAccessibilityView(text, AccessibilityView.Raw);
            header.Children.Add(text);
        }
        hoverRight.HorizontalAlignment = HorizontalAlignment.Right;
        slider.PresentationChanged += UpdateCompactPresentation;
        slider.SelectionCommitted += index =>
        {
            if (Model?.Efforts.ElementAtOrDefault(index) is { } effort) Run(() => SetEffortAsync(effort));
        };
        var body = new Grid { Margin = new(Metrics.SliderInset, 0, Metrics.SliderInset, 0) };
        body.Children.Add(slider);
        placeholder.Foreground = secondary;
        placeholder.TextAlignment = TextAlignment.Center;
        placeholder.TextWrapping = TextWrapping.Wrap;
        placeholder.MaxLines = 2;
        placeholder.Margin = new(8, 3, 8, 3);
        placeholderCapsule = new Border { MinHeight = ModelEffortSlider.TrackHeight, Background = faintTrack, CornerRadius = new(ModelEffortSlider.TrackHeight / 2), Child = placeholder };
        body.Children.Add(placeholderCapsule);
        body.Children.Add(compactPolicy);
        reasoningCaption = Pair();
        reasoningCaption.Margin = new(Metrics.SliderInset, 0, Metrics.SliderInset, 0);
        reasoningCaption.Children.Add(Muted("Reasoning", Metrics.ReasoningCaption));
        Grid.SetColumn(reasoningValue, 1);
        reasoningCaption.Children.Add(reasoningValue);
        AutomationProperties.SetAccessibilityView(reasoningCaption, AccessibilityView.Raw);

        var panel = new StackPanel { Padding = new(0, 7, 0, 13), Spacing = Metrics.CompactSpacing };
        panel.Children.Add(header);
        panel.Children.Add(body);
        panel.Children.Add(reasoningCaption);
        return panel;
    }

    void UpdateCompact()
    {
        var options = Model?.Efforts ?? [];
        var showSlider = Direct && options.Length > 1;
        slider.Visibility = Show(showSlider);
        slider.IsEnabled = showSlider;
        slider.Configure(options.Select(effort => effort.Title).ToArray(),
            Array.FindIndex(options, effort => effort.Id == (choice?.Effort ?? Model?.DefaultEffort)), BluePalette, FastSelected);
        compactPolicy.Children.Clear();
        compactPolicy.Visibility = Show(AutoEditable);
        if (AutoEditable) AddPolicyRows(compactPolicy);
        if (placeholderCapsule is not null) placeholderCapsule.Visibility = Show(!showSlider && !AutoEditable);
        placeholder.Text = locked ? "Auto route locked for this chat"
            : !Direct ? "Auto picks the effort for each turn"
            : options.Length == 1 ? "This model has one effort level" : "Reasoning effort is unavailable";
        if (bolt is not null && boltIcon is not null)
        {
            bolt.Visibility = Show(Direct && (SpeedChoices.Count > 0 || Model?.IsSpark == true));
            bolt.IsEnabled = Model?.IsSpark != true;
            boltIcon.Data = UltrafastSelected ? boltPair : FastSelected ? boltFill : boltOutline;
            boltIcon.Width = UltrafastSelected ? 15 : 10;
            boltIcon.Fill = UltrafastSelected ? ultrafastColor : FastSelected ? fastColor : secondary;
            AutomationProperties.SetItemStatus(bolt, SpeedTitle());
            ToolTipService.SetToolTip(bolt, Model?.IsSpark == true ? "Ultrafast is always on for this model."
                : Ultrafast is not null ? "Choose Standard, Fast, or Ultrafast"
                : FastSelected ? "Turn off Fast" : "Turn on Fast");
        }
        UpdateCompactPresentation();
    }

    void UpdateCompactPresentation()
    {
        var showingSlider = slider.Visibility == Visibility.Visible;
        var engaged = showingSlider && slider.IsEngaged;
        if (reasoningCaption is not null)
        {
            reasoningCaption.Visibility = Show(showingSlider);
            reasoningValue.Text = slider.CurrentTitle;
        }

        if (headerEngaged != engaged)
        {
            compactActions.IsHitTestVisible = !engaged;
            if (expand is not null) expand.IsTabStop = !engaged;
            if (bolt is not null) bolt.IsTabStop = !engaged;
            if (headerEngaged is null)
            {
                compactActions.Opacity = engaged ? 0 : 1;
                hoverLeft.Opacity = hoverRight.Opacity = engaged ? 1 : 0;
            }
            else
            {
                Metrics.FadeTo(compactActions, engaged ? 0 : 1);
                Metrics.FadeTo(hoverLeft, engaged ? 1 : 0);
                Metrics.FadeTo(hoverRight, engaged ? 1 : 0);
            }
            headerEngaged = engaged;
        }
        hoverRight.Visibility = Show(!slider.IsPeak);
        hoverLeft.Text = slider.IsPeak ? "Uses your limits faster" : "Faster";
        hoverLeft.Foreground = slider.IsPeak ? peak : secondary;
    }

    StackPanel MakeAdvanced()
    {
        var panel = new StackPanel { Padding = new(Metrics.AdvancedInset) };
        advancedModelValue = Label(ModelTitle, Metrics.Label);
        advancedModelAnchor = MenuRow("Model", ModelTitle, "NativeModelChoice", !locked, ModelMenu, valueLabel: advancedModelValue);
        advancedOptions = new StackPanel();
        panel.Children.Add(advancedModelAnchor);
        panel.Children.Add(advancedOptions);
        FillAdvancedOptions(advancedOptions);
        return panel;
    }

    void FillAdvancedOptions(StackPanel panel)
    {
        var model = Model;
        var effort = model?.Efforts.FirstOrDefault(item => item.Id == choice?.Effort);
        panel.Children.Clear();
        panel.Children.Add(editingContext ? ContextEditor(false)
            : MenuRow("Context", ContextLabel(Context), "ContextChoice", model is not null, ContextMenu));
        AddContextFeedback(panel, studio: false);
        panel.Children.Add(MenuRow("Effort", Auto ? Policy.AllowUltra ? "Ultra allowed" : "Ultra disallowed" : Direct ? effort?.Title ?? "Default" : "Auto",
            "EffortPicker", AutoEditable || Direct && model?.Efforts.Length > 0, EffortMenu,
            Direct && model?.Efforts.Length > 1 && effort == model.Efforts.Last() ? peak : null));
        panel.Children.Add(MenuRow("Speed", SpeedTitle(), "SpeedPicker", AutoEditable || Direct && SpeedChoices.Count > 0,
            () => SpeedMenu(advanced: true), UltrafastSelected ? ultrafastColor : FastSelected ? fastColor : null));
        panel.Children.Add(Rule(new(Metrics.RowInset, 6, Metrics.RowInset, 1)));
        var footer = new Grid { Height = Metrics.RowHeight };
        var close = PageButton("Advanced", "\uE70E", () => Navigate(Page.Compact), "CollapseAdvancedModelPicker");
        close.HorizontalAlignment = HorizontalAlignment.Left;
        footer.Children.Add(close);
        var right = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right };
        if (Direct && model is not null && (choice?.Effort != model.DefaultEffort || choice?.Tier != model.DefaultTier || Context.Kind != "Default"))
            right.Children.Add(ButtonFor(Icon("\uE72C", 11, secondary), "Reset to default", () => Run(ResetAsync), Metrics.HeaderHeight, new(6, 0, 6, 0)));
        right.Children.Add(DetailsButton(advanced: true));
        footer.Children.Add(right);
        panel.Children.Add(footer);
        if (NeedsStandardModel)
        {
            var hint = Muted(StandardModelRequired, Metrics.StudioDetail, wrap: true);
            hint.Margin = new(Metrics.RowInset, 1, Metrics.RowInset, 5);
            panel.Children.Add(hint);
        }
    }

    StackPanel MakeStudio()
    {
        var panel = new StackPanel { Padding = new(Metrics.StudioInset) };
        var autoRow = ToggleRow("Auto", Auto, allowed => Run(() => SetAutoAsync(allowed)), "ModelRouting", !locked && !ProtectDaybreak,
            IconLabel("Auto", AutoMark()));
        if (ProtectDaybreak) ToolTipService.SetToolTip(autoRow, "Turn off Daybreak before enabling Auto.");
        panel.Children.Add(autoRow);
        panel.Children.Add(DaybreakRow());
        if (Auto)
        {
            panel.Children.Add(Muted(locked ? "Auto route locked for this chat" : "Auto mode is on", Metrics.StudioDetail));
            panel.Children.Add(StudioRule());
            panel.Children.Add(Section("Auto options"));
            AddPolicyRows(panel);
        }
        else
        {
            panel.Children.Add(StudioRule());
            var heading = new Grid();
            heading.Children.Add(Section("Model"));
            var browse = ButtonFor(Icon("\uE72A", 11, secondary), "Show all models", () => Navigate(Page.Models), Metrics.HeaderHeight, new(6, 0, 6, 0), "NativeModelChoice");
            browse.HorizontalAlignment = HorizontalAlignment.Right;
            heading.Children.Add(browse);
            panel.Children.Add(heading);
            panel.Children.Add(StudioRow(ModelTitle, Model?.Description ?? "", true, () => Navigate(Page.Models)));
        }

        panel.Children.Add(StudioRule());
        panel.Children.Add(Section("Context"));
        foreach (var option in ContextOptions())
            panel.Children.Add(StudioRow(ContextLabel(option), ContextDescription(option), Context == option,
                () => Run(() => SetContextAsync(option)), ContextEnabled(option)));
        panel.Children.Add(editingContext ? ContextEditor(true) : StudioRow("Custom",
            Context.Kind == "Custom" ? ContextLabel(Context) : "Enter a token count inline", Context.Kind == "Custom", BeginContextEdit, CanEditContext));
        AddContextFeedback(panel, studio: true);

        if (Direct && Model is { } model)
        {
            var variants = model.Family("5.6") ? selection.Selectable.Where(option => option.Family("5.6")).ToArray() : [];
            if (variants.Length > 1)
            {
                panel.Children.Add(StudioRule());
                panel.Children.Add(Section("Variant"));
                foreach (var variant in variants)
                    panel.Children.Add(StudioRow(variant.DisplayName, CanChooseModel(variant) ? variant.Description : DaybreakRequired,
                        variant.Id == model.Id, () => Run(() => SetModelAsync(variant)), CanChooseModel(variant)));
            }
            panel.Children.Add(StudioRule());
            panel.Children.Add(Section("Reasoning"));
            foreach (var effort in model.Efforts)
                panel.Children.Add(StudioRow(effort.Title, EffortDescription(effort), effort.Id == choice?.Effort, () => Run(() => SetEffortAsync(effort)), id: "Effort_" + effort.Id));
            if (model.Efforts.Length == 0) panel.Children.Add(Muted("This model has no reasoning options.", 11.5));
            var speeds = SpeedChoices;
            if (speeds.Count > 0)
            {
                panel.Children.Add(StudioRule());
                panel.Children.Add(Section("Speed"));
                foreach (var speed in speeds)
                    panel.Children.Add(StudioRow(speed.Speed.ToString(), speed.Description, SelectedSpeed == speed.Speed,
                        () => Run(() => SetTierAsync(speed.TierId)), id: "Speed_" + speed.Speed, icon: SpeedIcon(speed.Speed)));
            }
            if (model.Specialty is { Length: > 0 } specialty) panel.Children.Add(Muted(specialty, Metrics.StudioDetail));
        }
        else if (choice?.FamilyPlan is { } plan)
        {
            panel.Children.Add(StudioRule());
            panel.Children.Add(Section("Auto lanes"));
            panel.Children.Add(Muted("Parent · " + plan.Parent.Name, Metrics.StudioTitle));
            panel.Children.Add(Muted("Implementation · " + plan.Routine.Name, Metrics.StudioTitle));
            panel.Children.Add(Muted("Review · " + plan.Reviewer.Name, Metrics.StudioTitle));
            foreach (var warning in plan.Warnings) panel.Children.Add(Muted(warning, Metrics.StudioDetail, wrap: true));
        }

        panel.Children.Add(StudioRule());
        panel.Children.Add(DetailsButton());
        return panel;
    }


    ToggleButton DaybreakRow()
    {
        var label = new StackPanel { Spacing = 1 };
        label.Children.Add(IconLabel("Daybreak", DaybreakMark()));
        if (!CanSetDaybreak || choice?.Daybreak is null || NeedsStandardModel)
            label.Children.Add(Muted(DaybreakHelp, Metrics.StudioDetail, wrap: true));
        var row = ToggleRow("Daybreak", DaybreakOn, allowed => Run(() => SetDaybreakAsync(allowed)),
            "DaybreakModelStyle", CanToggleDaybreak, label);
        AutomationProperties.SetHelpText(row, DaybreakHelp);
        return row;
    }

    static StackPanel IconLabel(string title, IconElement icon)
    {
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        label.Children.Add(icon);
        label.Children.Add(Label(title, Metrics.StudioTitle, true));
        return label;
    }

    PathIcon AutoMark() => Metrics.SparklesIcon(secondary);

    PathIcon DaybreakMark() => PickerMark("M1,11 L15,11 15,12 1,12 Z M3.5,11 A4.5,4.5 0 0 1 12.5,11 L11.5,11 A3.5,3.5 0 0 0 4.5,11 Z M7.5,1 L8.5,1 8.5,4 7.5,4 Z M2.5,3.4 L4.7,5.6 4,6.3 1.8,4.1 Z M13.5,3.4 L14.2,4.1 12,6.3 11.3,5.6 Z");

    PathIcon PickerMark(string path)
    {
        var icon = (PathIcon)Microsoft.UI.Xaml.Markup.XamlReader.Load($"""
            <PathIcon xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="14" Height="14" Data="{path}"/>
            """);
        icon.Foreground = secondary;
        return icon;
    }

    StackPanel MakeModelList()
    {
        var panel = new StackPanel { Padding = new(Metrics.StudioInset) };
        panel.Children.Add(PageButton("Models", "\uE76B", () => Navigate(Page.Studio), "BackToModelStudio"));
        var groups = ModelPickerCatalog.Groups(selection.Selectable);
        if (groups.Count == 0) panel.Children.Add(Muted("No selectable models", Metrics.StudioDetail));
        foreach (var group in groups)
        {
            panel.Children.Add(StudioRule());
            if (FamilyAutoRoute(group) is { } route)
                panel.Children.Add(StudioRow(group.Family + " Auto", ProtectDaybreak ? DaybreakRequired : "Veo routes within this model family.",
                    choice?.RoutingMode == route, () => Run(async () => { await SetRouteAsync(route); Navigate(Page.Studio); }), !ProtectDaybreak));
            foreach (var model in group.Models)
            {
                var canChoose = CanChooseModel(model);
                panel.Children.Add(StudioRow(model.DisplayName, canChoose ? model.Description : DaybreakRequired, Direct && choice?.ModelId == model.Id,
                    () => Run(async () => { await SetModelAsync(model); Navigate(Page.Studio); }), canChoose, "Model_" + Uri.EscapeDataString(model.Id)));
            }
        }
        return panel;
    }

    void AddPolicyRows(Panel panel)
    {
        panel.Children.Add(ToggleRow("Speed", Policy.AllowFast, value => ChangePolicy(p => p with { AllowFast = value }), "AutoAllowFast", !locked));
        panel.Children.Add(ToggleRow("Allow Ultra", Policy.AllowUltra, value => ChangePolicy(p => p with { AllowUltra = value }), "AutoAllowUltra", !locked));
    }

    static IEnumerable<ModelContextChoice> ContextOptions() => new[] { new ModelContextChoice() }
        .Concat(ModelContextChoice.Presets.Select(tokens => new ModelContextChoice("Preset", tokens)));

    bool CanEditContext => Direct && Limits is not null;
    string? ContextUnavailable => !Direct ? "Auto uses model defaults." : Limits is null ? "Provider context limit unavailable." : null;

    bool ContextEnabled(ModelContextChoice option) => option.Kind == "Default" ? Model is not null
        : Direct && Limits is { } limits && option.Tokens <= limits.Maximum;

    string ContextDescription(ModelContextChoice option)
    {
        if (option.Kind == "Default")
            return Limits?.Suggested is { } suggested ? "Model default · " + TokenCount(suggested) : "Use the model's runtime default";
        return Limits is { } limits && option.Tokens > limits.Maximum
            ? "Above this model's maximum of " + TokenCount(limits.Maximum) : ContextUnavailable ?? "";
    }

    static string ContextLabel(ModelContextChoice option) => option switch
    {
        { Kind: "Custom", Tokens: long tokens } => TokenCount(tokens),
        { Kind: "Preset", Tokens: 1_000_000 } => "1 million",
        { Kind: "Preset", Tokens: long tokens } => TokenLabel(tokens),
        _ => "Default"
    };

    static string TokenCount(long tokens) => tokens.ToString("N0") + " tokens";
    static string TokenLabel(long tokens) => tokens >= 1_000_000 ? (tokens / 1_000_000m).ToString("0.##") + "M"
        : tokens >= 1000 ? (tokens / 1000m).ToString("0.##") + "K" : tokens.ToString();

    void BeginContextEdit()
    {
        if (!CanEditContext) return;
        editingContext = true;
        contextError = null;
        Refresh();
    }

    void EndContextEdit()
    {
        editingContext = false;
        contextError = null;
    }

    void AddContextFeedback(Panel panel, bool studio)
    {
        contextFeedback = Muted("", studio ? Metrics.StudioDetail : 10, wrap: true);
        contextFeedback.Margin = studio ? new(5, 0, 0, 0) : new(Metrics.RowInset, 3, Metrics.RowInset, 0);
        AutomationProperties.SetLiveSetting(contextFeedback, AutomationLiveSetting.Polite);
        UpdateContextFeedback();
        panel.Children.Add(contextFeedback);
    }

    void UpdateContextFeedback()
    {
        if (contextFeedback is null) return;
        contextFeedback.Text = contextError ?? ContextUnavailable ?? "";
        contextFeedback.Visibility = Show(contextFeedback.Text.Length > 0);
        contextFeedback.Foreground = contextError is not null
            && Application.Current.Resources.TryGetValue("SystemFillColorCriticalBrush", out var brush) && brush is Brush critical
            ? critical : secondary;
    }

    Grid ContextEditor(bool studio)
    {
        var grid = Pair();
        grid.Height = Metrics.RowHeight;
        var inset = studio ? 5 : Metrics.RowInset;
        grid.Margin = new(inset, 0, inset, 0);
        grid.Children.Add(Label(studio ? "Custom" : "Context", Metrics.Label));
        var input = new TextBox
        {
            Text = Context.Kind == "Custom" ? Context.Tokens?.ToString() ?? "" : "", PlaceholderText = "e.g. 1.25M",
            Width = studio ? 124 : 132, Height = Metrics.RowHeight, MinHeight = 0, FontSize = 12, Padding = new(6, 3, 6, 3)
        };
        AutomationProperties.SetName(input, "Custom context window in tokens");
        AutomationProperties.SetAutomationId(input, "CustomContextTokens");
        Grid.SetColumn(input, 1);
        grid.Children.Add(input);
        var modelId = Model?.Id;
        var submitting = false;
        input.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Enter) return;
            e.Handled = true;
            Commit();
        };
        input.LostFocus += (_, _) => DispatcherQueue.TryEnqueue(Commit);
        input.Loaded += (_, _) => DispatcherQueue.TryEnqueue(() =>
        {
            if (!editingContext) return;
            input.Focus(FocusState.Programmatic);
            input.SelectAll();
        });
        return grid;

        void Commit()
        {
            if (!input.IsLoaded || !editingContext || submitting || Model?.Id != modelId) return;
            if (ModelContextChoice.Parse(input.Text) is not { } count)
                contextError = "Enter a positive whole number of tokens, such as 250K or 1.25M.";
            else if (!CanEditContext)
                contextError = "Context is unavailable for this model.";
            else if (Limits is { } limits && count > limits.Maximum)
                contextError = "Maximum for this model: " + TokenCount(limits.Maximum) + ".";
            else
            {
                submitting = true;
                Run(async () =>
                {
                    try
                    {
                        if (editingContext && Model?.Id == modelId) await SetContextAsync(new("Custom", count));
                    }
                    finally { submitting = false; }
                });
                return;
            }
            UpdateContextFeedback();
            input.Focus(FocusState.Programmatic);
        }
    }

    Flyout ModelMenu()
    {
        var title = Muted("Model", 11, true);
        title.Margin = new(25, 0, 0, 0);
        title.Height = 23;
        var auto = ModelMenuSwitch("Auto", "ModelMenuAuto");
        var daybreak = ModelMenuSwitch("Daybreak", "ModelMenuDaybreak");
        var choices = new StackPanel();
        var content = new StackPanel
        {
            Children = { title, ModelSwitchRow("Auto", AutoMark(), auto), ModelSwitchRow("Daybreak", DaybreakMark(), daybreak),
                ModelMenuDivider(), choices }
        };
        var flyout = new Flyout
        {
            FlyoutPresenterStyle = modelOptionsPresenter,
            AreOpenCloseAnimationsEnabled = Metrics.MotionEnabled,
            Content = new ScrollViewer
            {
                MaxHeight = Math.Max(120, (XamlRoot?.Size.Height ?? 620) - 32),
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                Content = content
            }
        };
        openModelOptions = flyout;
        flyout.Closed += (_, _) => { if (ReferenceEquals(openModelOptions, flyout)) openModelOptions = null; };
        var syncing = false;
        UpdateOptions();
        auto.Toggled += (_, _) => ApplyToggle(auto, SetAutoAsync);
        daybreak.Toggled += (_, _) => ApplyToggle(daybreak, SetDaybreakAsync);
        return flyout;

        void ApplyToggle(ToggleSwitch control, Func<bool, Task> applySwitch)
        {
            if (syncing) return;
            var enabled = control.IsOn;
            Run(async () =>
            {
                try { await applySwitch(enabled); }
                finally { if (ReferenceEquals(openModelOptions, flyout)) UpdateOptions(); }
            });
        }

        void UpdateOptions()
        {
            syncing = true;
            auto.IsOn = Auto;
            auto.IsEnabled = !locked && !ProtectDaybreak;
            daybreak.IsOn = DaybreakOn;
            daybreak.IsEnabled = CanToggleDaybreak;
            var daybreakHelp = DaybreakHelp;
            ToolTipService.SetToolTip(daybreak, daybreakHelp);
            AutomationProperties.SetHelpText(daybreak, daybreakHelp);
            AutomationProperties.SetHelpText(auto, ProtectDaybreak ? DaybreakRequired : "");

            choices.Children.Clear();
            if (Auto)
            {
                choices.Children.Add(ModelOption("Auto mode is on", "Chooses once for this thread.", false, false, null));
            }
            else
            {
                var groups = ModelPickerCatalog.Groups(selection.Selectable);
                if (groups.Count == 0) choices.Children.Add(ModelOption("No selectable models", "", false, false, null));
                for (var index = 0; index < groups.Count; index++)
                {
                    var group = groups[index];
                    if (index > 0) choices.Children.Add(ModelMenuDivider());
                    if (FamilyAutoRoute(group) is { } route)
                    {
                        var family = group.Family == "6" ? "GPT-6" : group.Family;
                        choices.Children.Add(ModelOption(group.Family + " Auto",
                            ProtectDaybreak ? DaybreakRequired : $"Veo routes across the {family} family",
                            choice?.RoutingMode == route, !ProtectDaybreak, () => SetRouteAsync(route)));
                    }
                    foreach (var model in group.Models)
                    {
                        var available = CanChooseModel(model);
                        choices.Children.Add(ModelOption(model.DisplayName, available ? "" : DaybreakRequired,
                            Direct && choice?.ModelId == model.Id, available, () => SetModelAsync(model),
                            "ModelMenu_" + Uri.EscapeDataString(model.Id)));
                    }
                }
            }
            syncing = false;
        }

        Button ModelOption(string name, string detail, bool selected, bool enabled, Func<Task>? select, string? id = null)
        {
            var caption = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
            caption.Children.Add(Label(name, 13));
            if (detail.Length > 0) caption.Children.Add(Muted(detail, 11));
            var row = ModelMenuRow(caption, selected ? Icon("\uE73E", 11, primary) : null);
            var button = ButtonFor(row, name, select is null ? null : () => { flyout.Hide(); Run(select); },
                detail.Length > 0 ? 38 : 24, new(4, 0, 9, 0), id);
            button.IsEnabled = enabled;
            if (selected) AutomationProperties.SetItemStatus(button, "Selected");
            if (detail.Length > 0) AutomationProperties.SetHelpText(button, detail);
            return button;
        }
    }

    static ToggleSwitch ModelMenuSwitch(string title, string id)
    {
        var toggle = new ToggleSwitch
        {
            MinWidth = 0, MinHeight = 0, Width = 44, Height = 30, Padding = new(0),
            OffContent = "", OnContent = "", VerticalAlignment = VerticalAlignment.Center
        };
        AutomationProperties.SetName(toggle, title);
        AutomationProperties.SetAutomationId(toggle, id);
        return toggle;
    }

    Grid ModelSwitchRow(string title, IconElement icon, ToggleSwitch toggle)
    {
        icon.Foreground = primary;
        var row = ModelMenuRow(Label(title, 13), icon);
        row.Height = 30;
        row.Margin = new(4, 0, 9, 0);
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        // The native template places its track below the center of its layout slot.
        toggle.Margin = new(0, -6, 0, 0);
        Grid.SetColumn(toggle, 2);
        row.Children.Add(toggle);
        return row;
    }

    static Grid ModelMenuRow(FrameworkElement caption, FrameworkElement? mark)
    {
        var row = new Grid { ColumnSpacing = 5 };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(16) });
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        if (mark is not null)
        {
            mark.IsHitTestVisible = false;
            AutomationProperties.SetAccessibilityView(mark, AccessibilityView.Raw);
            row.Children.Add(mark);
        }
        Grid.SetColumn(caption, 1);
        row.Children.Add(caption);
        return row;
    }

    Border ModelMenuDivider() => Rule(new(26, 5, 12, 5));

    static string? FamilyAutoRoute(ModelPickerGroup group) => group.Family switch
    {
        "6" when group.Models.Any(model => model.Family("6")) => "Family6",
        "5.6" when group.Models.Any(model => model.Family("5.6")) => "Family56",
        _ => null
    };

    MenuFlyout ContextMenu()
    {
        var menu = Dropdown("Context");
        foreach (var option in ContextOptions())
            Option(menu, ContextLabel(option), Context == option, () => Run(() => SetContextAsync(option)),
                ContextDescription(option), ContextEnabled(option), id: "PickerContext_" + option.Kind + option.Tokens);
        Option(menu, "Custom", Context.Kind == "Custom", BeginContextEdit, "Enter a token count inline", CanEditContext,
            id: "PickerContext_Custom");
        return menu;
    }

    MenuFlyout EffortMenu()
    {
        var menu = Dropdown("Effort");
        if (AutoEditable)
        {
            Option(menu, "Disallow Ultra", !Policy.AllowUltra, () => ChangePolicy(p => p with { AllowUltra = false }), "Auto will never select Ultra reasoning.");
            Option(menu, "Allow Ultra", Policy.AllowUltra, () => ChangePolicy(p => p with { AllowUltra = true }), "Auto may select Ultra for the rare tasks that need it.");
        }
        else
            foreach (var effort in Model?.Efforts ?? [])
                Option(menu, effort.Title, effort.Id == choice?.Effort, () => Run(() => SetEffortAsync(effort)), EffortDescription(effort));
        return menu;
    }

    MenuFlyout SpeedMenu(bool advanced = false)
    {
        var menu = Dropdown(advanced ? "Speed" : null);
        if (AutoEditable)
        {
            Option(menu, "Disallow", !Policy.AllowFast, () => ChangePolicy(p => p with { AllowFast = false }),
                "Auto will not choose Fast or Ultrafast routes.");
            Option(menu, "Allow", Policy.AllowFast, () => ChangePolicy(p => p with { AllowFast = true }),
                "Auto may spend more usage for speed when it helps.");
        }
        else
        {
            foreach (var speed in SpeedChoices)
                Option(menu, speed.Speed.ToString(), SelectedSpeed == speed.Speed, () => Run(() => SetTierAsync(speed.TierId)),
                    speed.Description, icon: advanced ? null : SpeedIcon(speed.Speed), reserveIcon: !advanced, id: "PickerSpeed_" + speed.Speed);
        }
        return menu;
    }

    string SpeedTitle() => Auto ? Policy.AllowFast ? "Allow" : "Disallow" : !Direct ? "Auto"
        : SelectedSpeed.ToString();

    FrameworkElement? SpeedIcon(ModelSpeed speed) => speed switch
    {
        ModelSpeed.Fast => Metrics.SpeedBolt(ultrafast: false, fastColor),
        ModelSpeed.Ultrafast => Metrics.SpeedBolt(ultrafast: true, ultrafastColor),
        _ => null
    };

    static string EffortDescription(ModelReasoning effort) => effort.Id.Equals("ultra", StringComparison.OrdinalIgnoreCase)
        ? effort.Description.Length > 0 ? effort.Description : "Maximum reasoning with automatic task delegation." : "";

    MenuFlyout Dropdown(string? header)
    {
        var menu = new MenuFlyout { AreOpenCloseAnimationsEnabled = Metrics.MotionEnabled, MenuFlyoutPresenterStyle = dropdownPresenter };
        if (header is not null)
        {
            var title = Muted(header, 11, true);
            title.Margin = new(3, 0, 0, 0);
            menu.Items.Add(new MenuFlyoutItem { Text = header, Tag = title, Style = dropdownItem, IsEnabled = false });
        }
        return menu;
    }

    void Option(MenuFlyout menu, string title, bool selected, Action action, string detail = "", bool enabled = true,
        FrameworkElement? icon = null, bool reserveIcon = false, string? id = null)
    {
        var row = new Grid { ColumnSpacing = 5 };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(13) });
        row.ColumnDefinitions.Add(new() { Width = icon is not null || reserveIcon ? new GridLength(16) : new GridLength(0) });
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        if (selected)
        {
            var check = Icon("\uE73E", 10, primary);
            check.Height = 16;
            check.VerticalAlignment = VerticalAlignment.Top;
            row.Children.Add(check);
        }
        if (icon is not null)
        {
            var slot = new Grid { Height = 16, VerticalAlignment = VerticalAlignment.Top, Children = { icon } };
            Grid.SetColumn(slot, 1);
            row.Children.Add(slot);
        }
        var caption = new StackPanel { Spacing = 1, MaxWidth = 255, HorizontalAlignment = HorizontalAlignment.Left };
        caption.Children.Add(Label(title, 13));
        if (detail.Length > 0) caption.Children.Add(Muted(detail, 10.5, wrap: true));
        Grid.SetColumn(caption, 2);
        row.Children.Add(caption);
        row.IsHitTestVisible = false;
        AutomationProperties.SetAccessibilityView(row, AccessibilityView.Raw);

        var item = new MenuFlyoutItem { Text = title, Tag = row, Style = dropdownItem, IsEnabled = enabled };
        AutomationProperties.SetName(item, title);
        if (id is not null) AutomationProperties.SetAutomationId(item, id);
        if (selected) AutomationProperties.SetItemStatus(item, "Selected");
        if (detail.Length > 0) AutomationProperties.SetHelpText(item, detail);
        item.Click += (_, _) => action();
        menu.Items.Add(item);
    }

    Button MenuRow(string title, string value, string id, bool enabled, Func<FlyoutBase> makeMenu, Brush? valueBrush = null,
        TextBlock? valueLabel = null)
    {
        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new() { Width = new GridLength(8) });
        var setting = valueLabel ?? Label(value, Metrics.Label);
        setting.Foreground = valueBrush ?? secondary;
        setting.TextAlignment = TextAlignment.Right;
        Grid.SetColumn(setting, 1);
        var arrow = Icon("\uE76C", 8, tertiary);
        Grid.SetColumn(arrow, 2);
        row.Children.Add(Label(title, Metrics.Label));
        row.Children.Add(setting);
        row.Children.Add(arrow);
        var button = ButtonFor(row, title, null, Metrics.RowHeight, new(Metrics.RowInset, 0, Metrics.RowInset, 0), id);
        button.IsEnabled = enabled;
        AutomationProperties.SetItemStatus(button, value);
        button.Click += (_, _) => makeMenu().ShowAt(button, new FlyoutShowOptions { Placement = FlyoutPlacementMode.RightEdgeAlignedTop });
        return button;
    }

    Button StudioRow(string title, string detail, bool selected, Action action, bool enabled = true, string? id = null, FrameworkElement? icon = null)
    {
        var row = new Grid { ColumnSpacing = 7 };
        row.ColumnDefinitions.Add(new() { Width = new GridLength(14) });
        row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        var mark = Icon(selected ? "\uE73E" : "\uEA3A", 12, selected ? selectedBrush : secondary);
        mark.Height = 16;
        mark.VerticalAlignment = VerticalAlignment.Top;
        row.Children.Add(mark);
        var text = new StackPanel { Spacing = 2 };
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
        if (icon is not null) heading.Children.Add(icon);
        heading.Children.Add(Label(title, Metrics.StudioTitle, true));
        text.Children.Add(heading);
        if (detail.Length > 0) text.Children.Add(Muted(detail, Metrics.StudioDetail));
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        var padding = detail.Length > 0 ? 3 : 4;
        var button = ButtonFor(row, title, action, double.NaN, new(5, padding, 5, padding), id);
        button.IsEnabled = enabled;
        if (!enabled) button.Opacity = .48;
        AutomationProperties.SetItemStatus(button, selected ? "Selected" : "Not selected");
        AutomationProperties.SetHelpText(button, detail);
        return button;
    }

    Button DetailsButton(bool advanced = false)
    {
        var title = advanced ? "Model details and personality" : "Model details and settings";
        var mark = new Grid { Width = 14, Height = 16, Children = { Metrics.InfoMark(secondary) } };
        var button = ButtonFor(mark, title, null, Metrics.HeaderHeight, new(6, 0, 6, 0), "ModelPickerDetails");
        button.Width = Metrics.HeaderHeight;
        button.HorizontalAlignment = HorizontalAlignment.Left;
        ToolTipService.SetToolTip(button, title);
        button.Click += (_, _) =>
        {
            if (advanced) ShowAdvancedDetails(button);
            else ShowStudioSettings(button);
        };
        return button;
    }

    void ShowStudioSettings(Button anchor)
    {
        var content = new StackPanel { Width = 274, Spacing = 6 };
        if (Model is { } model)
        {
            content.Children.Add(Label(model.DisplayName, 14, true));
            if (model.Description.Length > 0) content.Children.Add(Muted(model.Description, 12, wrap: true));
            if (Limits is { } limits) content.Children.Add(Muted("Maximum context · " + TokenLabel(limits.Maximum), 11.5));
            content.Children.Add(DetailsSpeedAvailability(model, App.Accounts.State.Identity));
        }
        var defaultScope = new ComboBox { Header = "Save defaults for", ItemsSource = new[] { "Global", "Project" }, SelectedItem = scope, HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetAutomationId(defaultScope, "ModelDefaultScope");
        defaultScope.SelectionChanged += (_, _) =>
        {
            scope = defaultScope.SelectedItem as string ?? "Global";
            if (choice is { } currentChoice) Run(() => ApplyChoiceAsync(currentChoice));
        };
        content.Children.Add(defaultScope);
        content.Children.Add(ButtonFor(Label("Clear project override", 12), "Clear project override", () => Run(async () =>
        {
            if (locked) return;
            await selection.ResetProjectAsync(session);
            choice = await selection.ResolveAsync(session);
            apply(choice);
            Refresh();
        }), Metrics.RowHeight, new(6, 0, 6, 0), "ResetProjectModelDefaults"));

        var policy = new StackPanel { Spacing = 6 };
        var provider = new ComboBox { Header = "Router", ItemsSource = new[] { "Utility", "Jev" }, SelectedItem = Policy.Provider, HorizontalAlignment = HorizontalAlignment.Stretch };
        provider.SelectionChanged += (_, _) => ChangePolicy(p => p with { Provider = provider.SelectedItem as string ?? "Utility" });
        policy.Children.Add(provider);
        var utilities = ModelPickerCatalog.Groups(selection.Selectable).SelectMany(group => group.Models)
            .Where(model => model.Efforts.Any(effort => effort.Id.Equals("low", StringComparison.OrdinalIgnoreCase))).ToArray();
        var utility = new ComboBox { Header = "Utility model", ItemsSource = utilities, SelectedItem = utilities.FirstOrDefault(model => model.Id == Policy.UtilityModelId), DisplayMemberPath = nameof(NativeModelDescriptor.DisplayName), HorizontalAlignment = HorizontalAlignment.Stretch };
        utility.SelectionChanged += (_, _) => ChangePolicy(p => p with { UtilityModelId = (utility.SelectedItem as NativeModelDescriptor)?.Id });
        policy.Children.Add(utility);
        AddPolicyRows(policy);
        policy.Children.Add(ToggleRow("Describe images for text-only models", Policy.VisionOptedIn, value => ChangePolicy(p => p with { VisionOptedIn = value })));
        policy.Children.Add(Muted("Auto sends up to 24,000 text elements of the first prompt to the selected router.", 11, wrap: true));
        content.Children.Add(Options("Auto routing", policy));
        var enabled = new StackPanel();
        foreach (var group in ModelPickerCatalog.Groups(selection.Catalog))
        {
            enabled.Children.Add(Section(group.Title));
            foreach (var candidate in group.Models)
            {
                var check = new CheckBox
                {
                    Content = candidate.DisplayName,
                    IsChecked = selection.Selectable.Any(model => model.Id == candidate.Id),
                    IsEnabled = !candidate.IsGPT56 || selection.IncludeGPT56Models
                };
                AutomationProperties.SetAutomationId(check, "EnabledModel_" + Uri.EscapeDataString(candidate.Id));
                check.Click += (_, _) => Run(async () =>
                {
                    try { await selection.SetEnabledAsync(candidate.Id, check.IsChecked == true); }
                    catch { check.IsChecked = check.IsChecked != true; throw; }
                    Refresh();
                });
                enabled.Children.Add(check);
            }
        }
        content.Children.Add(Options("Enabled models", enabled));
        new Flyout { Content = new ScrollViewer { MaxHeight = 430, Content = content }, AreOpenCloseAnimationsEnabled = Metrics.MotionEnabled }
            .ShowAt(anchor, new FlyoutShowOptions { Placement = FlyoutPlacementMode.RightEdgeAlignedTop });
    }

    static Expander Options(string title, UIElement content) => new()
    { Header = title, Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };

    async Task SetModelAsync(NativeModelDescriptor model)
    {
        if (locked || !CanChooseModel(model)) return;
        EndContextEdit();
        var context = selection.ContextChoice(model.Id);
        bool? program = choice?.Daybreak;
        if (program == true && (!model.SupportsDaybreakBlue || !selection.SupportsDaybreakBlue)) program = null;
        if (program == false && !model.SupportsDaybreakBlue && (!model.SupportsStandardCyberAccess || !selection.SupportsStandardCyberAccess)) program = null;
        await ApplyChoiceAsync(new(model.Id, model.Model, model.DefaultEffort, model.DefaultTier,
            context.Kind == "Default" ? selection.Limits(model.Id)?.Suggested : context.Tokens)
            { Daybreak = program });
    }

    Task SetRouteAsync(string route) => choice is { } item && !locked && !ProtectDaybreak
        ? ApplyChoiceAsync(item with { RoutingMode = route, Daybreak = null }) : Task.CompletedTask;

    async Task SetAutoAsync(bool enabled)
    {
        if (choice is null || locked || ProtectDaybreak) return;
        var policy = Policy with { OptedIn = enabled };
        await selection.SetRouterPolicyAsync(policy);
        await ApplyChoiceAsync(choice with { RouterPolicy = policy, RoutingMode = enabled ? "FirstPrompt" : "Direct", Daybreak = null });
    }

    void ChangePolicy(Func<AutoRouterPolicy, AutoRouterPolicy> change) => Run(async () =>
    {
        var policy = change(Policy);
        await selection.SetRouterPolicyAsync(policy);
        if (choice is not null && !locked) await ApplyChoiceAsync(choice with { RouterPolicy = policy });
    });

    Task SetEffortAsync(ModelReasoning effort) => choice is not null && Direct
        ? ApplyChoiceAsync(choice with { Effort = effort.Id }) : Task.CompletedTask;
    Task SetTierAsync(string? tier) => choice is not null && Direct
        ? ApplyChoiceAsync(choice with { Tier = tier }) : Task.CompletedTask;
    Task SetDaybreakAsync(bool enabled)
    {
        if (choice is null || locked || (enabled ? !CanSetDaybreak : !CanToggleDaybreak)) return Task.CompletedTask;
        daybreakRevision++;
        // On a Blue-only model, persist Off so dispatch cannot fall back to an inherited Blue default.
        return ApplyChoiceAsync(choice with { Daybreak = CanSetDaybreak || CanSetStandard ? enabled : null });
    }

    void OpenCompactSpeed()
    {
        if (!Direct || Model is not { IsSpark: false } model || bolt is null) return;
        if (Ultrafast is not null)
            SpeedMenu().ShowAt(bolt, new FlyoutShowOptions { Placement = FlyoutPlacementMode.RightEdgeAlignedTop });
        else if (Fast is { } fast)
            Run(() => SetTierAsync(FastSelected ? model.StandardTier?.Id : fast.Id));
    }

    async Task SetContextAsync(ModelContextChoice option)
    {
        if (Model is not { } model || choice is null || (!Direct && option.Kind != "Default")) return;
        await selection.SetContextAsync(model.Id, option);
        EndContextEdit();
        if (Direct)
            await ApplyChoiceAsync(choice with { ContextTokens = option.Kind == "Default" ? Limits?.Suggested : option.Tokens });
        else
            Refresh();
    }

    async Task ResetAsync()
    {
        if (!Direct || Model is not { } model || choice is null) return;
        await selection.SetContextAsync(model.Id, new());
        await ApplyChoiceAsync(choice with { Effort = model.DefaultEffort, Tier = model.DefaultTier, ContextTokens = Limits?.Suggested });
    }

    async Task ApplyChoiceAsync(ModelSelectionChoice next)
    {
        if (locked) return;
        if (next.RoutingMode is "Family56" or "Family6")
        {
            var plan = FamilyAutoRouting.Resolve(selection.Visible, next.RoutingMode == "Family56" ? "5.6" : "6", selection.MultiAgentEnabled);
            next = next with { ModelId = plan.Parent.ModelId, Model = plan.Parent.Model, Effort = plan.Parent.Effort,
                Tier = null, ContextTokens = selection.Limits(plan.Parent.ModelId)?.Suggested, FamilyPlan = plan, Daybreak = null };
        }
        else next = next with { FamilyPlan = null };
        next = selection.Validate(next with { RouterPolicy = next.RouterPolicy ?? selection.RouterPolicy }, next.RoutingMode != "Direct");
        await selection.SaveSelectionAsync(session, next, scope);
        choice = next;
        apply(next);
        Refresh();
    }

    async void Run(Func<Task> action)
    {
        await edits.WaitAsync();
        try { await action(); error.IsOpen = false; }
        catch (Exception exception)
        {
            error.Message = DiagnosticRedactor.Redact(exception.Message);
            error.IsOpen = true;
        }
        finally { edits.Release(); }
    }

    void UpdateTheme()
    {
        var ui = new UISettings();
        var contrast = new AccessibilitySettings().HighContrast;
        var dark = ActualTheme == ElementTheme.Dark;
        var foreground = contrast ? ui.GetColorValue(UIColorType.Foreground) : dark ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black;
        primary.Color = foreground;
        secondary.Color = Alpha(foreground, contrast ? (byte)255 : (byte)154);
        tertiary.Color = Alpha(foreground, contrast ? (byte)255 : (byte)96);
        divider.Color = Alpha(foreground, contrast ? (byte)255 : (byte)28);
        faintTrack.Color = Alpha(foreground, contrast ? (byte)0 : (byte)23);
        peak.Color = contrast ? foreground : Metrics.PeakText(dark, BluePalette);
        ultrafastColor.Color = contrast ? foreground : Metrics.PeakText(dark, blue: false);
        fastColor.Color = contrast ? foreground : Metrics.FastText(dark);
        fallbackSurface.Color = contrast ? ui.UIElementColor(UIElementType.Background) : dark
            ? Color.FromArgb(255, 48, 47, 49) : Color.FromArgb(255, 245, 244, 246);
        popoverSurface.TintColor = popoverSurface.FallbackColor = fallbackSurface.Color;
        pickerCard.Background = pickerPointer.Fill = contrast ? fallbackSurface : popoverSurface;
        var accent = App.Workspace.Preferences.Accent;
        selectedBrush.Color = contrast ? ui.UIElementColor(UIElementType.Highlight)
            : accent is { Length: 7 } && accent[0] == '#' && uint.TryParse(accent[1..], System.Globalization.NumberStyles.HexNumber, null, out var hex)
                ? Color.FromArgb(255, (byte)(hex >> 16), (byte)(hex >> 8), (byte)hex)
                : ui.GetColorValue(UIColorType.Accent);
    }

    static Color Alpha(Color color, byte alpha) => Color.FromArgb(alpha, color.R, color.G, color.B);
    static Visibility Show(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    static Grid Pair()
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        return grid;
    }

    ToggleButton ToggleRow(string title, bool isOn, Action<bool> change, string? id = null, bool enabled = true, FrameworkElement? label = null)
    {
        var row = Pair();
        row.Margin = new Thickness(5, 0, 5, 0);
        label ??= Label(title, Metrics.StudioTitle, true);
        label.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(label);
        var track = SwitchTrack(isOn);
        Grid.SetColumn(track, 1);
        row.Children.Add(track);
        var toggle = new ToggleButton
        {
            Content = row, IsChecked = isOn, IsEnabled = enabled, MinHeight = 28,
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Template = toggleTemplate ??= (ControlTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load(SwitchRowTemplate),
            UseSystemFocusVisuals = true, FocusVisualPrimaryBrush = secondary, FocusVisualSecondaryBrush = tertiary,
            FocusVisualPrimaryThickness = new(1), FocusVisualSecondaryThickness = new(0)
        };
        AutomationProperties.SetName(toggle, title);
        if (id is not null) AutomationProperties.SetAutomationId(toggle, id);
        toggle.Checked += (_, _) => Commit(true);
        toggle.Unchecked += (_, _) => Commit(false);
        return toggle;

        void Commit(bool value)
        {
            UpdateSwitch(track, value);
            if (toggle.IsLoaded) change(value);
        }
    }

    Border SwitchTrack(bool isOn)
    {
        var thumb = new Border { Width = 12, Height = 12, CornerRadius = new(6), Margin = new(2, 0, 2, 0), VerticalAlignment = VerticalAlignment.Center };
        var track = new Border
        {
            Child = thumb, Width = 31, Height = 17, CornerRadius = new(8.5), BorderThickness = new(1),
            VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false
        };
        UpdateSwitch(track, isOn);
        return track;
    }

    void UpdateSwitch(Border track, bool value)
    {
        var thumb = (Border)track.Child;
        var highlightText = new AccessibilitySettings().HighContrast
            ? new UISettings().UIElementColor(UIElementType.HighlightText) : Microsoft.UI.Colors.White;
        track.Background = value ? selectedBrush : faintTrack;
        track.BorderBrush = value ? selectedBrush : tertiary;
        thumb.Background = value ? new SolidColorBrush(highlightText) : secondary;
        thumb.HorizontalAlignment = value ? HorizontalAlignment.Right : HorizontalAlignment.Left;
    }

    const string SwitchRowTemplate = """
        <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                         xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="ToggleButton">
            <Grid x:Name="Chrome" Background="{ThemeResource SubtleFillColorTransparentBrush}" CornerRadius="6">
                <VisualStateManager.VisualStateGroups>
                    <VisualStateGroup x:Name="CommonStates">
                        <VisualState x:Name="Normal"/>
                        <VisualState x:Name="Checked"/>
                        <VisualState x:Name="PointerOver"><VisualState.Setters><Setter Target="Chrome.Background" Value="{ThemeResource SubtleFillColorSecondaryBrush}"/></VisualState.Setters></VisualState>
                        <VisualState x:Name="CheckedPointerOver"><VisualState.Setters><Setter Target="Chrome.Background" Value="{ThemeResource SubtleFillColorSecondaryBrush}"/></VisualState.Setters></VisualState>
                        <VisualState x:Name="Pressed"><VisualState.Setters><Setter Target="Chrome.Background" Value="{ThemeResource SubtleFillColorTertiaryBrush}"/></VisualState.Setters></VisualState>
                        <VisualState x:Name="CheckedPressed"><VisualState.Setters><Setter Target="Chrome.Background" Value="{ThemeResource SubtleFillColorTertiaryBrush}"/></VisualState.Setters></VisualState>
                        <VisualState x:Name="Disabled"><VisualState.Setters><Setter Target="Chrome.Opacity" Value="0.52"/></VisualState.Setters></VisualState>
                        <VisualState x:Name="CheckedDisabled"><VisualState.Setters><Setter Target="Chrome.Opacity" Value="0.52"/></VisualState.Setters></VisualState>
                    </VisualStateGroup>
                </VisualStateManager.VisualStateGroups>
                <ContentPresenter Content="{TemplateBinding Content}" HorizontalContentAlignment="Stretch" VerticalContentAlignment="Center"/>
            </Grid>
        </ControlTemplate>
        """;

    Button PageButton(string text, string glyph, Action action, string id)
    {
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        label.Children.Add(Muted(text, Metrics.Label));
        label.Children.Add(Icon(glyph, 9, secondary));
        return ButtonFor(label, text, action, Metrics.HeaderHeight, new(6, 0, 6, 0), id);
    }

    Button ButtonFor(object label, string name, Action? action, double height, Thickness padding, string? id = null)
    {
        var button = new Button
        {
            Content = label, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Height = height, MinWidth = 0, MinHeight = 0, Padding = padding, CornerRadius = new(6),
            FocusVisualPrimaryBrush = secondary, FocusVisualSecondaryBrush = tertiary,
            FocusVisualPrimaryThickness = new(1), FocusVisualSecondaryThickness = new(0)
        };
        if (Application.Current.Resources.TryGetValue("SubtleButtonStyle", out var style) && style is Style quiet) button.Style = quiet;
        AutomationProperties.SetName(button, name);
        if (id is not null) AutomationProperties.SetAutomationId(button, id);
        if (action is not null) button.Click += (_, _) => action();
        return button;
    }

    TextBlock Section(string title)
    {
        var label = Muted(title.ToUpperInvariant(), 10, true);
        label.Margin = new(0, 0, 0, 2);
        AutomationProperties.SetHeadingLevel(label, AutomationHeadingLevel.Level1);
        return label;
    }

    Border StudioRule() => Rule(new(0, 8, 0, 8));
    Border Rule(Thickness margin) => new() { Height = 1, Margin = margin, Background = divider };
    TextBlock Muted(string text, double size, bool medium = false, bool wrap = false)
    {
        var label = Label(text, size, medium);
        label.Foreground = secondary;
        if (wrap) label.TextWrapping = TextWrapping.Wrap;
        return label;
    }

    static TextBlock Label(string text, double size, bool medium = false) => new()
    {
        Text = text, FontSize = size, FontWeight = medium ? Microsoft.UI.Text.FontWeights.Medium : Microsoft.UI.Text.FontWeights.Normal,
        TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center
    };

    static FontIcon Icon(string glyph, double size, Brush brush) => new()
    { Glyph = glyph, FontSize = size, Foreground = brush, VerticalAlignment = VerticalAlignment.Center };

}
