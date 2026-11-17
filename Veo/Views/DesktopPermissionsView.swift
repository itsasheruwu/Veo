import AppKit
import SwiftUI

private enum PermissionsMetrics {
    // The reference uses a centered app icon above an inset list of permission rows.
    static let width: CGFloat = 344
    static let inset: CGFloat = 14
    static let iconSize: CGFloat = 48
    static let rowIconSize: CGFloat = 26
    static let actionWidth: CGFloat = 78
}

struct DesktopPermissionsView: View {
    static let width = PermissionsMetrics.width

    @ObservedObject var notifications: DesktopNotificationService
    @ObservedObject var audio: RealtimeAudioCoordinator
    let openSettings: () -> Void
    let close: () -> Void

    private var notificationsNeedSettings: Bool {
        notifications.authorizationState == .denied
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: PermissionsMetrics.iconSize, height: PermissionsMetrics.iconSize)
                    .accessibilityHidden(true)
                Text("Manage Permissions")
                    .font(.system(size: 18, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }

            VStack(spacing: 0) {
                permissionRow(
                    "Notifications",
                    detail: "Get an alert when work finishes or needs your attention.",
                    icon: "bell.badge",
                    status: notificationStatus,
                    retry: notifications.authorizationRequestFailed && !notificationsNeedSettings,
                    checking: !notifications.hasLoadedAuthorizationStatus && !notifications.authorizationRequestFailed,
                    granted: notifications.authorizationState == .allowed,
                    denied: notificationsNeedSettings,
                    requesting: notifications.isRequestingAuthorization
                ) {
                    if notificationsNeedSettings {
                        openSettings()
                        notifications.openSystemNotificationSettings()
                    } else {
                        notifications.requestPermission()
                    }
                }
                Divider().padding(.horizontal, 8)
                permissionRow(
                    "Microphone",
                    detail: "Speak to Codex when you start a realtime voice session.",
                    icon: "mic",
                    status: microphoneStatus,
                    granted: audio.microphonePermission == .granted,
                    denied: audio.microphonePermission == .denied,
                    requesting: audio.microphonePermission == .requesting
                ) {
                    if audio.microphonePermission == .denied {
                        openSettings()
                        audio.openMicrophoneSettings()
                    } else {
                        Task { await audio.requestMicrophonePermission() }
                    }
                }
            }
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.primary.opacity(0.08))
                    .allowsHitTesting(false)
            }

            Text("Both are optional. You can change access in System Settings.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, PermissionsMetrics.inset)
        .padding(.top, 23)
        .padding(.bottom, PermissionsMetrics.inset)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand(perform: close)
        .task {
            while !Task.isCancelled {
                audio.refreshMicrophonePermission()
                notifications.refreshAuthorizationStatus()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var notificationStatus: String {
        if notifications.isRequestingAuthorization { return "Waiting for macOS…" }
        if notifications.authorizationRequestFailed { return "Couldn’t request access" }
        if !notifications.hasLoadedAuthorizationStatus { return "Checking access…" }
        switch notifications.authorizationState {
        case .allowed: return "Allowed"
        case .denied: return "Off in System Settings"
        case .unknown: return "Not requested"
        }
    }

    private var microphoneStatus: String {
        switch audio.microphonePermission {
        case .granted: return "Allowed"
        case .denied: return "Off in System Settings"
        case .requesting: return "Waiting for macOS…"
        case .notDetermined: return "Not requested"
        }
    }

    private func permissionRow(
        _ title: String,
        detail: String,
        icon: String,
        status: String,
        retry: Bool = false,
        checking: Bool = false,
        granted: Bool,
        denied: Bool,
        requesting: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: PermissionsMetrics.rowIconSize, height: PermissionsMetrics.rowIconSize)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(status)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if granted {
                    Label("Granted", systemImage: "checkmark.circle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.green.opacity(0.12), in: Capsule())
                        .accessibilityLabel("\(title) granted")
                } else if requesting || checking {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(checking ? "Checking \(title) permission" : "Waiting for \(title) permission")
                } else {
                    Button(denied ? "Settings…" : retry ? "Try again…" : "Grant…", action: action)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .accessibilityLabel(denied ? "Open System Settings for \(title)" : retry ? "Retry \(title) permission" : "Grant \(title)")
                }
            }
            .frame(width: PermissionsMetrics.actionWidth, alignment: .trailing)
        }
        .padding(8)
    }
}
