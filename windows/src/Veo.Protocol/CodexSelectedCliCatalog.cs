using System.Text.Json;
namespace Veo.Protocol;
/// <summary>Reads only the exact selected native CLI's bundled catalog; no server or network refresh.</summary>
public static class CodexSelectedCliCatalog
{
    public static async Task<JsonElement> ReadBundledAsync(string selectedExecutable, CancellationToken cancellationToken = default)
    {
        var executable=CodexExecutableDiscovery.Resolve(selectedExecutable)??throw new FileNotFoundException("The selected native Codex executable is unavailable.");
        var output=await CodexSchemaProbe.ReadBundledCatalogAsync(executable,cancellationToken);
        using var document=JsonDocument.Parse(output);
        if(document.RootElement.ValueKind!=JsonValueKind.Object||!document.RootElement.TryGetProperty("models",out var rows)||rows.ValueKind!=JsonValueKind.Array||rows.GetArrayLength()==0)throw new InvalidDataException("The selected Codex CLI returned no bundled model catalog.");
        return document.RootElement.Clone();
    }
}
