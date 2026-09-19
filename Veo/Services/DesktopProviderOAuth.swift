// FILE: DesktopProviderOAuth.swift
// Purpose: In-app device-code OAuth for Kimi Code and Grok, with Veo-owned token refresh.
// Layer: Desktop app service

import Foundation

struct DesktopOAuthToken: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var tokenType: String

    var isExpired: Bool {
        expiresAt.timeIntervalSinceNow < 60
    }

    var bearer: String { accessToken }
}

struct DesktopOAuthDeviceChallenge: Equatable, Sendable {
    var userCode: String
    var deviceCode: String
    var verificationURL: URL
    var interval: TimeInterval
    var expiresAt: Date
}

enum DesktopProviderOAuthError: LocalizedError {
    case unsupported
    case transport(String)
    case denied
    case expired
    case cancelled
    case missingToken

    var errorDescription: String? {
        switch self {
        case .unsupported: return "This provider does not support in-app OAuth."
        case .transport(let message): return message
        case .denied: return "Sign in was denied."
        case .expired: return "The sign-in code expired. Start again."
        case .cancelled: return "Sign in was cancelled."
        case .missingToken: return "Sign in before connecting this provider."
        }
    }
}

enum DesktopProviderOAuth {
    static func loadToken(providerID: String) -> DesktopOAuthToken? {
        guard let raw = DesktopProviderCredentialStore.key(providerID: providerID),
              let data = raw.data(using: .utf8),
              let token = try? JSONDecoder().decode(DesktopOAuthToken.self, from: data),
              !token.accessToken.isEmpty else {
            return nil
        }
        return token
    }

    @discardableResult
    static func saveToken(_ token: DesktopOAuthToken, providerID: String) -> Bool {
        guard let data = try? JSONEncoder().encode(token),
              let raw = String(data: data, encoding: .utf8) else {
            return false
        }
        return DesktopProviderCredentialStore.setKey(raw, providerID: providerID)
    }

    static func startDeviceLogin(preset: DesktopExternalProviderPreset) async throws -> DesktopOAuthDeviceChallenge {
        switch preset {
        case .kimiOAuth:
            return try await startKimiDeviceLogin()
        case .grokOAuth:
            return try await startGrokDeviceLogin()
        default:
            throw DesktopProviderOAuthError.unsupported
        }
    }

    static func pollDeviceLogin(
        preset: DesktopExternalProviderPreset,
        challenge: DesktopOAuthDeviceChallenge
    ) async throws -> DesktopOAuthToken {
        switch preset {
        case .kimiOAuth:
            return try await pollKimi(challenge)
        case .grokOAuth:
            return try await pollGrok(challenge)
        default:
            throw DesktopProviderOAuthError.unsupported
        }
    }

    static func validAccessToken(providerID: String, preset: DesktopExternalProviderPreset) async throws -> String {
        guard var token = loadToken(providerID: providerID) else {
            throw DesktopProviderOAuthError.missingToken
        }
        if token.isExpired {
            token = try await refresh(token, preset: preset)
            saveToken(token, providerID: providerID)
        }
        return token.accessToken
    }

    static func extraAPIHeaders(for preset: DesktopExternalProviderPreset) -> [String: String] {
        preset == .kimiOAuth ? kimiHeaders() : [:]
    }

    private static func refresh(
        _ token: DesktopOAuthToken,
        preset: DesktopExternalProviderPreset
    ) async throws -> DesktopOAuthToken {
        switch preset {
        case .kimiOAuth:
            return try await tokenRequest(
                url: URL(string: "https://auth.kimi.com/api/oauth/token")!,
                form: [
                    "grant_type": "refresh_token",
                    "refresh_token": token.refreshToken,
                    "client_id": kimiClientID,
                ],
                headers: kimiHeaders()
            )
        case .grokOAuth:
            return try await tokenRequest(
                url: URL(string: "https://auth.x.ai/oauth2/token")!,
                form: [
                    "grant_type": "refresh_token",
                    "refresh_token": token.refreshToken,
                    "client_id": grokClientID,
                ],
                headers: [:]
            )
        default:
            throw DesktopProviderOAuthError.unsupported
        }
    }

    private static let kimiClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    private static let grokClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    private static let grokScope = "openid profile email offline_access grok-cli:access api:access"

    private static func startKimiDeviceLogin() async throws -> DesktopOAuthDeviceChallenge {
        let object = try await formJSON(
            url: URL(string: "https://auth.kimi.com/api/oauth/device_authorization")!,
            form: ["client_id": kimiClientID],
            headers: kimiHeaders()
        )
        return try parseChallenge(object, defaultInterval: 5)
    }

    private static func startGrokDeviceLogin() async throws -> DesktopOAuthDeviceChallenge {
        let object = try await formJSON(
            url: URL(string: "https://auth.x.ai/oauth2/device/code")!,
            form: [
                "client_id": grokClientID,
                "scope": grokScope,
            ],
            headers: [:]
        )
        return try parseChallenge(object, defaultInterval: 5)
    }

