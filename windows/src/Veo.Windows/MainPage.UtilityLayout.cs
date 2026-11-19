using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Windows.System;

namespace Veo_Windows;

public sealed partial class MainPage
{
    const double UtilityMinimumWidth = 280;
    const double UtilityMaximumWidth = 800;
    const double UtilityMinimumWindowWidth = 1150;
    const double UtilityMinimumConversationWidth = 560;
    const double UtilityDividerWidth = 7;
    const double SidebarMinimumWidth = 236;
    const double SidebarIdealWidth = 318;
    const double SidebarReferenceFraction = 467.0 / 2160;
    bool utilityLayoutReady;
    bool restoringUtilityTab;
    UtilityResizeSash? utilityResizeSash;

    void InitializeUtilityLayout()
    {
        utilityResizeSash = new UtilityResizeSash(
            () => UtilityWidth.Width.Value,
            () => UtilityMinimumWidth,
            MaximumUtilityWidth,
            width =>
            {
                if (!utilityLayoutReady) return;
                workspace.Preferences.UtilityWidth = width;
                ApplyUtilityLayout();
            },
            () => _ = Run(PersistUtilityLayoutAsync));
        UtilitySashHost.Content = utilityResizeSash;
        utilityResizeSash.IsEnabled = false;
    }

    void RestoreUtilityLayout()
    {
        var preferences = workspace.Preferences;
        preferences.UtilityWidth = double.IsFinite(preferences.UtilityWidth)
            ? Math.Clamp(preferences.UtilityWidth, UtilityMinimumWidth, UtilityMaximumWidth) : 360;
        restoringUtilityTab = true;
        try
        {
            UtilityTabs.SelectedIndex = preferences.UtilityTab switch { "Browser" => 1, "Files" => 2, _ => 0 };
        }
        finally { restoringUtilityTab = false; }
        utilityLayoutReady = true;
        ApplyUtilityLayout();
    }

    double UtilityWindowWidth() => ActualWidth > 0 ? ActualWidth : workspace.Preferences.WindowWidth;

    double PreferredSidebarWidth() => Math.Clamp(UtilityWindowWidth() * SidebarReferenceFraction, SidebarMinimumWidth, SidebarIdealWidth);

    void ApplyWorkspaceWidth()
    {
        var width = sidebarVisible ? PreferredSidebarWidth() : 0;
        SidebarWidth.Width = new GridLength(width);
        settingsPanel?.SetWorkspaceWidth(UtilityWindowWidth(), PreferredSidebarWidth());
        SidebarLayoutChanged?.Invoke(width, sidebarVisible);
        ApplyUtilityLayout();
    }

    double MaximumUtilityWidth() => Math.Max(UtilityMinimumWidth,
        Math.Min(UtilityMaximumWidth, UtilityWindowWidth() - SidebarWidth.Width.Value - UtilityDividerWidth - UtilityMinimumConversationWidth));

    void ApplyUtilityLayout()
    {
        if (!utilityLayoutReady) return;
        // A narrow window may temporarily hide the panel without overwriting the user's choice.
        var visible = workspace.Preferences.UtilityVisible && UtilityWindowWidth() >= UtilityMinimumWindowWidth;
        UtilityWidth.Width = new GridLength(visible
            ? Math.Clamp(workspace.Preferences.UtilityWidth, UtilityMinimumWidth, MaximumUtilityWidth()) : 0);
        UtilitySashWidth.Width = new GridLength(visible ? UtilityDividerWidth : 0);
        UtilityPanel.Visibility = UtilitySashHost.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (utilityResizeSash is not null) utilityResizeSash.IsEnabled = visible;
    }

    async Task PersistUtilityLayoutAsync()
    {
        if (utilityLayoutReady) await workspace.SavePreferencesAsync();
    }

    async Task OpenUtilityPanelAsync(int? selectedTab = null)
    {
        workspace.Preferences.UtilityVisible = true;
        if (selectedTab is { } index)
        {
            index = Math.Clamp(index, 0, 2);
            restoringUtilityTab = true;
            try { UtilityTabs.SelectedIndex = index; }
            finally { restoringUtilityTab = false; }
            workspace.Preferences.UtilityTab = UtilityTabName(index);
        }
        ApplyUtilityLayout();
        await PersistUtilityLayoutAsync();
        await ShowUtilityAsync();
    }

    async Task ToggleUtilityPanelAsync()
    {
        workspace.Preferences.UtilityVisible = !workspace.Preferences.UtilityVisible;
        ApplyUtilityLayout();
        await PersistUtilityLayoutAsync();
        if (workspace.Preferences.UtilityVisible) await ShowUtilityAsync();
    }

    static string UtilityTabName(int index) => index switch { 1 => "Browser", 2 => "Files", _ => "Review" };

    async void Utility_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!utilityLayoutReady || restoringUtilityTab) return;
        await Run(async () =>
        {
            workspace.Preferences.UtilityTab = UtilityTabName(UtilityTabs.SelectedIndex);
            await PersistUtilityLayoutAsync();
            await ShowUtilityAsync();
        });
    }
}

/// <summary>A visible native separator with captured pointer input and a UI Automation width range.</summary>
internal sealed class UtilityResizeSash : Control
{
    readonly Func<double> value;
    readonly Func<double> minimum;
    readonly Func<double> maximum;
    readonly Action<double> change;
    readonly Action commit;
    uint? pointer;
    double startX;
    double startWidth;

