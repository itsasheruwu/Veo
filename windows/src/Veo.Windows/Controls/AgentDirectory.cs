using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Veo.Core;
using Veo_Windows.Services;

namespace Veo_Windows.Controls;

public sealed class AgentDirectory : UserControl
{
    readonly AgentConnections agents;
    readonly StackPanel rows = new() { Spacing=6 };
    readonly TextBox search = new() {PlaceholderText="Find a provider"};
    readonly ToggleSwitch registry = new() { Header="ACP Registry",OnContent="All agents",OffContent="Featured agents" };
    readonly TextBlock status = new() {TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true};
    readonly bool onboarding;
    readonly Dictionary<string, Button> updateButtons = [];
    void UpdateButtonStates()
    {
        foreach (var (id, button) in updateButtons) {
            var info = agents.UpdateInfo(id);
            button.Content = info.Label;
            button.IsEnabled = info.Actionable && id != "custom-acp";
            AutomationProperties.SetName(button, info.Label + " " + button.Tag);
            AutomationProperties.SetHelpText(button, info.Detail);
            ToolTipService.SetToolTip(button, info.Detail);
        }
    }
    public AgentDirectory(WorkspaceCoordinator workspace,bool onboarding=false)
    {
        this.onboarding=onboarding;
        agents=AgentConnections.For(workspace);
        var body = new StackPanel {Spacing=onboarding ? 6 : 12,Children={search,status,rows,registry}};
        if (onboarding) {
            search.CornerRadius = new CornerRadius(8);
            rows.Spacing = 1;
            registry.Header = null;
            status.RegisterPropertyChangedCallback(TextBlock.TextProperty, (_, _) =>
                status.Visibility = string.IsNullOrEmpty(status.Text) ? Visibility.Collapsed : Visibility.Visible);
            status.Visibility = Visibility.Collapsed;
        }
        Content=body;
        Loaded += async (_, _) => { agents.UpdatesChanged += UpdateButtonStates; await agents.CheckUpdatesAsync(); };
        Unloaded += (_, _) => agents.UpdatesChanged -= UpdateButtonStates;
        search.TextChanged+=(_,_)=>Refresh();registry.Toggled+=(_,_)=>Refresh();Refresh();
    }
    void Refresh()
    {
        rows.Children.Clear();
        updateButtons.Clear();
        if("Codex".Contains(search.Text,StringComparison.OrdinalIgnoreCase))
            Add("Codex","Local Codex CLI",onboarding?"Use Codex":"Built in",onboarding?()=>agents.Choose("default",null):null,"codex");
        foreach(var agent in AgentConnections.Catalog.OrderByDescending(a=>agents.Connections.ContainsKey(a.Id)).Where(a=>(a.Featured||registry.IsOn||search.Text.Length>0||agents.Connections.ContainsKey(a.Id))&&a.Name.Contains(search.Text,StringComparison.OrdinalIgnoreCase)))
        {
            agents.Connections.TryGetValue(agent.Id,out var c);
            Add(agent.Name,c is null?"Local coding agent":$"{c.Models.Length} available models",c is null?"Connect":"Manage",()=>_=SetupAsync(agent),agent.Id);
            if(onboarding && c is not null) Add(agent.Name,"Default for new chats","Use",()=>{agents.Choose("default",agent.Id);status.Text="Selected "+agent.Name;});
        }
        UpdateButtonStates();
    }
    void Add(string title,string detail,string action,Action? click,string? mark=null)
    {
        var grid=new Grid {ColumnSpacing=12,Padding=new Thickness(12,8,12,8),CornerRadius=new CornerRadius(9),Background=(Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"]};
        if (onboarding) {
            grid.Background = null;
            grid.Padding = new Thickness(4,6,3,6);
        }
        grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});grid.ColumnDefinitions.Add(new());grid.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        grid.Children.Add(ProviderMark.Create(mark, 30));
        var label=new StackPanel {Spacing=2,Children={new TextBlock {Text=title,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold},new TextBlock {Text=detail,FontSize=12,Opacity=.72}}};
        Grid.SetColumn(label,1);grid.Children.Add(label);
        var button=new Button {Content=action,IsEnabled=click!=null,VerticalAlignment=VerticalAlignment.Center};
        if (onboarding) TourGlass.Button(button);
        AutomationProperties.SetName(button,action+" "+title);
        button.Click+=(_,_)=>click?.Invoke();
        var actions = new StackPanel { Orientation=Orientation.Horizontal, Spacing=6, VerticalAlignment=VerticalAlignment.Center };
        if (mark is not null) {
            var update = new Button { Width=88, Height=30, Padding=new Thickness(3,0,3,0), Tag=title };
            if (onboarding) TourGlass.Button(update);
            button.Width=update.Width; button.Height=update.Height; button.Padding=update.Padding;
            updateButtons[mark]=update;
            AutomationProperties.SetAutomationId(update,"UpdateProvider_"+mark);
            update.Click += async (_,_) => {
                try {
                    status.Text="";
                    var info = agents.UpdateInfo(mark);
                    if (info.State=="retry") { await agents.CheckUpdatesAsync(); }
                    else {
                        await agents.UpdateAsync(mark);
                        status.Text=agents.UpdateInfo(mark).Detail + (mark=="codex" ? " Restart Veo to reload the Codex runtime." : "");
                    }
                } catch(Exception error) { status.Text=error.Message; }
            };
            actions.Children.Add(update);
        }
        actions.Children.Add(button);
        Grid.SetColumn(actions,2); grid.Children.Add(actions); rows.Children.Add(grid);
    }
    async Task SetupAsync(AgentDefinition agent)
    {
        try {
            agents.Connections.TryGetValue(agent.Id,out var saved);
            var binary=new TextBox {Header="Executable name or absolute path",Text=saved?.Executable??(agent.Command=="agy_acp_server.par"?"agy_acp_server":agent.Command)};
            var args=new TextBox {Header="Arguments · one per line",AcceptsReturn=true,Text=string.Join(Environment.NewLine,saved?.Args??agent.Args)};
            var content=new StackPanel {Spacing=12,Children={new HyperlinkButton {Content="Installation and sign-in guide",NavigateUri=new Uri(agent.Site)},binary,args}};
            var dialog=new ContentDialog {XamlRoot=XamlRoot,Title=agent.Name,Content=content,PrimaryButtonText="Connect",SecondaryButtonText=saved is null?"":"Disconnect",CloseButtonText="Close"};
            if (onboarding) {
                // Keep the ordinary connection one click away; command overrides stay available.
                content.Children.Clear();
                var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
                title.Children.Add(ProviderMark.Create(agent.Id, 34));
                title.Children.Add(new TextBlock { Text = agent.Name, FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
                dialog.Title = title;
                content.Children.Add(new TextBlock { Text = "Install the agent and sign in, then connect it to Veo.", TextWrapping = TextWrapping.Wrap });
                content.Children.Add(new HyperlinkButton { Content = "Installation and sign-in guide", NavigateUri = new Uri(agent.Site), Padding = new Thickness(0,2,0,2) });
                content.Children.Add(new Expander { Header = "Executable and arguments", HorizontalAlignment = HorizontalAlignment.Stretch,
                    IsExpanded = saved != null || string.IsNullOrWhiteSpace(binary.Text),
                    Content = new StackPanel { Spacing = 8, Children = { binary, args } } });
                TourGlass.Dialog(dialog, ActualTheme);
            }
            var result=await dialog.ShowAsync();
            if(result==ContentDialogResult.Primary) {
                status.Text="Connecting to "+agent.Name+"…";
                await agents.ConnectAsync(agent,binary.Text.Trim(),args.Text.Split(['\r','\n'],StringSplitOptions.RemoveEmptyEntries));
                status.Text=agent.Name+" connected.";
            } else if(result==ContentDialogResult.Secondary) { agents.Disconnect(agent.Id);status.Text=agent.Name+" disconnected."; }
            Refresh();
            await agents.CheckUpdatesAsync();
        } catch(Exception e) {status.Text=e.Message;}
    }
}
