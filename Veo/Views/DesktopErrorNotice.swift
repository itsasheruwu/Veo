// FILE: DesktopErrorNotice.swift
// Purpose: Gives timeline and composer errors consistent, visible recovery and feedback.
// Layer: Desktop app view

import SwiftUI

struct DesktopErrorNotice: View {
    @Bindable var store: DesktopCodexStore
    var item: DesktopTimelineItem?
    @State private var showsRestoreConfirmation = false

    private var message: String { item?.body ?? store.visibleTransientError ?? "" }
    private var recovery: DesktopErrorRecoveryAction? { store.errorRecoveryAction(for: item) }
    private var isAutomaticallyRetrying: Bool {
        item?.status == "retrying" && store.isBusyTurn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    if let title = item?.title, !title.isEmpty {
                        Text(title).fontWeight(.semibold)
                    }
                    Text(message)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isAutomaticallyRetrying {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Codex is retrying…").foregroundStyle(.secondary)
                }
            } else if let recovery {
                if !showsRestoreConfirmation, let detail = store.errorRecoveryDetail(for: recovery) {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button {
                        guard store.performErrorRecovery(recovery) else { return }
                        if case .restoreMessage = recovery {
                            showsRestoreConfirmation = true
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if store.errorRecoveryActionInFlight == recovery {
                                ProgressView().controlSize(.mini)
                            }
                            Text(store.errorRecoveryActionInFlight == recovery ? recovery.progressTitle : recovery.title)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!store.canPerformErrorRecovery(recovery))
                    .help(recovery.help)
                    .accessibilityHint(recovery.help)

                    if showsRestoreConfirmation {
                        Label("Restored to composer", systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .onChange(of: item?.id) { _, _ in showsRestoreConfirmation = false }
    }
}
