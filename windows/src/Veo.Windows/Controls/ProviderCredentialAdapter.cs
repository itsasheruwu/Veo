using System.Text;
using System.Text.Json;
using Veo.Infrastructure.Providers;
using Veo.Platform.Windows.Security;

namespace Veo_Windows.Controls;

/// <summary>Chunked OS-protected entries accommodate OAuth tokens beyond CredWrite's per-entry limit.</summary>
public sealed class ProviderCredentialAdapter(string profile) : IProviderSecretStore
{
    private readonly CredentialManager credentials = new(profile);
    private readonly SemaphoreSlim gate = new(1, 1);
    private sealed record Manifest(int Version, string Generation, int Count);
    public async ValueTask<string?> ReadAsync(string key, CancellationToken token = default)
    {
        await gate.WaitAsync(token);
        try
        {
            var manifest = ReadManifest(key); if (manifest is null) return null;
            var secret = new StringBuilder();
            for (var part = 0; part < manifest.Count; part++)
                secret.Append(credentials.Read("ExternalProvider", PartKey(key, manifest.Generation, part))?.Secret ?? throw new InvalidDataException("The provider credential is incomplete. Reconnect this provider."));
            return secret.ToString();
        }
        finally { gate.Release(); }
    }
    public async ValueTask SaveAsync(string key, string secret, CancellationToken token = default)
    {
        if (secret.Length > 128000) throw new ArgumentException("The provider credential exceeds the supported size.");
        await gate.WaitAsync(token);
        try
        {
            var chunks = new List<string>();
            for (var position = 0; position < secret.Length;)
            {
                var length = Math.Min(500, secret.Length - position);
                if (position + length < secret.Length && char.IsHighSurrogate(secret[position + length - 1]) && char.IsLowSurrogate(secret[position + length])) length--;
                chunks.Add(secret.Substring(position, length)); position += length;
            }
            if (chunks.Count == 0) chunks.Add("");
            if (chunks.Count > 256) throw new ArgumentException("The provider credential exceeds the supported chunk count.");
            var previous = ReadManifest(key); var generation = Guid.NewGuid().ToString("N"); var count = chunks.Count; var written = 0; var committed = false;
            try
            {
                for (var part = 0; part < count; part++)
                { token.ThrowIfCancellationRequested(); credentials.Save("ExternalProvider", PartKey(key, generation, part), chunks[part]); written++; }
                credentials.Save("ExternalProvider", key, JsonSerializer.Serialize(new Manifest(1, generation, count))); committed = true;
            }
            finally
            {
                if (!committed)
                    for (var part = 0; part < written; part++) credentials.Delete("ExternalProvider", PartKey(key, generation, part));
            }
            if (previous is not null)
                for (var part = 0; part < previous.Count; part++) credentials.Delete("ExternalProvider", PartKey(key, previous.Generation, part));
        }
        finally { gate.Release(); }
    }
    public async ValueTask DeleteAsync(string key, CancellationToken token = default)
    {
        await gate.WaitAsync(token);
        try
        {
            var manifest = ReadManifest(key); credentials.Delete("ExternalProvider", key);
            if (manifest is not null) for (var part = 0; part < manifest.Count; part++) credentials.Delete("ExternalProvider", PartKey(key, manifest.Generation, part));
        }
        finally { gate.Release(); }
    }
    private Manifest? ReadManifest(string key)
    {
        var stored = credentials.Read("ExternalProvider", key); if (stored is null) return null;
        Manifest? manifest;
        try { manifest = JsonSerializer.Deserialize<Manifest>(stored.Secret); }
        catch (JsonException) { throw new InvalidDataException("The provider credential is unreadable. Reconnect this provider."); }
        if (manifest is null || manifest.Version != 1 || manifest.Count is < 1 or > 256 || !Guid.TryParseExact(manifest.Generation, "N", out _))
            throw new InvalidDataException("The provider credential is invalid. Reconnect this provider.");
        return manifest;
    }
    private static string PartKey(string key, string generation, int part) => key + "/" + generation + "/" + part;
}
