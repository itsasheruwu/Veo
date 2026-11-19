using System.Text.Json;
using System.Text.RegularExpressions;

namespace Veo.Infrastructure.Providers;

/// <summary>Only nonsecret configuration is written here. Credentials have a separate OS-protected owner.</summary>
public sealed class ProviderConfigurationStore(string dataRoot)
{
    private readonly string path = Path.Combine(dataRoot, "Settings", "providers.json");
    private readonly SemaphoreSlim gate = new(1, 1);
    public async Task<IReadOnlyList<ExternalProvider>> LoadAsync(CancellationToken token = default)
    {
        await gate.WaitAsync(token);
        try
        {
            if (!File.Exists(path)) return [];
            var providers = JsonSerializer.Deserialize<ExternalProvider[]>(await File.ReadAllTextAsync(path, token))
                ?? throw new InvalidDataException("The external-provider configuration is invalid; its file was preserved.");
            Validate(providers); return providers;
        }
        finally { gate.Release(); }
    }
    public async Task SaveAsync(IReadOnlyList<ExternalProvider> providers, CancellationToken token = default)
    {
        Validate(providers); await gate.WaitAsync(token);
        string? temporary = null;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(providers, new JsonSerializerOptions { WriteIndented = true }), token);
            File.Move(temporary, path, overwrite: true); temporary = null;
        }
        finally { if (temporary is not null && File.Exists(temporary)) File.Delete(temporary); gate.Release(); }
    }
    private static void Validate(IReadOnlyList<ExternalProvider> providers)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var provider in providers)
        {
            if (!Regex.IsMatch(provider.Id, "^[a-z0-9][a-z0-9-]{0,63}$", RegexOptions.CultureInvariant) || !ids.Add(provider.Id))
                throw new InvalidDataException("Provider identifiers must be unique lowercase names containing letters, numbers or hyphens.");
            _ = provider.BaseUri;
            if (string.IsNullOrWhiteSpace(provider.Name)) throw new InvalidDataException("Enter a provider name.");
            if ((provider.Models ?? []).Any(model => string.IsNullOrWhiteSpace(model.UpstreamId) || model.Id != provider.Id + "/" + model.UpstreamId))
                throw new InvalidDataException("A provider model has an invalid identity.");
        }
    }
}
