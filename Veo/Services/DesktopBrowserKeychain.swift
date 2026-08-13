// FILE: DesktopBrowserKeychain.swift
// Purpose: Save and fill website passwords via iCloud Keychain, and request passkey access for WKWebView.
// Layer: Desktop app service

import AppKit
import AuthenticationServices
import Foundation
import Security

enum DesktopBrowserPasskeyAccess: String {
    case authorized
    case denied
    case notDetermined
    case unavailable

    var title: String {
        switch self {
        case .authorized: return "Allowed"
        case .denied: return "Blocked"
        case .notDetermined: return "Not requested"
        case .unavailable: return "Unavailable"
        }
    }
}

struct DesktopBrowserStoredPassword: Equatable {
    var server: String
    var account: String
    var password: String
    var port: Int?
    var usesTLS: Bool
}

enum DesktopBrowserKeychain {
    static func passkeyAccess() -> DesktopBrowserPasskeyAccess {
        switch ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    static func requestPasskeyAccess() async -> DesktopBrowserPasskeyAccess {
        let state = await ASAuthorizationWebBrowserPublicKeyCredentialManager()
            .requestAuthorizationForPublicKeyCredentials()
        switch state {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unavailable
        }
    }

    static func requestPasskeyAccessIfNeeded() {
        guard passkeyAccess() == .notDetermined else { return }
        Task { @MainActor in
            _ = await requestPasskeyAccess()
        }
    }

    static func passwords(for url: URL) -> [DesktopBrowserStoredPassword] {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return [] }
        let port = url.port
        let usesTLS = url.scheme?.lowercased() != "http"
        var seen = Set<String>()
        var matches: [DesktopBrowserStoredPassword] = []
        for server in serverCandidates(host) {
            for item in copyInternetPasswords(server: server, port: port, usesTLS: usesTLS) {
                let key = item.account.lowercased()
                guard seen.insert(key).inserted else { continue }
                matches.append(item)
            }
        }
        return matches
    }

    @discardableResult
    static func save(_ password: DesktopBrowserStoredPassword) -> Bool {
        let server = password.server.lowercased()
        let account = password.account
        guard !server.isEmpty, !account.isEmpty, !password.password.isEmpty,
              let secret = password.password.data(using: .utf8) else { return false }

        var query: [String: Any] = baseQuery(server: server, port: password.port, usesTLS: password.usesTLS)
        query[kSecAttrAccount as String] = account
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        let attributes: [String: Any] = [
            kSecValueData as String: secret,
            kSecAttrLabel as String: server,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
        }

        var item = query
        item[kSecClass as String] = kSecClassInternetPassword
        item[kSecAttrSynchronizable as String] = kCFBooleanTrue
        item.merge(attributes) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func respond(
        to challenge: URLAuthenticationChallenge,
        window: NSWindow?
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            return (.performDefaultHandling, nil)
        case NSURLAuthenticationMethodClientCertificate:
            return clientCertificateResponse(for: challenge, window: window)
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM,
             NSURLAuthenticationMethodNegotiate,
             NSURLAuthenticationMethodDefault:
            return passwordChallengeResponse(for: challenge, window: window)
        default:
            return (.performDefaultHandling, nil)
        }
    }

    private static func passwordChallengeResponse(
        for challenge: URLAuthenticationChallenge,
        window: NSWindow?
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        if challenge.previousFailureCount == 0 {
            if let proposed = challenge.proposedCredential, proposed.hasPassword {
                return (.useCredential, proposed)
            }
            if let stored = URLCredentialStorage.shared.defaultCredential(for: space), stored.hasPassword {
                return (.useCredential, stored)
            }
            if let host = space.host.nonempty,
               let match = passwords(for: space.url ?? URL(string: "https://\(host)")!).first {
                let credential = URLCredential(user: match.account, password: match.password, persistence: .forSession)
                return (.useCredential, credential)
            }
        }

        guard let credentials = promptForPassword(space: space, window: window) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        if credentials.remember {
            URLCredentialStorage.shared.set(credentials.credential, for: space)
            if let host = space.host.nonempty {
                save(
                    DesktopBrowserStoredPassword(
                        server: host,
                        account: credentials.credential.user ?? "",
                        password: credentials.credential.password ?? "",
                        port: space.port == 0 ? nil : space.port,
                        usesTLS: space.`protocol` == "https"
                    )
                )
            }
        }
        return (.useCredential, credentials.credential)
    }

