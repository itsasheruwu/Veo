using System.ComponentModel;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Veo.Core;
using Veo.Infrastructure.Providers;

namespace Veo_Windows.Controls;

public sealed class ExternalModelRow(ExternalModelRecord model, Action<bool> changed) : INotifyPropertyChanged
{
    private bool enabled = model.Enabled;
    public string Name => model.DisplayName;
    public string Detail => model.UpstreamId + (model.ContextWindow is { } context ? " · " + context.ToString("N0") + " tokens" : "");
    public bool Enabled { get => enabled; set { if (enabled == value) return; enabled = value; PropertyChanged?.Invoke(this, new(nameof(Enabled))); changed(value); } }
    public event PropertyChangedEventHandler? PropertyChanged;
}

/// <summary>Optional provider configuration and explicitly authorized direct requests.</summary>
public sealed class ProvidersPanel : UserControl
{
    private readonly WorkspaceCoordinator workspace;
    private readonly ProviderConfigurationStore configuration;
    private readonly ExternalProviderService service;
    private readonly Action<Uri>? navigate;
    private readonly List<ExternalProvider> providers = [];
    private readonly ComboBox saved = new() { Header = "Connected provider configurations", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly ComboBox preset = new() { Header = "Provider", ItemsSource = Enum.GetValues<ProviderPreset>().Select(value => ExternalProvider.Create(value)).ToArray(), SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox name = new() { Header = "Name" };
    private readonly TextBox endpoint = new() { Header = "HTTPS API base URL" };
    private readonly ComboBox wire = new() { Header = "API format", ItemsSource = Enum.GetValues<ProviderWireApi>(), SelectedIndex = 0 };
    private readonly PasswordBox apiKey = new() { Header = "API key", PasswordRevealMode = PasswordRevealMode.Peek };
    private readonly ToggleSwitch enabled = new() { Header = "Enable this optional provider", IsOn = false };
    private readonly CheckBox consent = new() { Content = "Allow the next external request to the destination shown above", IsChecked = false };
    private readonly ListView models = new() { MaxHeight = 220, SelectionMode = ListViewSelectionMode.None, ItemContainerTransitions = new() };
    private readonly ComboBox selectedModel = new() { Header = "Model for explicit test request", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBox prompt = new() { Header = "Test prompt sent directly to this provider", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 120 };
    private readonly TextBox output = new() { Header = "Provider response", IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 240 };
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock challengeText = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private readonly InfoBar notice = new() { IsOpen = false, IsClosable = true };
    private readonly StackPanel body = new() { Spacing = 10 };
    private ExternalProvider? current;
    private CancellationTokenSource? operation;
    private bool busy;
    private bool loading;
    public ProvidersPanel(WorkspaceCoordinator workspace, Action<Uri>? navigate = null)
    {
        this.workspace = workspace; this.navigate = navigate; configuration = new(workspace.DataRoot);
        var devicePath = Path.Combine(workspace.DataRoot, "Settings", "provider-device-id"); Directory.CreateDirectory(Path.GetDirectoryName(devicePath)!);
        if (!File.Exists(devicePath)) File.WriteAllText(devicePath, Guid.NewGuid().ToString("N"));
        var profile = Path.GetFileName(Path.TrimEndingDirectorySeparator(workspace.DataRoot));
        service = new(new ProviderCredentialAdapter(profile), File.ReadAllText(devicePath).Trim());
        body.Children.Add(new TextBlock { Text = "External providers are optional. API keys and OAuth tokens are stored in Windows Credential Manager. Catalog probes and prompts contact the chosen provider directly; its own billing and terms apply.", TextWrapping = TextWrapping.Wrap });
        foreach (var control in new FrameworkElement[] { saved, preset, name, endpoint, wire, apiKey, enabled }) body.Children.Add(control);
        ActionButton("Save provider and entered API key", SaveAsync);
        ActionButton("Add another custom provider", () => SelectAsync(ExternalProvider.Create(ProviderPreset.Custom)));
        ActionButton("Remove provider and local credentials", RemoveAsync);
        body.Children.Add(consent);
        ActionButton("Probe live model catalog", ProbeAsync);
        ActionButton("Start provider device sign-in", SignInAsync);
        ActionButton("Cancel pending provider request", () => { operation?.Cancel(); return Task.CompletedTask; }, allowBusy: true);
        body.Children.Add(challengeText); body.Children.Add(status); body.Children.Add(models); body.Children.Add(selectedModel); body.Children.Add(prompt);
        ActionButton("Send explicit test prompt", TestAsync); body.Children.Add(output); body.Children.Add(notice); Content = body;
        models.ItemTemplate = (DataTemplate)XamlReader.Load("""
            <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><StackPanel><CheckBox Content="{Binding Name}" IsChecked="{Binding Enabled,Mode=TwoWay}"/><TextBlock Text="{Binding Detail}" Foreground="{ThemeResource TextFillColorSecondaryBrush}" FontSize="12"/></StackPanel></DataTemplate>
            """);
        AutomationProperties.SetName(consent, "Allow next external provider request");
        saved.SelectionChanged += async (_, _) => { if (!loading && saved.SelectedItem is ExternalProvider provider) await RunAsync(() => SelectAsync(provider)); };
        preset.SelectionChanged += async (_, _) => { if (!loading && preset.SelectedItem is ExternalProvider provider) await RunAsync(() => SelectAsync(provider)); };
        endpoint.TextChanged += (_, _) => consent.IsChecked = false;
        Loaded += async (_, _) => await RunAsync(async () => { providers.Clear(); providers.AddRange(await configuration.LoadAsync()); RefreshSaved(); await SelectAsync(providers.FirstOrDefault() ?? ExternalProvider.Create(ProviderPreset.Anthropic)); });
        Unloaded += (_, _) => operation?.Cancel();
    }
    private async Task SelectAsync(ExternalProvider provider)
    {
        current = provider; loading = true;
        preset.SelectedIndex = (int)provider.Preset;
        name.Text = provider.Name; endpoint.Text = provider.BaseUrl; wire.SelectedItem = provider.WireApi; enabled.IsOn = provider.Enabled;
        apiKey.Password = ""; apiKey.IsEnabled = !provider.IsOAuth; consent.IsChecked = false; challengeText.Text = "";
        loading = false; RefreshModels();
        if (string.IsNullOrWhiteSpace(provider.BaseUrl)) { status.Text = "Enter the custom provider's HTTPS base URL before saving or connecting."; return; }
        status.Text = await service.Authentication.HasCredentialAsync(provider) ? "Credential stored; connection status: " + service.State(provider.Id) : "No saved credential for this endpoint.";
        if (provider.IsOAuth) status.Text += " Sign-in and refresh also contact " + ProviderOAuthDescriptor.For(provider).TokenEndpoint.Host + ".";
    }
    private ExternalProvider Form()
    {
        var provider = current ?? throw new InvalidOperationException("Choose a provider.");
        var result = provider with { Name = name.Text.Trim(), BaseUrl = endpoint.Text.Trim(), WireApi = (ProviderWireApi)(wire.SelectedItem ?? ProviderWireApi.Chat), Enabled = enabled.IsOn };
        _ = result.BaseUri; return result;
    }
    private async Task SaveAsync()
    {
        var provider = Form();
        if (current is not null && providers.Any(p => p.Id == current.Id) && current.Identity != provider.Identity) await service.Authentication.DisconnectAsync(current);
        if (!provider.IsOAuth && apiKey.Password.Length > 0) { await service.Authentication.SaveApiKeyAsync(provider, apiKey.Password); apiKey.Password = ""; }
        var index = providers.FindIndex(p => p.Id == provider.Id); if (index >= 0) providers[index] = provider; else providers.Add(provider);
        await configuration.SaveAsync(providers); current = provider; RefreshSaved();
        status.Text = "Saved locally. Connection status: " + service.State(provider.Id);
    }
    private async Task RemoveAsync()
    {
        if (current is null) return; await service.Authentication.DisconnectAsync(current); providers.RemoveAll(p => p.Id == current.Id);
        await configuration.SaveAsync(providers); RefreshSaved(); await SelectAsync(ExternalProvider.Create(ProviderPreset.Anthropic)); status.Text = "Provider configuration and its local credentials were removed.";
    }
    private ProviderConsent Approval(ProviderRequestPurpose purpose)
    {
        var provider = Form();
        if (consent.IsChecked != true) throw new UnauthorizedAccessException("Approve this external request before continuing.");
        consent.IsChecked = false; return ProviderConsent.Approve(provider, purpose);
    }
    private async Task ProbeAsync()
    {
        var provider = Form(); var approval = Approval(ProviderRequestPurpose.Catalog); await SaveAsync();
        var found = await service.ProbeAsync(provider, approval, operation!.Token);
        current = provider with { Models = found.ToArray() }; await PersistCurrentAsync(); RefreshModels(); status.Text = "Connected; " + found.Count + " models reported by the provider.";
    }
    private async Task SignInAsync()
    {
        var provider = Form(); if (!provider.IsOAuth) throw new InvalidOperationException("This provider uses an API key. Enter the key and probe its catalog.");
        var approval = Approval(ProviderRequestPurpose.Authentication); await SaveAsync();
        var challenge = await service.Authentication.StartAsync(provider, approval, operation!.Token);
        challengeText.Text = "Code: " + challenge.UserCode + "\n" + challenge.VerificationUri;
        if (navigate is not null) navigate(challenge.VerificationUri);
        else status.Text = "Open this verification URL in Veo's browser, then return here. Waiting for authorization…";
        await service.Authentication.CompleteAsync(provider, challenge, approval, operation.Token);
        status.Text = "Provider sign-in completed. Approve a catalog probe to discover available models.";
    }
    private async Task TestAsync()
    {
        var provider = Form(); if (selectedModel.SelectedItem is not ExternalModelRecord model || !model.Enabled) throw new InvalidOperationException("Choose an enabled model from the live catalog.");
        if (string.IsNullOrWhiteSpace(prompt.Text)) throw new InvalidOperationException("Enter the exact prompt to send.");
        var approval = Approval(ProviderRequestPurpose.Inference); await SaveAsync(); output.Text = "";
        using var document = JsonDocument.Parse(JsonSerializer.Serialize(new { model = model.Id, input = prompt.Text, stream = true }));
        await foreach (var item in service.StreamAsync(provider, document.RootElement.Clone(), approval, operation!.Token))
            if (ExternalRequestAdapter.String(item["type"]) == "response.output_text.delta") output.Text += ExternalRequestAdapter.String(item["delta"]);
        status.Text = "The explicit provider request completed.";
    }
    private void RefreshSaved() { loading = true; saved.ItemsSource = providers.ToArray(); saved.SelectedItem = current is null ? null : providers.FirstOrDefault(p => p.Id == current.Id); loading = false; }
    private void RefreshModels()
    {
        var provider = current; if (provider is null) return;
        models.ItemsSource = (provider.Models ?? []).Select(model => new ExternalModelRow(model, value => _ = UpdateModelAsync(model.Id, value))).ToArray();
        selectedModel.ItemsSource = (provider.Models ?? []).Where(model => model.Enabled).ToArray(); selectedModel.SelectedIndex = selectedModel.Items.Count > 0 ? 0 : -1;
    }
    private async Task UpdateModelAsync(string modelId, bool value)
    {
        try
        {
            if (current is null) return;
            current = current with { Models = (current.Models ?? []).Select(model => model.Id == modelId ? model with { Enabled = value } : model).ToArray() };
            await PersistCurrentAsync(); selectedModel.ItemsSource = (current.Models ?? []).Where(model => model.Enabled).ToArray(); selectedModel.SelectedIndex = selectedModel.Items.Count > 0 ? 0 : -1;
        }
        catch (Exception error) { ShowError(error); }
    }
    private async Task PersistCurrentAsync()
    {
        if (current is null) return; var index = providers.FindIndex(p => p.Id == current.Id);
        if (index < 0) providers.Add(current); else providers[index] = current;
        await configuration.SaveAsync(providers); RefreshSaved();
    }
    private void ActionButton(string label, Func<Task> action, bool allowBusy = false)
    { var button = new Button { Content = label }; body.Children.Add(button); button.Click += async (_, _) => { if (allowBusy) await action(); else await RunAsync(action); }; }
    private async Task RunAsync(Func<Task> action)
    {
        if (busy) return; busy = true; notice.IsOpen = false; operation?.Dispose(); operation = new();
        try { await action(); }
        catch (OperationCanceledException) { status.Text = "Provider request cancelled."; }
        catch (Exception error) { ShowError(error); }
        finally { busy = false; }
    }
    private void ShowError(Exception error) { notice.Title = "Provider action failed"; notice.Message = error.Message; notice.Severity = InfoBarSeverity.Error; notice.IsOpen = true; }
}
