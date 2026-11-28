using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;
using Veo.Core;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace Veo_Windows.Controls;

public sealed partial class WorkspaceTour : UserControl
{
    static readonly (string Heading, string Detail, string Action)[] Pages =
    [
        ("Welcome to Veo.", "A local workspace for Codex, from the first question to the final diff.", "Take the tour"),
        ("A home for every project.", "Open a folder and Veo keeps its chats together. Return to a conversation and its working directory comes with it.", "Continue"),
        ("Make yourself at home.", "Choose how your workspace looks. You can change it anytime in Appearance.", "Continue"),
        ("Choose your provider.", "Use Codex or connect another coding agent. Switch providers beside the model picker in any chat.", "Continue"),
        ("Where shall we begin?", "Choose a project folder to start a chat with Codex. You can also open Veo and pick a folder later.", "Choose a folder…")
    ];

    readonly WorkspaceCoordinator workspace;
    readonly Action applyTheme;
    readonly Action close;
    bool rendering;
    int page;
    public bool WantsFolder { get; private set; }

    public WorkspaceTour(WorkspaceCoordinator workspace, Action applyTheme, Action close)
    {
        InitializeComponent();
        foreach (var button in new[] { Back, Skip, Later }) TourGlass.Navigation(button);
        foreach (var button in new[] { ProviderSetup, DirectoryDone }) TourGlass.Button(button);
        TourGlass.Button(Next, primary: true);
        PrimarySheen.Background = TourGlass.Sheen(primary: true);
        AppearanceSurface.BorderBrush = TourGlass.Edge();
        this.workspace = workspace;
        this.applyTheme = applyTheme;
        this.close = close;
        page = Math.Clamp(workspace.Preferences.WorkspaceTourStep, 0, Pages.Length - 1);
        RenderPage();
        Loaded += BeginGreeting;
    }

    async void BeginGreeting(object sender, RoutedEventArgs args)
    {
        if (page != 0 || !new UISettings().AnimationsEnabled) return;
        Scene.Opacity = 0;
        Greeting.Visibility = Visibility.Visible;
        var draw = new DoubleAnimation { From = 190, To = 0, Duration = TimeSpan.FromSeconds(1.35), EnableDependentAnimation = true };
        Storyboard.SetTarget(draw, Ink);
        Storyboard.SetTargetProperty(draw, "StrokeDashOffset");
        var story = new Storyboard();
        story.Children.Add(draw);
        story.Begin();
        await Task.Delay(1700);
        if (!IsLoaded) return;
        Greeting.Visibility = Visibility.Collapsed;
        FadeIn(Scene);
    }

    static void FadeIn(UIElement target)
    {
        if (!new UISettings().AnimationsEnabled) { target.Opacity = 1; return; }
        var fade = new DoubleAnimation { From = 0, To = 1, Duration = TimeSpan.FromMilliseconds(330) };
        Storyboard.SetTarget(fade, target);
        Storyboard.SetTargetProperty(fade, "Opacity");
        var story = new Storyboard();
        story.Children.Add(fade);
        story.Begin();
    }

    void RenderPage()
    {
        rendering = true;
        var (heading, detail, action) = Pages[page];
        Heading.Text = heading;
        Detail.Text = detail;
        Next.Content = action;
        static Visibility Show(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;
        Back.Visibility = Show(page > 0);
        Brand.Visibility = Show(page == 0);
        Preview.Visibility = Show(page == 1 || page == 2);
        Files.Visibility = Show(page == 1);
        Chat.Visibility = AppearanceSurface.Visibility = Show(page == 2);
        Folder.Visibility = Later.Visibility = Show(page == 4);
        ProviderArt.Visibility = Show(page == 3);
        if (page == 3) RefreshProvider();
        var mode = workspace.Preferences.Appearance;
        var light = page == 2 && (mode == "Light" || (mode == "System" && Application.Current.RequestedTheme == ApplicationTheme.Light));
        Preview.RequestedTheme = light ? ElementTheme.Light : ElementTheme.Dark;
        PreviewPlate.SetLight(light);
        foreach (var choice in Modes.Children.OfType<RadioButton>()) choice.IsChecked = Equals(choice.Content, mode);
        ProgressDots.Children.Clear();
        for (int i = 0; i < Pages.Length; i++)
            ProgressDots.Children.Add(new Rectangle { Width = i == page ? 21 : 5, Height = 5, RadiusX = 3, RadiusY = 3,
                Fill = new SolidColorBrush(Microsoft.UI.Colors.White), Opacity = i == page ? 1 : .42 });
        AutomationProperties.SetName(ProgressDots, $"Step {page + 1} of {Pages.Length}");
        rendering = false;
    }

    async Task MoveAsync(int delta)
    {
        page = Math.Clamp(page + delta, 0, Pages.Length - 1);
        workspace.Preferences.WorkspaceTourStep = page;
        RenderPage();
        FadeIn(Stage);
        await workspace.SavePreferencesAsync();
    }

    async void Appearance_Checked(object sender, RoutedEventArgs args)
    {
        if (rendering || sender is not RadioButton { Content: string mode }) return;
        workspace.Preferences.Appearance = mode;
        applyTheme();
        RenderPage();
        await workspace.SavePreferencesAsync();
    }

    void RefreshProvider()
    {
        var connections = Services.AgentConnections.For(workspace);
        var selected = Services.AgentConnections.Catalog.FirstOrDefault(a => a.Id == connections.Choice("default"));
        ProviderName.Text = selected?.Name ?? "Codex";
        ProviderDetail.Text = selected == null ? "Local Codex CLI" : "Connected coding agent";
        ProviderLogo.Content = ProviderMark.Create(selected?.Id ?? "codex", 40);
    }

    void Providers_Click(object sender, RoutedEventArgs args)
    {
        DirectoryScroll.Content = new AgentDirectory(workspace,true);
        DirectoryHost.Visibility = Visibility.Visible; Scene.Visibility = Visibility.Collapsed;
        DirectoryDone.Focus(FocusState.Programmatic);
    }
    void CloseProviders_Click(object sender, RoutedEventArgs args)
    {
        DirectoryHost.Visibility = Visibility.Collapsed; Scene.Visibility = Visibility.Visible;
        RefreshProvider();
        ProviderSetup.Focus(FocusState.Programmatic);
    }
    async void Next_Click(object sender, RoutedEventArgs args)
    {
        if (page < Pages.Length - 1) { await MoveAsync(1); return; }
        WantsFolder = true;
        close();
    }
    async void Back_Click(object sender, RoutedEventArgs args) => await MoveAsync(-1);
    void Finish_Click(object sender, RoutedEventArgs args) => close();
}