    private static func clientCertificateResponse(
        for challenge: URLAuthenticationChallenge,
        window: NSWindow?
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let identities = copyIdentities()
        guard !identities.isEmpty else { return (.performDefaultHandling, nil) }
        if identities.count == 1 {
            return (.useCredential, URLCredential(identity: identities[0].identity, certificates: nil, persistence: .forSession))
        }
        let names = identities.map(\.name)
        let alert = NSAlert()
        alert.messageText = "Choose a certificate"
        alert.informativeText = "\(challenge.protectionSpace.host) requested a client certificate from Keychain."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 24), pullsDown: false)
        names.forEach { popup.addItem(withTitle: $0) }
        alert.accessoryView = popup
        alert.window.initialFirstResponder = popup
        _ = window
        guard alert.runModal() == .alertFirstButtonReturn else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let index = max(popup.indexOfSelectedItem, 0)
        let identity = identities[min(index, identities.count - 1)].identity
        return (.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
    }

    private static func promptForPassword(
        space: URLProtectionSpace,
        window: NSWindow?
    ) -> (credential: URLCredential, remember: Bool)? {
        let alert = NSAlert()
        alert.messageText = "Sign in to \(space.host)"
        alert.informativeText = space.realm.flatMap(\.nonempty).map { "The site asked for a password for “\($0)”." }
            ?? "Enter the username and password stored in Keychain, or a new login to save."
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 78))
        let userField = NSTextField(string: "")
        userField.placeholderString = "Username"
        userField.frame = NSRect(x: 0, y: 54, width: 320, height: 24)
        let passwordField = NSSecureTextField(string: "")
        passwordField.placeholderString = "Password"
        passwordField.frame = NSRect(x: 0, y: 26, width: 320, height: 24)
        let remember = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
        remember.state = .on
        remember.frame = NSRect(x: 0, y: 2, width: 320, height: 18)
        container.addSubview(userField)
        container.addSubview(passwordField)
        container.addSubview(remember)
        alert.accessoryView = container
        alert.window.initialFirstResponder = userField
        _ = window
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = passwordField.stringValue
        guard !user.isEmpty, !password.isEmpty else { return nil }
        let persistence: URLCredential.Persistence = remember.state == .on ? .permanent : .forSession
        return (URLCredential(user: user, password: password, persistence: persistence), remember.state == .on)
    }

    private static func copyInternetPasswords(server: String, port: Int?, usesTLS: Bool) -> [DesktopBrowserStoredPassword] {
        var query = baseQuery(server: server, port: port, usesTLS: usesTLS)
        query[kSecClass as String] = kSecClassInternetPassword
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let account = (item[kSecAttrAccount as String] as? String)?.nonempty,
                  let data = item[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8)?.nonempty else { return nil }
            let storedPort = item[kSecAttrPort as String] as? Int
            return DesktopBrowserStoredPassword(
                server: server,
                account: account,
                password: password,
                port: storedPort == 0 ? nil : storedPort,
                usesTLS: usesTLS
            )
        }
    }

    private static func copyIdentities() -> [(identity: SecIdentity, name: String)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [Any] else { return [] }
        return items.compactMap { item -> (identity: SecIdentity, name: String)? in
            guard CFGetTypeID(item as CFTypeRef) == SecIdentityGetTypeID() else { return nil }
            let identity = item as! SecIdentity
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            let name = certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Keychain certificate"
            return (identity, name)
        }
    }

    private static func baseQuery(server: String, port: Int?, usesTLS: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecAttrServer as String: server,
            kSecAttrProtocol as String: usesTLS ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP,
        ]
        if let port, port > 0 {
            query[kSecAttrPort as String] = port
        }
        return query
    }

    private static func serverCandidates(_ host: String) -> [String] {
        var values = [host]
        if host.hasPrefix("www.") {
            values.append(String(host.dropFirst(4)))
        } else {
            values.append("www." + host)
        }
        return values
    }
}

