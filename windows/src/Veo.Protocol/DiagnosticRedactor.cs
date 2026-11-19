using System.Text.RegularExpressions;

namespace Veo.Protocol;

public static partial class DiagnosticRedactor
{
    [GeneratedRegex("(?i)(bearer\\s+)[A-Za-z0-9._~+/=-]+")]
    private static partial Regex Bearer();
    [GeneratedRegex("(?i)((?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|authorization|client[_-]?secret)[\\\"']?\\s*[:=]\\s*[\\\"']?)[^\\s\\\"',;}]+")]
    private static partial Regex NamedSecret();
    [GeneratedRegex("\\b(?:sk|ghp|gho|github_pat)-?[A-Za-z0-9_]{16,}\\b")]
    private static partial Regex Token();
    [GeneratedRegex("(?i)(VEO_LOOPBACK_TOKEN_[A-F0-9]{32}[\\\"']?\\s*[:=]\\s*[\\\"']?)[A-F0-9]{64}")]
    private static partial Regex LoopbackCapability();

    public static string Redact(string text) => LoopbackCapability().Replace(Token().Replace(NamedSecret().Replace(Bearer().Replace(text, "$1[redacted]"), "$1[redacted]"), "[redacted]"), "$1[redacted]");
}
