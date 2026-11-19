using System.Text.Json;
using System.Text.Json.Nodes;
using Veo.Infrastructure.Providers;
using Veo.Protocol;

namespace Veo.Core;

public sealed record ExternalProviderLaunchOverlay(IReadOnlyList<string> Arguments, IReadOnlyDictionary<string, string> EnvironmentOverrides,
    string CatalogPath, IReadOnlyList<ExternalRuntimeModel> Models);
public sealed record ExternalRuntimeModel(string CatalogId, string ProviderId, string RuntimeProviderId, string UpstreamModel,
    string DisplayName, long? ContextWindow, long? MaximumContextWindow);

/// <summary>Builds a temporary local launch overlay; never starts or owns Codex app-server.</summary>
public sealed class ExternalProviderRuntimeBridge : IAsyncDisposable
{
    readonly ExternalProviderService providers;
    readonly string directory;
    readonly Func<string, CancellationToken, Task<JsonElement>> readNativeCatalog;
    readonly SemaphoreSlim gate = new(1, 1);
    LocalProviderForwarder? forwarder;
    ExternalProviderLaunchOverlay? current;
    public ExternalProviderRuntimeBridge(ExternalProviderService providers, string dataRoot,
        Func<string, CancellationToken, Task<JsonElement>>? readNativeCatalog = null)
    {
        this.providers = providers;
        directory = Path.GetFullPath(Path.Combine(dataRoot, "Runtime", "ExternalModels"));
        this.readNativeCatalog = readNativeCatalog ?? CodexSelectedCliCatalog.ReadBundledAsync;
    }
    public ExternalProviderLaunchOverlay? Current => current;
    public string? ModelProviderFor(string? catalogModel) => current?.Models.FirstOrDefault(m => m.CatalogId == catalogModel)?.RuntimeProviderId;
    public void DisableProvider(string providerId) => forwarder?.DisableProvider(providerId);
    public async Task<ExternalProviderLaunchOverlay?> PrepareAsync(string selectedExecutable, IReadOnlyList<ExternalProvider> configurations,
        IReadOnlyCollection<string> currentNativeModelIds, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            if(forwarder is not null) { await forwarder.DisposeAsync(); forwarder = null; } current = null;
            var enabled = configurations.Where(p => p.Enabled && p.Models?.Any(m => m.Enabled) == true).ToArray();
            if(enabled.Length == 0) return null;
            if(currentNativeModelIds.Count == 0) throw new InvalidOperationException("Read the current native Codex model catalog before reconnecting with external providers.");
            var root = await readNativeCatalog(selectedExecutable, cancellationToken);
            var catalog = MergeCatalog(root, currentNativeModelIds, enabled);
            var launch = new LocalProviderForwarder(providers);
            try
            {
                var approvals = enabled.ToDictionary(p => p.Id, p => ProviderConsent.Approve(p, ProviderRequestPurpose.Inference), StringComparer.Ordinal);
                var bases = launch.Start(enabled, approvals);
                var rows = enabled.SelectMany(p => p.Models!.Where(m => m.Enabled).Select(m => new ExternalRuntimeModel(m.Id, p.Id, RuntimeProviderId(p.Id), m.UpstreamId, m.DisplayName, m.ContextWindow, m.MaximumContextWindow))).ToArray();
                Directory.CreateDirectory(directory);
                var path = Path.Combine(directory, "catalog-" + Guid.NewGuid().ToString("N") + ".json");
                await File.WriteAllTextAsync(path, catalog.ToJsonString(), cancellationToken);
                var args = new List<string>();
                foreach(var provider in enabled)
                {
                    var key = "model_providers." + RuntimeProviderId(provider.Id) + ".";
                    Add(args, key + "name", provider.Name + " (Veo local adapter)");
                    Add(args, key + "base_url", bases[provider.Id].AbsoluteUri.TrimEnd('/'));
                    Add(args, key + "env_key", launch.EnvironmentKey);
                    Add(args, key + "wire_api", "responses");
                    args.AddRange(["-c", key + "requires_openai_auth=false", "-c", key + "supports_websockets=false", "-c", key + "request_max_retries=0", "-c", key + "stream_max_retries=0"]);
                }
                Add(args, "model_catalog_json", path);
                forwarder = launch;
                current = new(args.ToArray(), launch.EnvironmentOverrides, path, rows);
                return current;
            }
            catch { await launch.DisposeAsync(); throw; }
        }
        finally { gate.Release(); }
    }
    public static string RuntimeProviderId(string providerId)
    {
        if(providerId.Length is <1 or >64 || providerId.Any(c => !char.IsAsciiLetterOrDigit(c) && c != '-') || !char.IsAsciiLetterOrDigit(providerId[0])) throw new ArgumentException("Invalid external provider identity.");
        return "veo-external-" + providerId;
    }
    static void Add(List<string> arguments, string key, string value) { arguments.Add("-c"); arguments.Add(key + "=" + JsonSerializer.Serialize(value)); }
    public static JsonObject MergeCatalog(JsonElement bundled, IReadOnlyCollection<string> nativeLiveIds, IReadOnlyList<ExternalProvider> enabled)
    {
        if(!bundled.TryGetProperty("models", out var native) || native.ValueKind != JsonValueKind.Array) throw new InvalidDataException("The selected CLI has no native catalog rows.");
        var ids = nativeLiveIds.ToHashSet(StringComparer.Ordinal);
        var rows = new JsonArray(); var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach(var row in native.EnumerateArray())
            if(row.TryGetProperty("slug",out var slug) && slug.ValueKind==JsonValueKind.String && ids.Contains(slug.GetString()!) && seen.Add(slug.GetString()!)) rows.Add(JsonNode.Parse(row.GetRawText()));
        // A local overlay may only preserve native entries proven available in the current runtime.
        if(rows.Count == 0) throw new InvalidDataException("No current native model matched the selected CLI's catalog. Recheck the CLI/account before enabling the external overlay.");
        foreach(var provider in enabled.Where(p=>p.Enabled))
        {
            _=provider.BaseUri; _=RuntimeProviderId(provider.Id);
            foreach(var model in (provider.Models??[]).Where(m=>m.Enabled))
            {
                if(model.Id != provider.Id+"/"+model.UpstreamId || !seen.Add(model.Id)) throw new InvalidDataException("An enabled external model has a duplicate or mismatched identity.");
                var entry=new JsonObject
                {
                    ["slug"]=model.Id,["display_name"]=model.DisplayName,["description"]="External "+provider.Name+" model, enabled in Veo.",
                    ["base_instructions"]="You are a coding assistant in Veo. Follow the user's instructions and repository guidance. Use the available tools accurately.",
                    ["supported_reasoning_levels"]=new JsonArray(),["shell_type"]="shell_command",["visibility"]="list",["supported_in_api"]=true,
                    ["priority"]=80,["support_verbosity"]=false,["truncation_policy"]=new JsonObject{["mode"]="tokens",["limit"]=10000},
                    ["experimental_supported_tools"]=new JsonArray(),["input_modalities"]=new JsonArray("text"),["multi_agent_version"]="disabled",
                    ["supports_search_tool"]=false,["model_messages"]=null,["service_tiers"]=new JsonArray(),["additional_speed_tiers"]=new JsonArray()
                };
                if(model.ContextWindow is >0)entry["context_window"]=model.ContextWindow.Value;
                if(model.MaximumContextWindow is >0)entry["max_context_window"]=model.MaximumContextWindow.Value;
                if(model.Metadata.ValueKind==JsonValueKind.Object)
                {
                    foreach(var key in new[]{"supported_reasoning_levels","service_tiers","input_modalities"})
                        if(model.Metadata.TryGetProperty(key,out var value)&&value.ValueKind==JsonValueKind.Array&&value.GetArrayLength()<=32)entry[key]=JsonNode.Parse(value.GetRawText());
                    if(model.Metadata.TryGetProperty("default_reasoning_level",out var effort)&&effort.ValueKind==JsonValueKind.String)entry["default_reasoning_level"]=effort.GetString();
                }
                rows.Add(entry);
            }
        }
        return new JsonObject{["models"]=rows};
    }
    public async ValueTask DisposeAsync()
    {
        await gate.WaitAsync();try{if(forwarder is not null)await forwarder.DisposeAsync();forwarder=null;current=null;}finally{gate.Release();}
    }
}