extension DesktopBrowserKeychain {
    static let captureScript = """
    (() => {
      if (window.__veoKeychainInstalled) return;
      window.__veoKeychainInstalled = true;

      const post = (payload) => {
        try { window.webkit.messageHandlers.veoKeychain.postMessage(payload); } catch (_) {}
      };

      const meta = (el) => ((el.getAttribute('autocomplete') || '') + ' ' + (el.name || '') + ' ' + (el.id || '')).toLowerCase();
      const visible = (el) => !!(el && el.offsetParent !== null && !el.disabled && !el.readOnly);
      const skipPassword = (el) => {
        const text = meta(el);
        return text.includes('cc-') || text.includes('card-number') || text.includes('cvv');
      };

      const usernameFrom = (root, passwordEl) => {
        const nodes = Array.from((root || document).querySelectorAll('input:not([type="hidden"]):not([type="password"]):not([type="submit"]):not([type="button"]):not([type="checkbox"]):not([type="radio"])')).filter(visible);
        return nodes.find((el) => {
          const type = (el.getAttribute('type') || 'text').toLowerCase();
          const text = meta(el);
          return type === 'email' || el.autocomplete === 'username' || text.includes('user') || text.includes('email') || text.includes('login');
        }) || nodes[0];
      };

      const reportFocus = () => post({ type: 'focus', host: location.hostname });
      const reportSubmit = (root) => {
        const password = Array.from((root || document).querySelectorAll('input[type="password"]')).find((el) => visible(el) && el.value && !skipPassword(el));
        if (!password) return;
        const user = usernameFrom(password.form || root, password);
        if (!user || !user.value) return;
        post({ type: 'submit', host: location.hostname, account: user.value, password: password.value });
      };

      window.__veoFillCredentials = (payload) => {
        const password = Array.from(document.querySelectorAll('input[type="password"]')).find(visible);
        if (!password) return false;
        const setValue = (el, value) => {
          if (!el) return;
          const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto, 'value') && Object.getOwnPropertyDescriptor(proto, 'value').set;
          if (setter) setter.call(el, value); else el.value = value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        };
        const user = usernameFrom(password.form || document, password);
        if (payload.username) setValue(user, payload.username);
        setValue(password, payload.password || '');
        password.focus();
        return true;
      };

      document.addEventListener('focusin', (event) => {
        const el = event.target;
        if (!(el instanceof HTMLInputElement)) return;
        const type = (el.type || '').toLowerCase();
        if (type === 'password' || type === 'email' || el.autocomplete === 'username') reportFocus();
      }, true);

      document.addEventListener('submit', (event) => {
        if (event.target instanceof HTMLFormElement) reportSubmit(event.target);
      }, true);

      document.addEventListener('click', (event) => {
        const button = event.target && event.target.closest && event.target.closest('button, input[type="submit"]');
        if (!button) return;
        const type = (button.getAttribute('type') || (button.tagName === 'BUTTON' ? 'submit' : '')).toLowerCase();
        if (button.tagName === 'BUTTON' && type === 'button') {
          const label = ((button.textContent || '') + ' ' + (button.getAttribute('aria-label') || '')).toLowerCase();
          if (!/(sign[ -]?in|log[ -]?in|continue|next|submit|authenticate)/.test(label)) return;
        }
        reportSubmit(button.closest('form') || document);
      }, true);
    })();
    """
}

private final class DesktopBrowserPasswordPicker: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static var active: DesktopBrowserPasswordPicker?

    let window: NSWindow?
    let completion: (ASPasswordCredential?) -> Void

    init(window: NSWindow?, completion: @escaping (ASPasswordCredential?) -> Void) {
        self.window = window
        self.completion = completion
    }

    func start() {
        let request = ASAuthorizationPasswordProvider().createRequest()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        Self.active = self
        controller.performRequests()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        if let window { return window }
        if let keyWindow = NSApp.keyWindow { return keyWindow }
        if let first = NSApp.windows.first { return first }
        return NSWindow()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        completion(authorization.credential as? ASPasswordCredential)
        Self.active = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        completion(nil)
        Self.active = nil
    }
}

extension DesktopBrowserKeychain {
    static func requestSystemPassword(window: NSWindow?, completion: @escaping (ASPasswordCredential?) -> Void) {
        DesktopBrowserPasswordPicker(window: window, completion: completion).start()
    }
}

private extension String {
    var nonempty: String? { isEmpty ? nil : self }
}

private extension URLProtectionSpace {
    var url: URL? {
        var components = URLComponents()
        components.scheme = `protocol`
        components.host = host
        if port > 0 { components.port = port }
        return components.url
    }
}
