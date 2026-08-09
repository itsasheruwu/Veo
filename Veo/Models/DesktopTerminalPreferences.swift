// FILE: DesktopTerminalPreferences.swift
// Purpose: Persisted docked-terminal preferences and Agent CLI PATH wrappers.
// Layer: Desktop app model

import Foundation

enum DesktopTerminalPreferences {
    static let agentCLIsEnabledKey = "VeoDesktop.agentCLIsEnabled"
    static let yoloModeKey = "VeoDesktop.agentCLIsYoloMode"
    static let yoloClaudeKey = "VeoDesktop.agentCLIsYoloClaude"
    static let yoloCodexKey = "VeoDesktop.agentCLIsYoloCodex"

    /// CLI names that require Agent CLIs consent in the docked terminal.
    static let gatedAgentCLINames: Set<String> = ["claude", "codex"]

    private static let defaults = UserDefaults.standard

    static var agentCLIsEnabled: Bool {
        defaults.bool(forKey: agentCLIsEnabledKey)
    }

    static func setAgentCLIsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: agentCLIsEnabledKey)
    }

    /// True when the shell line would launch a gated agent CLI (`claude`, `codex`, …).
    static func commandInvokesAgentCLI(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Strip simple env assignments: FOO=bar claude …
        var tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = tokens.first, first.contains("="), !first.hasPrefix("-") {
            tokens.removeFirst()
        }
        guard let raw = tokens.first else { return false }

        let command = raw.split(separator: "/").last.map(String.init) ?? raw
        return gatedAgentCLINames.contains(command.lowercased())
    }

    /// Adds the selected yolo flag to a direct Agent CLI command after the login shell
    /// has finished rewriting PATH. Returns the original line when no rewrite applies.
    static func commandLineApplyingYoloMode(_ line: String) -> String {
        guard yoloModeEnabled else { return line }

        let pattern = #"^(\s*(?:[A-Za-z_][A-Za-z0-9_]*=[^\s]+\s+)*)([^\s]+)(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..., in: line)
              ),
              let commandRange = Range(match.range(at: 2), in: line),
              let suffixRange = Range(match.range(at: 3), in: line) else {
            return line
        }

        let command = String(line[commandRange])
        let commandName = command.split(separator: "/").last.map(String.init)?.lowercased() ?? command.lowercased()
        let suffix = String(line[suffixRange])

        let flag: String
        switch commandName {
        case "claude" where yoloClaudeEnabled:
            flag = "--dangerously-skip-permissions"
        case "codex" where yoloCodexEnabled:
            flag = "--dangerously-bypass-approvals-and-sandbox"
        default:
            return line
        }

        guard !suffix.split(whereSeparator: \.isWhitespace).contains(Substring(flag)) else {
            return line
        }
        return line[..<commandRange.upperBound] + " " + flag + suffix
    }

    static var yoloModeEnabled: Bool {
        agentCLIsEnabled && defaults.bool(forKey: yoloModeKey)
    }

    static var yoloClaudeEnabled: Bool {
        yoloModeEnabled && defaults.object(forKey: yoloClaudeKey) as? Bool ?? true
    }

    static var yoloCodexEnabled: Bool {
        yoloModeEnabled && defaults.object(forKey: yoloCodexKey) as? Bool ?? true
    }

    /// Application Support bin dir prepended to PATH when wrappers are active.
    static var agentCLIBinDirectory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root
            .appendingPathComponent("com.ash.Veo", isDirectory: true)
            .appendingPathComponent("TerminalAgentCLIs", isDirectory: true)
    }

    /// Ensures wrapper scripts match current prefs. Returns the bin path to prepend, if any.
    @discardableResult
    static func syncAgentCLIWrappers() -> URL? {
        let fm = FileManager.default
        let bin = agentCLIBinDirectory
        try? fm.createDirectory(at: bin, withIntermediateDirectories: true)

        var activeNames: [String] = []
        if yoloClaudeEnabled {
            writeWrapper(
                named: "claude",
                in: bin,
                extraArguments: ["--dangerously-skip-permissions"]
            )
            activeNames.append("claude")
        } else {
            try? fm.removeItem(at: bin.appendingPathComponent("claude"))
        }

        if yoloCodexEnabled {
            writeWrapper(
                named: "codex",
                in: bin,
                extraArguments: ["--dangerously-bypass-approvals-and-sandbox"]
            )
            activeNames.append("codex")
        } else {
            try? fm.removeItem(at: bin.appendingPathComponent("codex"))
        }

        return activeNames.isEmpty ? nil : bin
    }

    private static func writeWrapper(named name: String, in directory: URL, extraArguments: [String]) {
        let url = directory.appendingPathComponent(name)
        let quotedExtras = extraArguments
            .map { arg in
                "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            .joined(separator: " ")
        let script = """
        #!/bin/zsh
        emulate -L zsh
        bin_dir=${0:A:h}
        path=(${path:#$bin_dir})
        hash -r
        if ! real=$(command -v \(name)); then
          print -u2 "\(name): command not found"
          exit 127
        fi
        exec "$real" \(quotedExtras) "$@"
        """
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path
            )
        } catch {
            // Best-effort; terminal still works without wrappers.
        }
    }
}
