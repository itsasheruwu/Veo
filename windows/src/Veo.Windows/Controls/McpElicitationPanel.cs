using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Veo.Protocol;

namespace Veo_Windows.Controls;

public sealed class McpElicitationPanel : StackPanel
{
    readonly IntegrationCoordinator integrations;
    readonly RuntimeEvent request;
    readonly InfoBar error = new() { Severity = InfoBarSeverity.Error, IsClosable = true };
    public McpElicitationPanel(IntegrationCoordinator integrations, RuntimeEvent request)
    {
        this.integrations = integrations; this.request = request; Spacing = 10;
        Children.Add(new TextBlock { Text = request.Parameters.Str("message") ?? "An integration requests input.", TextWrapping = TextWrapping.Wrap, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        NativeSchemaFormPanel? form = null; var mode = request.Parameters.Str("mode"); var supported = false;
        if (mode == "form" && request.Parameters.TryObjectProperty("requestedSchema", out var schema))
        { form = new(NativeSchemaForm.Parse(schema)); Children.Add(form); supported = form.Form.IsSupported; }
        else if (mode == "url")
        {
            var url = IntegrationCoordinator.SecureUri(request.Parameters.Str("url")); supported = url is not null;
            Children.Add(new TextBlock { Text = url?.Host ?? "This request does not provide a secure URL.", TextWrapping = TextWrapping.Wrap });
            var open = new Button { Content = "Open in Veo's browser", IsEnabled = supported }; open.Click += (_, _) => Run(() => { integrations.OpenElicitationUrl(request); return Task.CompletedTask; }); Children.Add(open);
        }
        else Children.Add(new TextBlock { Text = "This integration requested an unsupported form mode. You can decline or cancel it.", TextWrapping = TextWrapping.Wrap });
        Children.Add(error);
        var bar = new CommandBar { DefaultLabelPosition = CommandBarDefaultLabelPosition.Right };
        var accept = new AppBarButton { Label = mode == "url" ? "Continue" : "Send form", IsEnabled = supported, Icon = new SymbolIcon(Symbol.Send) };
        accept.Click += (_, _) => Run(async () => { await integrations.RespondElicitationAsync(request, form?.Values(), "accept"); Visibility = Visibility.Collapsed; });
        var decline = new AppBarButton { Label = "Decline" }; decline.Click += (_, _) => Run(async () => { await integrations.RespondElicitationAsync(request, null, "decline"); Visibility = Visibility.Collapsed; });
        var cancel = new AppBarButton { Label = "Cancel" }; cancel.Click += (_, _) => Run(async () => { await integrations.RespondElicitationAsync(request, null, "cancel"); Visibility = Visibility.Collapsed; });
        bar.PrimaryCommands.Add(accept); bar.PrimaryCommands.Add(decline); bar.SecondaryCommands.Add(cancel); Children.Add(bar);
    }
    async void Run(Func<Task> action) { try { await action(); error.IsOpen = false; } catch (Exception exception) { error.Message = DiagnosticRedactor.Redact(exception.Message); error.IsOpen = true; } }
}
