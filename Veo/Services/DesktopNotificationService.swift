// FILE: DesktopNotificationService.swift
// Purpose: Delivers system alerts, in-app warnings, and sounds for agent activity.
// Layer: Desktop app service
// Depends on: AppKit, UserNotifications

import AppKit
import UserNotifications

private final class DesktopNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Alerts are never enqueued for the chat already on screen, so anything
        // reaching this delegate is useful even while another Veo chat is active.
        completionHandler([.banner])
    }
}

/// Notifies the user about work that finished or needs them outside the chat they
/// are watching. The timeline remains the better signal for the selected chat.
@MainActor
final class DesktopNotificationService: ObservableObject {
    enum AuthorizationState: Equatable {
        case unknown
        case allowed
        case denied
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let detail: String
    }

    enum Alert {
        case turnCompleted(threadTitle: String)
        case turnFailed(threadTitle: String, message: String)
        case attentionNeeded(threadTitle: String, detail: String)

        var title: String {
            switch self {
            case .turnCompleted(let threadTitle): return threadTitle
            case .turnFailed(let threadTitle, _): return threadTitle
            case .attentionNeeded(let threadTitle, _): return threadTitle
            }
        }

        var body: String {
            switch self {
            case .turnCompleted: return "Codex finished this turn."
            case .turnFailed(_, let message): return message
            case .attentionNeeded(_, let detail): return detail
            }
        }
    }

    @Published private(set) var authorizationState: AuthorizationState = .unknown
    @Published private(set) var toast: Toast?

    private var hasRequestedAuthorization = false
    private var toastTask: Task<Void, Never>?
    private let centerDelegate = DesktopNotificationCenterDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = centerDelegate
    }

    /// Asks for notification permission once, lazily, so a user who never enables
    /// alerts is never prompted.
    func prepareIfNeeded() {
        guard DesktopNotificationPreferences.systemAlertsEnabled,
              !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        requestAuthorization(delivering: nil)
    }

    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.authorizationState = Self.authorizationState(for: settings.authorizationStatus)
            }
        }
    }

    /// Posts an alert for work the user is not currently watching.
    ///
    /// `isForegroundThread` is true when the originating chat is both selected and
    /// on screen, in which case a banner would only repeat what the timeline shows.
    func post(_ alert: Alert, isForegroundThread: Bool) {
        let isActive = NSApp.isActive && isForegroundThread
        guard !isActive else { return }

        if DesktopNotificationPreferences.completionSoundEnabled {
            playSound()
        }

        guard DesktopNotificationPreferences.systemAlertsEnabled else { return }
        deliverWhenAuthorized(alert)
    }

    func playSound() {
        DesktopNotificationPreferences.resolvedSound()?.play()
    }

    func showWarning(title: String, detail: String) {
        guard DesktopNotificationPreferences.inAppWarningsEnabled else { return }
        let boundedDetail = detail.count > 240 ? String(detail.prefix(239)) + "…" : detail
        let nextToast = Toast(title: title, detail: boundedDetail)
        toastTask?.cancel()
        toast = nextToast
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            guard self?.toast?.id == nextToast.id else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        toast = nil
    }

    func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func deliverWhenAuthorized(_ alert: Alert) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                self.authorizationState = Self.authorizationState(for: settings.authorizationStatus)
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    self.deliver(alert)
                case .notDetermined:
                    self.requestAuthorization(delivering: alert)
                case .denied:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func requestAuthorization(delivering alert: Alert?) {
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.authorizationState = granted ? .allowed : .denied
                if granted, let alert { self.deliver(alert) }
            }
        }
    }

    private func deliver(_ alert: Alert) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    private static func authorizationState(
        for status: UNAuthorizationStatus
    ) -> AuthorizationState {
        switch status {
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }
}
