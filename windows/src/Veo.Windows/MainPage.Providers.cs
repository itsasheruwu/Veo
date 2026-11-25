using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Veo.Core;
using Veo.Infrastructure.Providers;
using Veo_Windows.Services;

namespace Veo_Windows;
public sealed partial class MainPage
{
    AgentConnections Agents => AgentConnections.For(workspace);
    string? ActiveAgent => current is { } session ? Agents.Choice(session.Record.VeoId) : null;
    static IconElement ProviderIcon(string? id, double size)
    {
        var file = "AgentMark-" + id + ".png";
        IconElement icon = id is not null && File.Exists(Path.Combine(AppContext.BaseDirectory, "Assets", file))
            ? new BitmapIcon { UriSource = new Uri("ms-appx:///Assets/" + file), ShowAsMonochrome = id == "codex" }
            : new FontIcon { Glyph = id == "fx" ? "ƒx" : "\uE950", FontSize = size - 3 };
        icon.Width = size;
        icon.Height = size;
        AutomationProperties.SetAccessibilityView(icon, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        return icon;
    }

    static string? ApiMark(string? id) => id is "xai" or "grok-build" or "grok" or "grok-oauth" ? "grok-build" : null;

    void RenderProvider()
    {
        var agent=AgentConnections.Catalog.FirstOrDefault(a=>a.Id==ActiveAgent);
        var catalogModel=App.Models.Find(modelCatalogId??model);
        var apiName = catalogModel?.IsExternal == true ? catalogModel.Id.Split('/')[0] : null;
        ComposerProviderName.Text = agent?.Name ?? apiName ?? "Codex";
        var mark = agent?.Id ?? (apiName is null ? "codex" : ApiMark(apiName));
        if (ComposerProviderMark.Content is null || !Equals(ComposerProviderMark.Tag, mark))
        {
            ComposerProviderMark.Tag = mark;
            var icon = ProviderIcon(mark, 15);
            ComposerProviderMark.Content = icon is BitmapIcon && mark != "codex"
                ? new Border { Width = 19, Height = 19, CornerRadius = new CornerRadius(4),
                    Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.WhiteSmoke), Child = icon }
                : icon;
        }
        AutomationProperties.SetName(ProviderTrigger, "Change provider, " + ComposerProviderName.Text);
        ProviderTrigger.IsEnabled=current is { IsSubmitting:false } && !current.Timeline.IsRunning;
        if(agent is null) return;
        var connection=Agents.Connections[agent.Id];
        ModelLabel.Text = connection.SelectedModel?.Name ?? "Provider default";
        ModelEffortLabel.Text = connection.SelectedModel?.Efforts?.FirstOrDefault(option => option.Id == connection.SelectedEffort)?.Name ?? "";
        ModelEffortLabel.Visibility = string.IsNullOrEmpty(ModelEffortLabel.Text) ? Visibility.Collapsed : Visibility.Visible;
        RenderComposerSpeedMark(connection.UsesFastSpeed ? ModelSpeed.Fast : ModelSpeed.Standard);
        UpdateComposerModelLayout();
        var label = $"Model settings, {ModelLabel.Text} {ModelEffortLabel.Text}".TrimEnd();
        AutomationProperties.SetName(ModelTrigger, label + (connection.UsesFastSpeed ? ", Fast Mode on" : ""));
    }
    async void Provider_Click(object sender,RoutedEventArgs args) => await Run(async () => {
        if(current is not { } session) return;
        var menu=new MenuFlyout {Placement=FlyoutPlacementMode.TopEdgeAlignedLeft};
        void Item(string text,Action click, string? mark=null)
        {
            var item=new MenuFlyoutItem {Text=text};
            item.Icon=ProviderIcon(mark, 16);
            if (item.Icon is BitmapIcon bitmap) bitmap.ShowAsMonochrome = true;
            item.Click+=(_,_)=>{if(ReferenceEquals(session,current))click();};
            menu.Items.Add(item);
        }
        void Use(string? id) { Agents.Choose(session.Record.VeoId,id); Render(); }
        void SelectNative(NativeModelDescriptor? m)
        {
            if(m==null) {Use(null);return;}
            var selection = Run(async () =>
            {
                var choice = App.Models.Validate(new(m.Id, m.Model, m.DefaultEffort, m.DefaultTier));
                await App.Models.SaveSelectionAsync(session, choice);
                if (!ReferenceEquals(session, current)) return;
                Agents.Choose(session.Record.VeoId, null);
                ApplyModelChoice(choice);
                await SaveDraftNowAsync();
                Render();
            });
            pendingComposerProviderSelection = selection;
            _ = Run(async () =>
            {
                await selection;
                if (ReferenceEquals(session, current)) await ShowModelPickerUpgradeAsync();
            });
        }
        Item("Codex",()=>SelectNative(App.Models.Selectable.FirstOrDefault(m=>!m.IsExternal)),mark:"codex");
        foreach(var a in AgentConnections.Catalog.Where(a=>Agents.Connections.ContainsKey(a.Id))) Item(a.Name,()=>Use(a.Id),a.Id);
        var api=await new ProviderConfigurationStore(workspace.DataRoot).LoadAsync();
        foreach(var p in api.Where(p=>p.Enabled))
        {
            var m=App.Models.Selectable.FirstOrDefault(m=>p.Models?.Any(r=>r.Enabled&&r.Id==m.Id)==true);
            if(m!=null)Item(p.Name,()=>SelectNative(m),p.Preset is ProviderPreset.Xai or ProviderPreset.GrokOAuth ? "grok-build" : null);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        Item("Connect a provider…",()=>_=Run(()=>ShowSettingsAsync("Providers")));
        if (ReferenceEquals(session, current)) ShowComposerPill(menu, composerProviderPill);
    });
    async Task SendAgentAsync(string id,ThreadSession session,string text, Func<Task> accepted)
    {
        var thread=session.Record.VeoId;
        var turn=Guid.NewGuid().ToString("N");
        var assistant=Guid.NewGuid().ToString("N");
        var userItem=Guid.NewGuid().ToString("N");
        var predecessor=session.Timeline.Items.LastOrDefault()?.Id ?? "";
        var history=session.Timeline.Items.Where(i=>i.Kind is "userMessage" or "agentMessage")
            .Select(i=>new {role=i.Kind=="userMessage"?"user":"assistant",text=i.Text}).ToArray();
        var veoProviderName=AgentConnections.Catalog.First(a=>a.Id==id).Name;
        if(history.Length==0 && (string.IsNullOrWhiteSpace(session.Record.Title) || session.Record.Title.Equals("New chat",StringComparison.OrdinalIgnoreCase))) {
            var firstLine=text.Trim().Split(['\r','\n'],StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
            if(!string.IsNullOrWhiteSpace(firstLine)) await workspace.RenameAsync(session,firstLine[..Math.Min(firstLine.Length,68)]);
        }
        void Apply(string method,object payload) {session.Timeline.Apply(method,JsonSerializer.SerializeToElement(payload));}
        Apply("turn/started",new {turnId=turn,turn=new {id=turn}});
        Apply("item/completed",new {turnId=turn,item=new {id=userItem,veoAfter=predecessor,type="userMessage",content=new[]{new {type="text",text}}}});
        Apply("item/started",new {turnId=turn,item=new {id=assistant,type="agentMessage",veoProviderName,veoAfter=userItem,text=""}});
        await workspace.PersistTimelineAsync(session);
        await accepted();
        if(ReferenceEquals(current,session))Render();
        var accumulated=new System.Text.StringBuilder();
        string output;
        try {
            output=await Agents.TurnAsync(id,session,text,composerAccess,history,delta=>{
                accumulated.Append(delta);
                Apply("item/agentMessage/delta",new {turnId=turn,itemId=assistant,delta});
                if(ReferenceEquals(current,session))Render();
            },async title=>{
                var dialog=new ContentDialog {XamlRoot=XamlRoot,Title="Allow this provider action?",Content=title,PrimaryButtonText="Allow once",CloseButtonText="Decline"};
                return await dialog.ShowAsync()==ContentDialogResult.Primary;
            });
            if(output.Length==0)output="The agent finished without a text reply.";
        } catch(Exception e) { output=accumulated+(accumulated.Length>0?"\n\n":"")+e.Message; }
        Apply("item/completed",new {turnId=turn,item=new {id=assistant,type="agentMessage",veoProviderName,veoAfter=userItem,text=output}});
        Apply("turn/completed",new {turnId=turn,turn=new {id=turn,status="completed"}});
        await workspace.PersistTimelineAsync(session);
        if(ReferenceEquals(current,session))Render();
    }
}
