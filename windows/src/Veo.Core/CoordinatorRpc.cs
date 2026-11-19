using System.Text.Json;
using Veo.Protocol;

namespace Veo.Core;

public interface ICoordinatorRpc
{
    long Generation { get; }
    bool Supports(string method);
    Task<JsonElement> RequestAsync(string method, object? parameters, CancellationToken token = default);
}
public sealed class WorkspaceCoordinatorRpc(WorkspaceCoordinator workspace) : ICoordinatorRpc
{
    public long Generation => workspace.Runtime.Generation;
    public bool Supports(string method) => workspace.Runtime.Capabilities.Availability(method) == CapabilityAvailability.Available;
    public Task<JsonElement> RequestAsync(string method, object? parameters, CancellationToken token = default) => workspace.Runtime.RequestAsync(method, parameters, token);
}
public static class ComposerProtocol
{
    public static object SandboxPolicy(string access, string cwd) => access switch
    {
        "Read only" => new { type = "readOnly", networkAccess = false },
        "Full access" => (object)new { type = "dangerFullAccess" },
        _ => new { type = "workspaceWrite", writableRoots = new[] { cwd }, networkAccess = false }
    };
    public static object[] Input(ComposerSnapshot payload)
    {
        var input = new List<object> { new { type = "text", text = payload.Text + (payload.VisionFallback is null ? "" : "\n\n" + payload.VisionFallback.ProtocolText) } };
        foreach (var attachment in Attachments(payload))
        {
            if (payload.VisionFallback is not null && attachment.Kind is ComposerAttachmentKind.LocalImage or ComposerAttachmentKind.Image) continue;
            input.Add(attachment.UserInput());
        }
        return input.ToArray();
    }
    public static IReadOnlyList<ComposerAttachment> Attachments(ComposerSnapshot payload) => payload.StructuredAttachments?.ToArray()
        ?? payload.Attachments.Select(path => new ComposerAttachment(ComposerAttachmentKind.LocalImage, path, Path.GetFileName(path))).ToArray();
}
