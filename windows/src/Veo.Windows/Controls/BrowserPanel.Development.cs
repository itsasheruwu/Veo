using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Veo.Platform.Windows.Browser;

namespace Veo_Windows.Controls;
public sealed partial class BrowserPanel
{
    readonly ListView console = new()
    {
        MaxHeight = 170,
        ItemContainerTransitions = new()
    };
    readonly TextBox script = new()
    {
        PlaceholderText = "Evaluate JavaScript in the selected page"
    };
    readonly StackPanel consolePanel = new()
    {
        Visibility = Visibility.Collapsed,
        Spacing = 4
    };
    void BuildConsole(StackPanel parent)
    {
        consolePanel.Children.Add(console);
        var row = new Grid();
        row.ColumnDefinitions.Add(new());
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.Children.Add(script);
        var evaluate = new Button
        {
            Content = "Evaluate"
        };
        evaluate.Click += (_, _) => Guard(EvaluateAsync);
        SetColumn(evaluate, 1);
        row.Children.Add(evaluate);
        consolePanel.Children.Add(row);
        var clear = new Button
        {
            Content = "Clear console"
        };
        clear.Click += (_, _) =>
        {
            Current?.Console.Clear();
            RefreshConsole();
        };
        consolePanel.Children.Add(clear);
        parent.Children.Add(consolePanel);
        script.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                e.Handled = true;
                Guard(EvaluateAsync);
            }
        };
    }

    async Task WireConsoleAsync(Tab tab, CoreWebView2 core)
    {
        await core.CallDevToolsProtocolMethodAsync("Runtime.enable", "{}");
        core.GetDevToolsProtocolEventReceiver("Runtime.consoleAPICalled").DevToolsProtocolEventReceived += (_, e) =>
        {
            try
            {
                AddConsole(tab, BrowserConsoleMessages.ParseDevTools(e.ParameterObjectAsJson));
            }
            catch (Exception error)when (error is JsonException or InvalidDataException)
            {
                AddConsole(tab, "[malformed console event]");
            }
        };
    }

    async Task EvaluateAsync()
    {
        if (Current is not { } tab || string.IsNullOrWhiteSpace(script.Text))
            return;
        if (script.Text.Length > 16384)
            throw new InvalidOperationException("JavaScript evaluation is limited to 16 KiB.");
        await EnsureAsync(tab);
        AddConsole(tab, "> " + script.Text);
        AddConsole(tab, await tab.View.CoreWebView2.ExecuteScriptAsync(script.Text));
        script.Text = "";
    }

    void AddConsole(Tab tab, string value)
    {
        if (tab.Closed || disposed)
            return;
        tab.Console.Add(value.Length > 4096 ? value[..4096] + "…" : value);
        if (tab.Console.Count > 500)
            tab.Console.RemoveRange(0, tab.Console.Count - 500);
        if (Current == tab)
            RefreshConsole();
    }

    void RefreshConsole()
    {
        console.ItemsSource = Current?.Console.ToArray() ?? [];
    }

    void WirePreview(Tab tab, CoreWebView2 core)
    {
        core.AddWebResourceRequestedFilter("https://*.veo-preview.invalid/*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += async (_, e) =>
        {
            var deferral = e.GetDeferral();
            try
            {
                if (tab.PreviewRoot is null || tab.PreviewHost is null || e.Request.Method != "GET")
                    throw new UnauthorizedAccessException("The preview request is not authorized.");
                var epoch = tab.Epoch;
                var path = SafePreviewFiles.ResolveRequest(tab.PreviewRoot, new(e.Request.Uri), tab.PreviewHost);
                var bytes = await SafePreviewFiles.ReadAsync(tab.PreviewRoot, path);
                if (tab.Closed || epoch != tab.Epoch)
                    throw new UnauthorizedAccessException("This preview navigation has ended.");
                tab.PreviewBytes += bytes.Length;
                if (tab.PreviewBytes > 64 * 1024 * 1024)
                    throw new InvalidDataException("Preview resources exceeded 64 MiB. Reload to start again.");
                e.Response = environment!.CreateWebResourceResponse(new MemoryStream(bytes, false).AsRandomAccessStream(), 200, "OK", "Content-Type: " + SafePreviewFiles.Mime(path) + "\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\nContent-Security-Policy: " + SafePreviewFiles.ContentSecurityPolicy);
            }
            catch (Exception error)when (error is IOException or UnauthorizedAccessException or ArgumentException)
            {
                e.Response = environment!.CreateWebResourceResponse(new MemoryStream(Encoding.UTF8.GetBytes("Preview resource unavailable.")).AsRandomAccessStream(), 403, "Forbidden", "Content-Type: text/plain\r\nCache-Control: no-store");
                progress.Text = error.Message;
            }
            finally
            {
                deferral.Complete();
            }
        };
    }

    async Task ChoosePreviewAsync()
    {
        if (scope is null)
            return;
        var path = new TextBox
        {
            Header = "HTML path relative to this workspace",
            PlaceholderText = "index.html"
        };
        var dialog = new ContentDialog
        {
            Title = "Preview workspace HTML",
            Content = path,
            PrimaryButtonText = "Open preview",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };
        if (await ShowAsync(dialog) == ContentDialogResult.Primary)
            await OpenWorkspaceFileAsync(path.Text);
    }

    public async Task OpenWorkspaceFileAsync(string path)
    {
        if (scope is null)
            throw new InvalidOperationException("Select a workspace before opening its preview.");
        var root = scope;
        var file = Path.GetFullPath(Path.IsPathFullyQualified(path) ? path : Path.Combine(root, path));
        if (Path.GetExtension(file).ToLowerInvariant()is not (".html" or ".htm"))
            throw new InvalidOperationException("Choose an HTML file for the initial preview.");
        await SafePreviewFiles.ReadAsync(root, file);
        var relative = Path.GetRelativePath(root, file);
        if (relative.StartsWith("..") || Path.IsPathFullyQualified(relative))
            throw new UnauthorizedAccessException("The preview is outside the workspace.");
        var tab = await AddTabAsync();
        tab.PreviewRoot = root;
        tab.PreviewHost = Guid.NewGuid().ToString("N") + ".veo-preview.invalid";
        await EnsureAsync(tab);
        ShowPage(tab);
        tab.View.Source = new("https://" + tab.PreviewHost + "/" + string.Join('/', relative.Split(Path.DirectorySeparatorChar).Select(Uri.EscapeDataString)));
    }
}
