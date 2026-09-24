// FILE: DesktopExternalModelCatalog.swift
// Purpose: Probes providers, writes a Veo-owned model catalog, and builds app-server -c/env overlays.
// Layer: Desktop app service

import Foundation

struct CodexAppServerLaunchOverlay: Equatable {
    var arguments: [String]
    var environment: [String: String]
    var catalogURL: URL
}

enum DesktopExternalModelCatalogError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case emptyCatalog
    case unreadableResponse
    case missingCodex
    case catalogWrite(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The provider URL is not valid."
        case .httpStatus(let code):
            return "The provider returned HTTP \(code)."
        case .emptyCatalog:
            return "The provider did not list any models for this key."
        case .unreadableResponse:
            return "The provider returned an unreadable model list."
        case .missingCodex:
            return "Codex CLI was not found, so Veo could not build a native catalog snapshot."
        case .catalogWrite(let message):
            return message
        }
    }
}

enum DesktopExternalModelCatalog {
    private static let fileManager = FileManager.default

    static var directoryURL: URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return root.appendingPathComponent("com.ash.Veo/ExternalModels", isDirectory: true)
    }

    static var catalogURL: URL {
        directoryURL.appendingPathComponent("catalog.json", isDirectory: false)
    }

    @MainActor
    static func launchOverlay() async throws -> CodexAppServerLaunchOverlay? {
        let preferences = DesktopModelCatalogPreferences.shared
        let providers = preferences.providers
        let published = externalModelsForOverlay(
            enabledModels: preferences.publishedExternalModels,
            providers: providers
        )

        var environment: [String: String] = [:]
        var arguments: [String] = []
        let publishedIDs = Set(published.map(\.id))
        let connected = providers.filter { provider in
            provider.models.contains { $0.enabled && publishedIDs.contains($0.id) }
        }
        let oauthBases = try DesktopOAuthForwarder.shared.prepare(providers: connected)
        for provider in connected {
            let credential: String
            if provider.authKind == .oauth {
                credential = try await DesktopProviderOAuth.validAccessToken(
                    providerID: provider.id,
                    preset: provider.preset ?? .custom
                )
            } else if let key = DesktopProviderCredentialStore.key(providerID: provider.id), !key.isEmpty {
                credential = key
            } else {
                continue
            }
            environment[provider.envKey] = credential
            let baseURL = oauthBases[provider.id] ?? provider.baseURL
            arguments += tomlString("model_providers.\(provider.id).name", provider.name)
            arguments += tomlString("model_providers.\(provider.id).base_url", baseURL)
            arguments += tomlString("model_providers.\(provider.id).env_key", provider.envKey)
            arguments += tomlString("model_providers.\(provider.id).wire_api", provider.wireAPI.rawValue)
            arguments += tomlBool("model_providers.\(provider.id).requires_openai_auth", false)
        }
        guard connected.isEmpty || !environment.isEmpty else {
            throw DesktopExternalModelCatalogError.catalogWrite(
                "An external provider is enabled but its credential is missing from Keychain."
            )
        }

        let url = try await Task.detached(priority: .userInitiated) {
            try writeMergedCatalog(published: published, providers: providers)
        }.value
        arguments += tomlString("model_catalog_json", url.path)
        return CodexAppServerLaunchOverlay(arguments: arguments, environment: environment, catalogURL: url)
    }

    static func probe(provider: DesktopConnectedProvider, apiKey: String) async throws -> [DesktopExternalModelRecord] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw DesktopExternalModelCatalogError.emptyCatalog }
        let modelsURL = try modelsEndpoint(from: provider.baseURL)
        var request = URLRequest(url: modelsURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Veo", forHTTPHeaderField: "User-Agent")
        if provider.usesAnthropicAuth {
            request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }
        if let preset = provider.preset {
            for (name, value) in DesktopProviderOAuth.extraAPIHeaders(for: preset) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            if let fallback = fallbackRecords(for: provider), !fallback.isEmpty {
                return fallback
            }
            throw DesktopExternalModelCatalogError.httpStatus(status)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DesktopExternalModelCatalogError.unreadableResponse
        }
        let rows = object["data"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        var models: [DesktopExternalModelRecord] = rows.compactMap { row in
            guard let upstream = row["id"] as? String, !upstream.isEmpty, seen.insert(upstream).inserted else {
                return nil
            }
            let catalogID = DesktopConnectedProvider.catalogModelID(providerID: provider.id, upstreamID: upstream)
            let rawDisplay = (row["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? humanize(upstream)
            let display = DesktopModelOption.displayNameForUser(
                id: catalogID,
                model: upstream,
                fallback: rawDisplay.isEmpty ? upstream : rawDisplay
            )
            return DesktopExternalModelRecord(
                id: catalogID,
                upstreamID: upstream,
                displayName: display,
                enabled: false,
                contextWindow: contextWindow(from: row),
                maxContextWindow: maximumContextWindow(from: row)
            )
        }
        if provider.preset == .grokOAuth, seen.insert("grok-4.7").inserted {
            let upstreamID = "grok-4.7"
            let catalogID = DesktopConnectedProvider.catalogModelID(
                providerID: provider.id,
                upstreamID: upstreamID
            )
            models.append(
                DesktopExternalModelRecord(
                    id: catalogID,
                    upstreamID: upstreamID,
                    displayName: DesktopModelOption.displayNameForUser(
                        id: catalogID,
                        model: upstreamID,
                        fallback: "4.7 Grok"
                    ),
                    enabled: false
                )
            )
        }
        if models.isEmpty, let fallback = fallbackRecords(for: provider), !fallback.isEmpty {
            return fallback
        }
        guard !models.isEmpty else { throw DesktopExternalModelCatalogError.emptyCatalog }
        return models.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func fallbackRecords(for provider: DesktopConnectedProvider) -> [DesktopExternalModelRecord]? {
        guard let fallback = provider.preset?.fallbackModels, !fallback.isEmpty else { return nil }
        return fallback.map { item in
            DesktopExternalModelRecord(
                id: DesktopConnectedProvider.catalogModelID(providerID: provider.id, upstreamID: item.id),
                upstreamID: item.id,
                displayName: item.name,
                enabled: false
            )
        }
    }

    private static func contextWindow(from row: [String: Any]) -> Int? {
        positiveInteger(row["context_window"] ?? row["context_length"])
    }

    private static func maximumContextWindow(from row: [String: Any]) -> Int? {
        positiveInteger(row["max_context_window"] ?? row["max_context_length"])
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let integer = number.intValue
        return integer > 0 && NSNumber(value: integer) == number ? integer : nil
    }

    private static func writeMergedCatalog(
        published: [DesktopExternalModelRecord],
        providers: [DesktopConnectedProvider]
    ) throws -> URL {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var root = try nativeCatalogRoot()
        var models = root["models"] as? [[String: Any]] ?? []
        var existing = Set(models.compactMap { $0["slug"] as? String })
        for index in models.indices {
            let slug = (models[index]["slug"] as? String ?? "").lowercased()
            if slug.contains("gpt-6-astra") {
                models[index]["visibility"] = "list"
            }
        }
        guard let template = models.first(where: { ($0["visibility"] as? String) == "list" }) ?? models.first else {
            throw DesktopExternalModelCatalogError.catalogWrite("The native Codex catalog has no models to clone.")
        }
        if let gpt6Template = models.first(where: { ($0["slug"] as? String) == "gpt-6-astra" }) {
            for (slug, title) in [("gpt-6-sol", "Sol"), ("gpt-6-luna", "Luna")] where !existing.contains(slug) {
                var entry = gpt6Template
                entry["slug"] = slug
                entry["display_name"] = "GPT-6-\(title)"
                entry["description"] = "GPT-6 \(title), available with Standard and Fast processing."
                entry["visibility"] = "list"
                entry["supported_in_api"] = true
                entry["default_reasoning_level"] = "medium"
                entry["supported_reasoning_levels"] = gpt6ReasoningLevels
                entry["additional_speed_tiers"] = ["fast"]
                entry["service_tiers"] = [openAIFastServiceTier]
                entry["model_messages"] = NSNull()
                entry["availability_nux"] = NSNull()
                entry["upgrade"] = NSNull()
                models.append(entry)
                existing.insert(slug)
            }
        }
        if let solIndex = models.firstIndex(where: {
            canonicalModelID($0["slug"] as? String ?? "") == "gpt-6-sol"
        }) {
            var reasoningLevels = models[solIndex]["supported_reasoning_levels"] as? [Any]
                ?? gpt6ReasoningLevels.map { $0 as [String: Any] }
            let alreadySupportsUltra = reasoningLevels.contains { level in
                guard let level = level as? [String: Any],
                      let effort = level["effort"] as? String else {
                    return false
                }
                return effort.caseInsensitiveCompare("ultra") == .orderedSame
            }
            if !alreadySupportsUltra {
                reasoningLevels.append([
                    "effort": "ultra",
                    "description": "Maximum reasoning with automatic task delegation.",
                ])
            }
            models[solIndex]["supported_reasoning_levels"] = reasoningLevels
        }
        let providerByModelID = Dictionary(
            uniqueKeysWithValues: providers.flatMap { provider in
                provider.models.map { ($0.id, provider) }
            }
        )
        for record in published where !existing.contains(record.id) {
            models.append(
                clonedCatalogEntry(
                    from: template,
                    record: record,
                    provider: providerByModelID[record.id]
                )
            )
        }
        root["models"] = models
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: catalogURL, options: .atomic)
        return catalogURL
    }

    private static func externalModelsForOverlay(
        enabledModels: [DesktopExternalModelRecord],
        providers: [DesktopConnectedProvider]
    ) -> [DesktopExternalModelRecord] {
        var result = enabledModels.filter { !isGrok47Fast($0.upstreamID) }
        let includedIDs = Set(result.map(\.id))
        for provider in providers {
            for base in provider.models where base.enabled && isGrok47(base.upstreamID) {
                guard let fast = provider.models.first(where: { isGrok47Fast($0.upstreamID) }),
                      includedIDs.contains(base.id),
                      !includedIDs.contains(fast.id) else { continue }
                var companion = fast
                companion.enabled = true
                result.append(companion)
            }
        }
        return result
    }

    private static var nativeCatalogCacheURL: URL {
        directoryURL.appendingPathComponent("native-catalog.json", isDirectory: false)
    }

    private static func nativeCatalogRoot() throws -> [String: Any] {
        if let cached = cachedNativeCatalog() {
            return cached
        }
        guard let executable = CodexAppServerClient.resolveCodexExecutable() else {
            throw DesktopExternalModelCatalogError.missingCodex
        }
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = ["debug", "models", "--bundled"]
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment
        do {
            try process.run()
        } catch {
            throw DesktopExternalModelCatalogError.catalogWrite("Could not read the native Codex catalog.")
        }
        // Drain both pipes while the process runs. The bundled catalog is large
        // enough to fill a pipe and deadlock waitUntilExit if we read after exit.
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading
        let group = DispatchGroup()
        var output = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            output = stdoutHandle.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            _ = stderrHandle.readDataToEndOfFile()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              object["models"] != nil else {
            throw DesktopExternalModelCatalogError.catalogWrite("The native Codex catalog could not be parsed.")
        }
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? output.write(to: nativeCatalogCacheURL, options: .atomic)
        return object
    }

    private static func cachedNativeCatalog() -> [String: Any]? {
        guard let executable = CodexAppServerClient.resolveCodexExecutable() else { return nil }
        let cache = nativeCatalogCacheURL
        guard fileManager.fileExists(atPath: cache.path) else { return nil }
        let cacheDate = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let binaryDate = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
        guard cacheDate >= binaryDate else { return nil }
        guard let data = try? Data(contentsOf: cache),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["models"] != nil else {
            return nil
        }
        return object
    }

    private static func clonedCatalogEntry(
        from template: [String: Any],
        record: DesktopExternalModelRecord,
        provider: DesktopConnectedProvider?
    ) -> [String: Any] {
        let displayName = DesktopModelOption.displayNameForUser(
            id: record.id,
            model: record.upstreamID,
            fallback: record.displayName
        )
        let providerName = provider?.name ?? displayName
        let reasoning = reasoningProfile(for: record.upstreamID)
        var entry = template
        entry["slug"] = record.id
        entry["display_name"] = displayName
        entry["description"] = "External \(providerName) model, connected only in Veo."
        entry["visibility"] = "list"
        entry["supported_in_api"] = true
        entry["default_reasoning_level"] = reasoning.defaultEffort
        entry["supported_reasoning_levels"] = reasoning.levels
        entry["service_tiers"] = grok47FastTier(for: record, provider: provider).map { [$0] } ?? []
        entry["additional_speed_tiers"] = []
        entry["base_instructions"] = """
        You are \(displayName), a coding assistant in Veo. Follow the user's instructions \
        and the repository's project guidance. Do not claim to be a GPT model.
        """
        entry["model_messages"] = NSNull()
        entry["multi_agent_version"] = "disabled"
        entry["supports_search_tool"] = false
        entry["upgrade"] = NSNull()
        entry["availability_nux"] = NSNull()
        if let limits = record.reliableContextLimits {
            if let suggested = limits.suggested { entry["context_window"] = suggested }
            entry["max_context_window"] = limits.maximum
        }
        if entry["priority"] is Int { entry["priority"] = 80 }
        return entry
    }

    /// Codex does not expose these limits through model/list. Read the same
    /// bundled catalog already used to build Veo's local model overlay.
    static func nativeContextLimits() -> [String: DesktopContextWindowLimits] {
        guard let root = try? nativeCatalogRoot(),
              let rows = root["models"] as? [[String: Any]] else { return [:] }
        var result: [String: DesktopContextWindowLimits] = [:]
        for row in rows {
            guard let slug = row["slug"] as? String,
                  let suggested = positiveInteger(row["context_window"]),
                  let maximum = positiveInteger(row["max_context_window"]),
                  let limits = DesktopContextWindowLimits(suggested: suggested, maximum: maximum) else { continue }
            result[slug] = limits
        }
        return result
    }

    private static let openAIFastServiceTier: [String: String] = [
        "id": "priority",
        "name": "Fast",
        "description": "Fast processing; uses more of your limits.",
    ]

    private static let gpt6ReasoningLevels: [[String: String]] = [
        ["effort": "none", "description": "No reasoning effort."],
        ["effort": "low", "description": "Some reasoning, still fast."],
        ["effort": "medium", "description": "More thinking for harder work."],
        ["effort": "high", "description": "Deeper reasoning for complex problems."],
        ["effort": "xhigh", "description": "Extra reasoning depth for complex problems."],
        ["effort": "max", "description": "Maximum reasoning depth."],
    ]

    private static func grok47FastTier(
        for record: DesktopExternalModelRecord,
        provider: DesktopConnectedProvider?
    ) -> [String: String]? {
        guard isGrok47(record.upstreamID),
              let provider,
              provider.preset == .grokOAuth else {
            return nil
        }
        let fastModel = provider.models.first(where: { isGrok47Fast($0.upstreamID) })?.upstreamID
            ?? "grok-4.7-fast"
        return [
            "id": "model-variant:\(provider.id):\(fastModel)",
            "name": "Fast",
            "description": "Use the Grok 4.7 Fast model variant.",
        ]
    }

    private static func isGrok47(_ upstreamID: String) -> Bool {
        canonicalModelID(upstreamID) == "grok-4.7"
    }

    private static func isGrok47Fast(_ upstreamID: String) -> Bool {
        canonicalModelID(upstreamID) == "grok-4.7-fast"
    }

    private static func canonicalModelID(_ value: String) -> String {
        value.lowercased().split(separator: "/").last.map(String.init) ?? value.lowercased()
    }

    private static func reasoningProfile(for upstreamID: String) -> (defaultEffort: String, levels: [[String: String]]) {
        let id = upstreamID.lowercased()
        let low = ["effort": "low", "description": "Some reasoning, still fast."]
        let medium = ["effort": "medium", "description": "More thinking for harder work."]
        let high = ["effort": "high", "description": "Deeper reasoning for complex problems."]
        let xhigh = ["effort": "xhigh", "description": "Maximum reasoning depth."]
        if id.contains("grok-4.7") || id.contains("grok-4-7") {
            return ("high", [low, medium, high, xhigh])
        }
        if id.contains("grok-4.6") || id.contains("grok-4-6") {
            return ("high", [low, medium, high, xhigh])
        }
        if id.contains("grok-4.5") || id.contains("grok-4-5") || id.hasPrefix("grok-") {
            return ("high", [low, medium, high])
        }
        return ("medium", [low, medium, high])
    }

    private static func modelsEndpoint(from baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/models"), url.scheme == "https" || isLoopback(url) else {
            throw DesktopExternalModelCatalogError.invalidURL
        }
        return url
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        let host = url.host?.lowercased() ?? ""
        return host == "127.0.0.1" || host == "localhost" || host == "[::1]"
    }

    private static func humanize(_ id: String) -> String {
        id.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "_" })
            .map { part in
                let value = String(part)
                if value.allSatisfy(\.isNumber) || value.contains(where: \.isNumber) { return value }
                return value.prefix(1).uppercased() + value.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func tomlString(_ key: String, _ value: String) -> [String] {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return ["-c", "\(key)=\"\(escaped)\""]
    }

    private static func tomlBool(_ key: String, _ value: Bool) -> [String] {
        ["-c", "\(key)=\(value)"]
    }
}