    private static func pollKimi(_ challenge: DesktopOAuthDeviceChallenge) async throws -> DesktopOAuthToken {
        try await poll(
            url: URL(string: "https://auth.kimi.com/api/oauth/token")!,
            form: [
                "client_id": kimiClientID,
                "device_code": challenge.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ],
            headers: kimiHeaders(),
            challenge: challenge
        )
    }

    private static func pollGrok(_ challenge: DesktopOAuthDeviceChallenge) async throws -> DesktopOAuthToken {
        try await poll(
            url: URL(string: "https://auth.x.ai/oauth2/token")!,
            form: [
                "client_id": grokClientID,
                "device_code": challenge.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ],
            headers: [:],
            challenge: challenge
        )
    }

    private static func poll(
        url: URL,
        form: [String: String],
        headers: [String: String],
        challenge: DesktopOAuthDeviceChallenge
    ) async throws -> DesktopOAuthToken {
        var interval = max(challenge.interval, 2)
        while Date() < challenge.expiresAt {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(interval))
            try Task.checkCancellation()
            let (object, status) = try await formJSONStatus(url: url, form: form, headers: headers)
            if (200..<300).contains(status), object["access_token"] as? String != nil {
                return try decodeToken(object)
            }
            let error = (object["error"] as? String) ?? ""
            switch error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
            case "access_denied":
                throw DesktopProviderOAuthError.denied
            case "expired_token":
                throw DesktopProviderOAuthError.expired
            default:
                if status == 400 || status == 401 || status == 403 {
                    let description = (object["error_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw DesktopProviderOAuthError.transport(description?.nilIfEmpty ?? "Sign in failed (\(status)).")
                }
            }
        }
        throw DesktopProviderOAuthError.expired
    }

    private static func parseChallenge(_ object: [String: Any], defaultInterval: Int) throws -> DesktopOAuthDeviceChallenge {
        let userCode = (object["user_code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let deviceCode = (object["device_code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let complete = (object["verification_uri_complete"] as? String)
            ?? (object["verification_uri"] as? String)
            ?? ""
        guard !userCode.isEmpty, !deviceCode.isEmpty, let url = URL(string: complete), url.scheme == "https" else {
            throw DesktopProviderOAuthError.transport("The provider did not return a sign-in address.")
        }
        let expires = (object["expires_in"] as? Int) ?? 900
        let interval = (object["interval"] as? Int) ?? defaultInterval
        return DesktopOAuthDeviceChallenge(
            userCode: userCode,
            deviceCode: deviceCode,
            verificationURL: url,
            interval: TimeInterval(max(interval, 2)),
            expiresAt: Date().addingTimeInterval(TimeInterval(expires))
        )
    }

    private static func tokenRequest(
        url: URL,
        form: [String: String],
        headers: [String: String]
    ) async throws -> DesktopOAuthToken {
        let object = try await formJSON(url: url, form: form, headers: headers)
        return try decodeToken(object)
    }

    private static func decodeToken(_ object: [String: Any]) throws -> DesktopOAuthToken {
        guard let access = object["access_token"] as? String, !access.isEmpty else {
            throw DesktopProviderOAuthError.transport("Sign in did not return an access token.")
        }
        let refresh = (object["refresh_token"] as? String) ?? ""
        let expiresIn = (object["expires_in"] as? Int) ?? 3600
        return DesktopOAuthToken(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(TimeInterval(max(expiresIn, 60))),
            tokenType: (object["token_type"] as? String) ?? "Bearer"
        )
    }

    private static func formJSON(
        url: URL,
        form: [String: String],
        headers: [String: String]
    ) async throws -> [String: Any] {
        let (object, status) = try await formJSONStatus(url: url, form: form, headers: headers)
        guard (200..<300).contains(status) else {
            let description = (object["error_description"] as? String)
                ?? (object["error"] as? String)
                ?? "HTTP \(status)"
            throw DesktopProviderOAuthError.transport(description)
        }
        return object
    }

    private static func formJSONStatus(
        url: URL,
        form: [String: String],
        headers: [String: String]
    ) async throws -> ([String: Any], Int) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Veo", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = form
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return (object, status)
    }

    private static func kimiHeaders() -> [String: String] {
        [
            "User-Agent": "Veo",
            "X-Msh-Platform": "veo",
            "X-Msh-Version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            "X-Msh-Device-Name": asciiOnly(Host.current().localizedName ?? "Mac"),
            "X-Msh-Device-Model": "macOS",
            "X-Msh-Os-Version": asciiOnly(ProcessInfo.processInfo.operatingSystemVersionString),
            "X-Msh-Device-Id": kimiDeviceID(),
        ]
    }

    private static func kimiDeviceID() -> String {
        let url = DesktopExternalModelCatalog.directoryURL.appendingPathComponent("kimi-device-id", isDirectory: false)
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fresh.write(to: url, atomically: true, encoding: .utf8)
        return fresh
    }

    private static func asciiOnly(_ value: String) -> String {
        let filtered = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7E }
        let result = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "unknown" : result
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
