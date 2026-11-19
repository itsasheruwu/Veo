namespace Veo.Platform.Windows.Audio;

public static class Pcm16Packets
{
    /// <summary>Keep interleaved PCM16 channel frames intact when bounding playback writes.</summary>
    public static IEnumerable<ReadOnlyMemory<byte>> Split(ReadOnlyMemory<byte> data, int channels, int maximumBytes = 4096)
    {
        if (channels is < 1 or > 8 || maximumBytes < channels * 2 || data.Length % (channels * 2) != 0) throw new InvalidDataException("PCM16 packet contains incomplete channel frames.");
        var stride = maximumBytes / (channels * 2) * channels * 2;
        for (var position = 0; position < data.Length; position += stride) yield return data.Slice(position, Math.Min(stride, data.Length - position));
    }
}
