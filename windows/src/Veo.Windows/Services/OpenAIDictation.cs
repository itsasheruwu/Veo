using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;
using Veo.Platform.Windows.Security;

namespace Veo_Windows.Services;

internal static class OpenAIDictation
{
    public const string ModelName = "OpenAI";
    const string CredentialService = "Dictation/OpenAI";
    const string CredentialAccount = "api-key";
    static readonly CredentialManager Credentials = new(App.Workspace.DataRoot);
    static readonly HttpClient Client = new(new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false });

    public static string? ReadKey() => Credentials.Read(CredentialService, CredentialAccount)?.Secret;
    public static void SaveKey(string key) => Credentials.Save(CredentialService, CredentialAccount, key);
    public static void RemoveKey() => Credentials.Delete(CredentialService, CredentialAccount);

    public static async Task<string> TranscribeAsync(
        string path, string key, bool stream, Action<string> onPartial, CancellationToken token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.openai.com/v1/audio/transcriptions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        using var form = new MultipartFormDataContent();
        request.Content = form;
        form.Add(new StringContent("gpt-transcribe"), "model");
        if (stream) form.Add(new StringContent("true"), "stream");
        var audio = new StreamContent(File.OpenRead(path));
        audio.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        form.Add(audio, "file", "speech.wav");
        using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException(response.StatusCode switch
            {
                HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden => "OpenAI rejected the API key. Check the key in Voice settings.",
                HttpStatusCode.TooManyRequests => "OpenAI transcription reached a rate or usage limit. Check your OpenAI API account.",
                _ => $"OpenAI transcription failed (HTTP {(int)response.StatusCode})."
            });

        await using var body = await response.Content.ReadAsStreamAsync(token);
        if (!stream)
        {
            using var result = await JsonDocument.ParseAsync(body, cancellationToken: token);
            return ReadString(result.RootElement, "text") ?? throw Incomplete();
        }

        using var lines = new StreamReader(body);
        var partial = "";
        while (await lines.ReadLineAsync(token) is { } line)
        {
            if (!line.StartsWith("data:", StringComparison.Ordinal)) continue;
            var data = line[5..].Trim();
            if (data == "[DONE]") break;
            using var item = JsonDocument.Parse(data);
            switch (ReadString(item.RootElement, "type"))
            {
                case "transcript.text.delta":
                    partial += ReadString(item.RootElement, "delta") ?? "";
                    onPartial(partial);
                    break;
                case "transcript.text.done":
                    return ReadString(item.RootElement, "text") ?? throw Incomplete();
                case "error":
                    throw Incomplete();
            }
        }
        throw Incomplete();
    }

    static string? ReadString(JsonElement item, string property) =>
        item.ValueKind == JsonValueKind.Object && item.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;

    static InvalidOperationException Incomplete() => new("OpenAI did not return a complete transcript.");
}