    internal UtilityResizeSash(Func<double> value, Func<double> minimum, Func<double> maximum, Action<double> change, Action commit)
    {
        this.value = value;
        this.minimum = minimum;
        this.maximum = maximum;
        this.change = change;
        this.commit = commit;
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        AutomationProperties.SetName(this, "Resize right panel");
        AutomationProperties.SetAutomationId(this, "UtilityResizeSash");
        AutomationProperties.SetHelpText(this, "Drag left or right. Arrow keys resize by 10 pixels; Page Up and Page Down by 50. Home and End choose the minimum and maximum width.");
        Template = (ControlTemplate)XamlReader.Load("""
            <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Control">
              <Grid Background="{ThemeResource SubtleFillColorSecondaryBrush}">
                <Border Width="1" HorizontalAlignment="Center" Background="{ThemeResource DividerStrokeColorDefaultBrush}" IsHitTestVisible="False"/>
                <Border x:Name="FocusOutline" BorderBrush="{ThemeResource TextFillColorPrimaryBrush}" BorderThickness="0" IsHitTestVisible="False"/>
              </Grid>
            </ControlTemplate>
            """);
        GotFocus += (_, _) => RefreshFocus();
        LostFocus += (_, _) => RefreshFocus();
    }

    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        RefreshFocus();
    }

    void RefreshFocus()
    {
        if (GetTemplateChild("FocusOutline") is Border outline)
            outline.BorderThickness = new Thickness(FocusState == FocusState.Keyboard ? 1 : 0);
    }

    protected override void OnPointerPressed(PointerRoutedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (!IsEnabled || pointer is not null || !e.GetCurrentPoint(null).Properties.IsLeftButtonPressed) return;
        Focus(FocusState.Pointer);
        if (!CapturePointer(e.Pointer)) return;
        pointer = e.Pointer.PointerId;
        startX = e.GetCurrentPoint(null).Position.X;
        startWidth = CurrentWidth;
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerRoutedEventArgs e)
    {
        base.OnPointerMoved(e);
        if (pointer != e.Pointer.PointerId) return;
        SetWidth(startWidth - (e.GetCurrentPoint(null).Position.X - startX), false);
        e.Handled = true;
    }

    protected override void OnPointerReleased(PointerRoutedEventArgs e)
    {
        base.OnPointerReleased(e);
        if (pointer != e.Pointer.PointerId) return;
        FinishPointer();
        e.Handled = true;
    }

    protected override void OnPointerCaptureLost(PointerRoutedEventArgs e)
    {
        base.OnPointerCaptureLost(e);
        FinishPointer();
    }

    protected override void OnPointerCanceled(PointerRoutedEventArgs e)
    {
        base.OnPointerCanceled(e);
        FinishPointer();
    }

    void FinishPointer()
    {
        if (pointer is null) return;
        pointer = null;
        ReleasePointerCaptures();
        commit();
    }

    protected override void OnKeyDown(KeyRoutedEventArgs e)
    {
        base.OnKeyDown(e);
        var next = e.Key switch
        {
            VirtualKey.Left => CurrentWidth + 10,
            VirtualKey.Right => CurrentWidth - 10,
            VirtualKey.PageUp => CurrentWidth + 50,
            VirtualKey.PageDown => CurrentWidth - 50,
            VirtualKey.Home => minimum(),
            VirtualKey.End => maximum(),
            _ => double.NaN
        };
        if (double.IsNaN(next)) return;
        SetWidth(next, true);
        e.Handled = true;
    }

    internal double CurrentWidth => Math.Clamp(value(), minimum(), maximum());

    internal void SetWidth(double width, bool persist)
    {
        if (!double.IsFinite(width)) throw new ArgumentOutOfRangeException(nameof(width));
        var previous = CurrentWidth;
        var next = Math.Clamp(Math.Round(width), minimum(), maximum());
        change(next);
        if (FrameworkElementAutomationPeer.FromElement(this) is UtilitySashPeer peer) peer.Notify(previous, next);
        if (persist) commit();
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new UtilitySashPeer(this);

    sealed class UtilitySashPeer(UtilityResizeSash owner) : FrameworkElementAutomationPeer(owner), IRangeValueProvider
    {
        protected override string GetClassNameCore() => "UtilityPanelDivider";
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Thumb;
        protected override object GetPatternCore(PatternInterface patternInterface) => patternInterface == PatternInterface.RangeValue ? this : base.GetPatternCore(patternInterface);
        public bool IsReadOnly => !owner.IsEnabled;
        public double LargeChange => 50;
        public double SmallChange => 10;
        public double Minimum => owner.minimum();
        public double Maximum => owner.maximum();
        public double Value => owner.CurrentWidth;
        public void SetValue(double value)
        {
            if (!double.IsFinite(value) || value < Minimum || value > Maximum) throw new ArgumentOutOfRangeException(nameof(value));
            if (IsReadOnly) throw new InvalidOperationException("The right panel divider is unavailable while the panel is hidden.");
            if (owner.DispatcherQueue.HasThreadAccess) owner.SetWidth(value, true);
            else if (!owner.DispatcherQueue.TryEnqueue(() => owner.SetWidth(value, true))) throw new InvalidOperationException("The window is closing.");
        }
        internal void Notify(double previous, double next) => RaisePropertyChangedEvent(RangeValuePatternIdentifiers.ValueProperty, previous, next);
    }
}
