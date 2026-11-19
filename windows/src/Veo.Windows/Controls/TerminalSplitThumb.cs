using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Markup;
using Veo.Core;
using Windows.System;

namespace Veo_Windows.Controls;

/// <summary>Native pointer drag, keyboard adjustment and UI Automation range semantics for a pane divider.</summary>
internal sealed class TerminalSplitThumb : Control
{
    private readonly Func<double> value;
    private readonly Action<double> changed;
    private readonly Func<double> extent;
    private readonly TerminalSplitAxis axis;
    public double Ratio => value();
    public TerminalSplitThumb(TerminalSplitAxis axis, Func<double> value, Action<double> changed, Func<double> extent)
    {
        this.axis = axis; this.value = value; this.changed = changed; this.extent = extent;
        IsTabStop = true; UseSystemFocusVisuals = false;
        Template = (ControlTemplate)XamlReader.Load("""
            <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Control">
              <Grid>
                <Thumb x:Name="PaneThumb" IsTabStop="False"><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="{ThemeResource ControlStrongFillColorDefaultBrush}" Opacity="0.5"/></ControlTemplate></Thumb.Template></Thumb>
                <Border x:Name="FocusOutline" BorderBrush="{ThemeResource TextFillColorPrimaryBrush}" BorderThickness="0" IsHitTestVisible="False"/>
              </Grid>
            </ControlTemplate>
            """);
        AutomationProperties.SetName(this, axis == TerminalSplitAxis.Horizontal ? "Resize terminal panes horizontally" : "Resize terminal panes vertically");
        AutomationProperties.SetHelpText(this, "Drag the divider or use arrow keys. Home centers the split.");
        GotFocus += (_, _) => UpdateFocus(); LostFocus += (_, _) => UpdateFocus();
        KeyDown += (_, args) =>
        {
            if (args.Key == VirtualKey.Home) { SetRatio(0.5); args.Handled = true; }
            else if (args.Key is VirtualKey.Left or VirtualKey.Up) { SetRatio(Ratio - 0.05); args.Handled = true; }
            else if (args.Key is VirtualKey.Right or VirtualKey.Down) { SetRatio(Ratio + 0.05); args.Handled = true; }
        };
    }
    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        if (GetTemplateChild("PaneThumb") is Thumb thumb)
        {
            thumb.DragDelta += (_, args) => SetRatio(Ratio + (axis == TerminalSplitAxis.Horizontal ? args.HorizontalChange : args.VerticalChange) / Math.Max(1, extent()));
            thumb.PointerPressed += (_, _) => Focus(FocusState.Pointer);
        }
        UpdateFocus();
    }
    private void UpdateFocus()
    {
        if (GetTemplateChild("FocusOutline") is Border outline)
            outline.BorderThickness = new Thickness(FocusState == FocusState.Keyboard || FocusState != FocusState.Unfocused && new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast ? 1 : 0);
    }
    public void SetRatio(double next)
    {
        if (!double.IsFinite(next)) throw new ArgumentOutOfRangeException(nameof(next));
        var old = Ratio; next = Math.Clamp(next, 0.2, 0.8); changed(next);
        if (FrameworkElementAutomationPeer.FromElement(this) is TerminalSplitPeer peer) peer.Notify(old, next);
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new TerminalSplitPeer(this);
    private sealed class TerminalSplitPeer(TerminalSplitThumb owner) : FrameworkElementAutomationPeer(owner), IRangeValueProvider
    {
        protected override string GetClassNameCore() => "TerminalPaneDivider";
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Thumb;
        protected override object GetPatternCore(PatternInterface patternInterface) => patternInterface == PatternInterface.RangeValue ? this : base.GetPatternCore(patternInterface);
        public bool IsReadOnly => false;
        public double LargeChange => 0.1;
        public double SmallChange => 0.05;
        public double Maximum => 0.8;
        public double Minimum => 0.2;
        public double Value => owner.Ratio;
        public void SetValue(double value)
        {
            if (!double.IsFinite(value) || value < Minimum || value > Maximum) throw new ArgumentOutOfRangeException(nameof(value));
            if (owner.DispatcherQueue.HasThreadAccess) owner.SetRatio(value); else owner.DispatcherQueue.TryEnqueue(() => owner.SetRatio(value));
        }
        public void Notify(double before, double after) => RaisePropertyChangedEvent(RangeValuePatternIdentifiers.ValueProperty, before, after);
    }
}
