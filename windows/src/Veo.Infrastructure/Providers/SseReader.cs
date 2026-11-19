using System.Runtime.CompilerServices;
using System.Text;

namespace Veo.Infrastructure.Providers;

public sealed record SseEvent(string? Event, string Data, string? Id);
public static class SseReader
{
    /// <summary>Strict incremental UTF-8 decoding with bounds applied before allocating a complete line/event.</summary>
    public static async IAsyncEnumerable<SseEvent> ReadAsync(Stream stream, int maximumEventCharacters = 4 * 1024 * 1024,
        [EnumeratorCancellation] CancellationToken token = default)
    {
        using var reader = new StreamReader(stream, new UTF8Encoding(false, true), detectEncodingFromByteOrderMarks: true, 8192, leaveOpen: true);
        var data = new StringBuilder(); string? eventName = null, id = null;
        await foreach (var line in LinesAsync(reader, maximumEventCharacters, token))
        {
            if (line.Length > maximumEventCharacters || data.Length + line.Length > maximumEventCharacters)
                throw new InvalidDataException("The provider sent an event larger than the supported bound.");
            if (line.Length == 0)
            {
                if (data.Length > 0) { data.Length--; yield return new(eventName, data.ToString(), id); }
                data.Clear(); eventName = null; continue;
            }
            if (line[0] == ':') continue;
            var separator = line.IndexOf(':'); var name = separator < 0 ? line : line[..separator];
            var value = separator < 0 ? "" : line[(separator + 1)..]; if (value.StartsWith(' ')) value = value[1..];
            if (name == "data") data.Append(value).Append('\n');
            else if (name == "event") eventName = value;
            else if (name == "id" && !value.Contains('\0')) id = value;
        }
        if (data.Length > 0) { data.Length--; yield return new(eventName, data.ToString(), id); }
    }
    private static async IAsyncEnumerable<string> LinesAsync(StreamReader reader, int maximum,
        [EnumeratorCancellation] CancellationToken token)
    {
        var buffer = new char[8192]; var line = new StringBuilder(); var afterCarriageReturn = false;
        while (await reader.ReadAsync(buffer.AsMemory(), token) is var count && count > 0)
            for (var i = 0; i < count; i++)
            {
                var character = buffer[i];
                if (character == '\n' && afterCarriageReturn) { afterCarriageReturn = false; continue; }
                if (character is '\r' or '\n')
                { yield return line.ToString(); line.Clear(); afterCarriageReturn = character == '\r'; continue; }
                afterCarriageReturn = false;
                if (line.Length >= maximum) throw new InvalidDataException("The provider sent a line larger than the supported event bound.");
                line.Append(character);
            }
        if (line.Length > 0) yield return line.ToString();
    }
}
