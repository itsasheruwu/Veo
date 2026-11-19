using System.Text.Json;

namespace Veo.Protocol;

/// <summary>Frames bytes before decoding UTF-8, so arbitrary pipe boundaries cannot split text.</summary>
public sealed class NdjsonFramer(int maximumFrameBytes = 32 * 1024 * 1024) : IDisposable
{
    private readonly MemoryStream _pending = new();

    public IReadOnlyList<JsonElement> Append(ReadOnlySpan<byte> bytes)
    {
        var frames = new List<JsonElement>();
        while (!bytes.IsEmpty)
        {
            var delimiter = bytes.IndexOf((byte)'\n');
            var count = delimiter < 0 ? bytes.Length : delimiter;
            if (_pending.Length + count > maximumFrameBytes)
                throw new InvalidDataException($"Codex protocol frame exceeds {maximumFrameBytes} bytes.");
            _pending.Write(bytes[..count]);
            if (delimiter < 0) break;
            if (_pending.Length > 0)
            {
                var content = _pending.GetBuffer().AsSpan(0, checked((int)_pending.Length));
                if (content[^1] == '\r') content = content[..^1];
                if (!content.IsEmpty)
                {
                    using var document = JsonDocument.Parse(content.ToArray());
                    if (document.RootElement.ValueKind != JsonValueKind.Object)
                        throw new InvalidDataException("Codex stdout contained a non-object protocol frame.");
                    frames.Add(document.RootElement.Clone());
                }
            }
            _pending.SetLength(0);
            bytes = bytes[(delimiter + 1)..];
        }
        return frames;
    }

    public void Complete()
    {
        if (_pending.Length != 0) throw new EndOfStreamException("Codex stdout ended inside a JSON frame.");
    }

    public void Dispose() => _pending.Dispose();
}
