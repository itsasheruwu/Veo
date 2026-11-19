using System.Text.Json;
using Veo.Platform.Windows.Security;

namespace Veo.Platform.Windows.Browser;
public sealed record BrowserCredentialIdentity(string Origin, string Account, string Kind, string Realm);
/// <summary>Only identities are indexed on disk. Secrets stay in current-user Credential Manager.</summary>
public sealed class BrowserCredentialStore
{
    readonly CredentialManager credentials;
    readonly string path;
    readonly SemaphoreSlim writer = new(1, 1);
    public BrowserCredentialStore(string dataRoot)
    {
        credentials = new CredentialManager("Browser-" + BrowserOrigin.Key(Path.GetFullPath(dataRoot).ToUpperInvariant()));
        path = Path.Combine(dataRoot, "Browser", "credential-identities.json");
    }

    public async Task<IReadOnlyList<BrowserCredentialIdentity>> ListAsync(Uri origin, string kind = "Form", string realm = "")
    {
        ValidateKind(kind);
        var expected = BrowserOrigin.Of(origin);
        var all = await LoadAsync();
        return all.Where(x => x.Origin == expected && x.Kind == kind && x.Realm == realm).ToArray();
    }

    public async Task SaveAsync(Uri origin, string account, string secret, bool explicitlyConfirmed, string kind = "Form", string realm = "")
    {
        if (!explicitlyConfirmed)
            throw new InvalidOperationException("A native save confirmation is required.");
        ValidateKind(kind);
        if (account.Length is 0 or > 512 || realm.Length > 2048)
            throw new ArgumentException("Credential identity exceeds its limit.");
        var identity = new BrowserCredentialIdentity(BrowserOrigin.Of(origin), account, kind, realm);
        await writer.WaitAsync();
        try
        {
            var all = await LoadAsync();
            credentials.Save(Service(identity), account, secret);
            if (!all.Contains(identity))
                all.Add(identity);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(all));
                File.Move(temporary, path, true);
            }
            finally
            {
                if (File.Exists(temporary))
                    File.Delete(temporary);
            }
        }
        finally
        {
            writer.Release();
        }
    }

    public StoredCredential? Read(BrowserCredentialIdentity identity, Uri currentOrigin)
    {
        if (identity.Origin != BrowserOrigin.Of(currentOrigin))
            throw new InvalidOperationException("The credential belongs to another origin.");
        ValidateKind(identity.Kind);
        return credentials.Read(Service(identity), identity.Account);
    }

    public async Task DeleteAsync(BrowserCredentialIdentity identity)
    {
        await writer.WaitAsync();
        try
        {
            credentials.Delete(Service(identity), identity.Account);
            var all = await LoadAsync();
            all.RemoveAll(x => x == identity);
            if (File.Exists(path))
                await File.WriteAllTextAsync(path, JsonSerializer.Serialize(all));
        }
        finally
        {
            writer.Release();
        }
    }

    async Task<List<BrowserCredentialIdentity>> LoadAsync()
    {
        if (!File.Exists(path))
            return[];
        if (new FileInfo(path).Length > 1024 * 1024)
            throw new InvalidDataException("Browser credential identities exceed the limit.");
        return JsonSerializer.Deserialize<List<BrowserCredentialIdentity>>(await File.ReadAllTextAsync(path)) ?? [];
    }

    static string Service(BrowserCredentialIdentity identity) => "Browser/" + BrowserOrigin.Key(identity.Origin + "\n" + identity.Kind + "\n" + identity.Realm);
    static void ValidateKind(string kind)
    {
        if (kind is not ("Form" or "Http"))
            throw new ArgumentException("Unknown browser credential kind.");
    }
}
