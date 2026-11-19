using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Veo.Platform.Windows.Browser;

namespace Veo_Windows.Controls;
public sealed partial class BrowserPanel
{
    void WireAuthentication(Tab tab, CoreWebView2 core)
    {
        core.WebMessageReceived += (_, e) => Guard(() => PasswordOfferAsync(tab, e));
        Guard(async () => await core.AddScriptToExecuteOnDocumentCreatedAsync(PasswordCapture));
        core.BasicAuthenticationRequested += async (_, e) =>
        {
            var deferral = e.GetDeferral();
            e.Cancel = true;
            var epoch = tab.Epoch;
            try
            {
                if (tab.PreviewRoot is not null || !BrowserOrigin.IsWeb(e.Uri) || !BrowserOrigin.Same(tab.Address, e.Uri))
                    return;
                var uri = new Uri(e.Uri);
                var realm = e.Challenge ?? "";
                var result = await CredentialDialogAsync(uri, realm);
                if (result is null || tab.Closed || epoch != tab.Epoch || !BrowserOrigin.Same(tab.Address, e.Uri))
                    return;
                e.Response.UserName = result.Value.Account;
                e.Response.Password = result.Value.Secret;
                e.Cancel = false;
                if (result.Value.Save)
                    await credentials.SaveAsync(uri, result.Value.Account, result.Value.Secret, true, "Http", realm);
            }
            catch (Exception error)
            {
                progress.Text = error.Message;
            }
            finally
            {
                deferral.Complete();
            }
        };
    // Unhandled ClientCertificateRequested invokes WebView2's native certificate chooser.
    // WebAuthn stays with the platform; Veo does not emulate passkeys in JavaScript.
    }

    void WirePermissions(Tab tab, CoreWebView2 core)
    {
        core.PermissionRequested += async (_, e) =>
        {
            var deferral = e.GetDeferral();
            e.State = CoreWebView2PermissionState.Deny;
            e.SavesInProfile = false;
            var epoch = tab.Epoch;
            try
            {
                if (tab.PreviewRoot is not null || !BrowserOrigin.IsWeb(e.Uri))
                    return;
                var dialog = new ContentDialog
                {
                    Title = "Website permission",
                    Content = $"{BrowserOrigin.Of(new(e.Uri))} requests {e.PermissionKind}.",
                    PrimaryButtonText = "Allow once",
                    CloseButtonText = "Deny",
                    DefaultButton = ContentDialogButton.Close
                };
                if (await ShowAsync(dialog) == ContentDialogResult.Primary && !tab.Closed && epoch == tab.Epoch)
                    e.State = CoreWebView2PermissionState.Allow;
            }
            catch (Exception error)
            {
                progress.Text = error.Message;
            }
            finally
            {
                deferral.Complete();
            }
        };
    }

    async Task FillAsync()
    {
        if (Current is not { PreviewRoot: null } tab || !workspace.Preferences.BrowserAutoFill || !BrowserOrigin.IsWeb(tab.Address))
        {
            progress.Text = "Password fill is available for web pages when AutoFill is enabled.";
            return;
        }

        await EnsureAsync(tab);
        var epoch = tab.Epoch;
        var origin = new Uri(tab.Address);
        var ids = await credentials.ListAsync(origin);
        if (ids.Count == 0)
        {
            progress.Text = "No saved Veo password for this origin.";
            return;
        }

        var picker = new ComboBox
        {
            ItemsSource = ids.Select(x => x.Account).ToArray(),
            SelectedIndex = 0,
            MinWidth = 240
        };
        var content = new StackPanel
        {
            Spacing = 8
        };
        content.Children.Add(new TextBlock { Text = BrowserOrigin.Of(origin) });
        content.Children.Add(picker);
        var dialog = new ContentDialog
        {
            Title = "Fill password",
            Content = content,
            PrimaryButtonText = "Fill",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };
        if (await ShowAsync(dialog) != ContentDialogResult.Primary || tab.Closed || tab.Epoch != epoch || !BrowserOrigin.Same(tab.View.CoreWebView2.Source, origin.AbsoluteUri))
            return;
        var saved = credentials.Read(ids[picker.SelectedIndex], new(tab.View.CoreWebView2.Source));
        if (saved is null)
        {
            progress.Text = "This credential is no longer available.";
            return;
        }

        var payload = JsonSerializer.Serialize(new { origin = BrowserOrigin.Of(origin), username = saved.Account, password = saved.Secret });
        var result = await tab.View.CoreWebView2.ExecuteScriptAsync("((p)=>{if(window!==top||location.origin!==p.origin)return false;const pw=Array.from(document.querySelectorAll('input[type=password]')).find(x=>x.offsetParent!==null&&!x.disabled&&!x.readOnly);if(!pw)return false;const form=pw.form||document;const user=Array.from(form.querySelectorAll('input')).find(x=>x!==pw&&x.offsetParent!==null&&(x.autocomplete==='username'||x.type==='email'||/user|email|login/i.test(x.name+' '+x.id)));const set=(e,v)=>{if(!e)return;Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(e,v);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));};set(user,p.username);set(pw,p.password);return true;})(" + payload + ")");
        progress.Text = result == "true" ? "Password filled for " + BrowserOrigin.Of(origin) : "No visible password field was found.";
    }

    async Task RemovePasswordAsync()
    {
        if (Current is not { } tab || !BrowserOrigin.IsWeb(tab.Address))
            return;
        var ids = await credentials.ListAsync(new(tab.Address));
        if (ids.Count == 0)
        {
            progress.Text = "No saved form password for this origin.";
            return;
        }

        var picker = new ComboBox
        {
            ItemsSource = ids.Select(x => x.Account).ToArray(),
            SelectedIndex = 0
        };
        var dialog = new ContentDialog
        {
            Title = "Remove saved password",
            Content = picker,
            PrimaryButtonText = "Remove",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };
        if (await ShowAsync(dialog) == ContentDialogResult.Primary)
        {
            await credentials.DeleteAsync(ids[picker.SelectedIndex]);
            progress.Text = "Saved password removed.";
        }
    }

    async Task PasswordOfferAsync(Tab tab, CoreWebView2WebMessageReceivedEventArgs message)
    {
        if (!workspace.Preferences.BrowserAutoFill || tab.Closed || tab.PreviewRoot is not null || !BrowserOrigin.Same(message.Source, tab.Address) || !BrowserOrigin.Same(message.Source, tab.View.CoreWebView2.Source))
            return;
        var json = message.WebMessageAsJson;
        if (json.Length > 16000)
            return;
        using var doc = JsonDocument.Parse(json);
        var value = doc.RootElement;
        if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty("veo", out var kind) || kind.GetString() != "password-save" || !value.TryGetProperty("origin", out var originValue) || !BrowserOrigin.Same(originValue.GetString(), message.Source))
            return;
        if (!value.TryGetProperty("account", out var accountValue) || !value.TryGetProperty("secret", out var secretValue) || accountValue.ValueKind != JsonValueKind.String || secretValue.ValueKind != JsonValueKind.String)
            return;
        var account = accountValue.GetString() ?? "";
        var secret = secretValue.GetString() ?? "";
        if (account.Length is 0 or > 512 || Encoding.UTF8.GetByteCount(secret)is 0 or > 2560)
            return;
        var origin = new Uri(message.Source);
        var epoch = tab.Epoch;
        var dialog = new ContentDialog
        {
            Title = "Save password in Veo?",
            Content = $"Save the password for {account} at {BrowserOrigin.Of(origin)} in your Windows Credential Manager?",
            PrimaryButtonText = "Save password",
            CloseButtonText = "Not now",
            DefaultButton = ContentDialogButton.Close
        };
        if (await ShowAsync(dialog) == ContentDialogResult.Primary && !tab.Closed && BrowserOrigin.Same(tab.View.CoreWebView2.Source, origin.AbsoluteUri))
        {
            await credentials.SaveAsync(origin, account, secret, true);
            progress.Text = "Password saved for " + BrowserOrigin.Of(origin);
        }
    }

    async Task<(string Account, string Secret, bool Save)?> CredentialDialogAsync(Uri origin, string realm)
    {
        var saved = workspace.Preferences.BrowserAutoFill ? await credentials.ListAsync(origin, "Http", realm) : [];
        var content = new StackPanel
        {
            Spacing = 8
        };
        content.Children.Add(new TextBlock { Text = BrowserOrigin.Of(origin) + (origin.Scheme == "http" ? " (unencrypted HTTP)" : ""), TextWrapping = TextWrapping.Wrap });
        var account = new TextBox
        {
            Header = "Username"
        };
        var secret = new PasswordBox
        {
            Header = "Password"
        };
        var remember = new CheckBox
        {
            Content = "Save this origin and authentication realm in Windows Credential Manager"
        };
        if (saved.Count != 0)
        {
            var picker = new ComboBox
            {
                Header = "Saved credentials",
                ItemsSource = saved.Select(x => x.Account).ToArray(),
                PlaceholderText = "Choose a saved account"
            };
            picker.SelectionChanged += (_, _) =>
            {
                if (picker.SelectedIndex >= 0 && credentials.Read(saved[picker.SelectedIndex], origin)is { } value)
                {
                    account.Text = value.Account;
                    secret.Password = value.Secret;
                }
            };
            content.Children.Add(picker);
        }

        content.Children.Add(account);
        content.Children.Add(secret);
        content.Children.Add(remember);
        var dialog = new ContentDialog
        {
            Title = "Website authentication",
            Content = content,
            PrimaryButtonText = "Sign in",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };
        return await ShowAsync(dialog) == ContentDialogResult.Primary ? (account.Text, secret.Password, remember.IsChecked == true) : null;
    }

    const string PasswordCapture = """
    (()=>{if(window!==top||window.__veoPasswordCapture)return;window.__veoPasswordCapture=true;
    document.addEventListener('submit',e=>{if(!(e.target instanceof HTMLFormElement))return;
    const pw=Array.from(e.target.querySelectorAll('input[type=password]')).find(x=>x.offsetParent!==null&&!x.disabled&&x.value);
    if(!pw)return;const user=Array.from(e.target.querySelectorAll('input')).find(x=>x!==pw&&x.offsetParent!==null&&(x.autocomplete==='username'||x.type==='email'||/user|email|login/i.test(x.name+' '+x.id)));
    if(user&&user.value)chrome.webview.postMessage({veo:'password-save',origin:location.origin,account:user.value,secret:pw.value});},true);})();
    """;
}
