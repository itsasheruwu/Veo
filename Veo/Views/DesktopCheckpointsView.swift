import SwiftUI

struct DesktopCheckpointsView: View {
    @Bindable var store: DesktopCodexStore
    @Environment(\.dismiss) private var dismiss
    @State private var library = DesktopCheckpointLibrary.shared
    @State private var selected: DesktopWorkspaceCheckpoint?
    @State private var isBusy = false
    @State private var message: String?
    private let git = LocalGitService()

    private var checkpoints: [DesktopWorkspaceCheckpoint] {
        library.checkpoints.filter { $0.workspacePath == store.effectiveWorkspaceURL.path }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Workspace checkpoints").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.disabled(isBusy).keyboardShortcut(.cancelAction)
            }
            Text("Restore files and staging without changing conversation history. A recovery copy is saved before each restore. Ignored files are left alone.")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            if isBusy { ProgressView().controlSize(.small) }
            if checkpoints.isEmpty {
                ContentUnavailableView("No checkpoints yet", systemImage: "clock.arrow.circlepath", description: Text("Checkpoints are saved before supported Codex turns. Older and queued turns may not have a checkpoint."))
            } else {
                List(checkpoints) { checkpoint in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(checkpoint.payloadID.hasPrefix("recovery-") ? "Recovery checkpoint" : "Before turn")
                                .fontWeight(.medium)
                            Text(checkpoint.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                            Text(checkpoint.filesRef).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Restore files…") { selected = checkpoint }
                            .disabled(isBusy || !store.canRestoreCheckpoint(checkpoint))
                    }.padding(.vertical, 5)
                }
            }
        }.padding(22).frame(width: 610, height: 420)
        .confirmationDialog("Restore this checkpoint's workspace files and staging?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), presenting: selected) { checkpoint in
            Button("Restore files", role: .destructive) { restore(checkpoint) }
            Button("Cancel", role: .cancel) { selected = nil }
        } message: { checkpoint in
            Text("Tracked and nonignored files in \(checkpoint.workspacePath) return to their state at \(checkpoint.createdAt.formatted()). New files are removed after a recovery checkpoint is saved. Conversation history is unchanged.")
        }
    }

    private func restore(_ checkpoint: DesktopWorkspaceCheckpoint) {
        guard store.canRestoreCheckpoint(checkpoint) else { return }
        isBusy = true; message = nil
        store.isRestoringCheckpoint = true
        Task {
            defer { isBusy = false; store.isRestoringCheckpoint = false }
            do {
                let backup = try await git.captureCheckpoint(workspace: URL(fileURLWithPath: checkpoint.workspacePath), threadID: checkpoint.threadID, payloadID: "recovery-" + UUID().uuidString)
                library.save(backup)
                try await git.restoreCheckpoint(checkpoint, recovery: backup)
                message = "Files and staging restored. The previous state is available as a recovery checkpoint."
                store.refreshGitRepository()
            } catch { message = "Restore did not complete: " + error.localizedDescription + " Any saved recovery checkpoint is listed here." }
        }
    }
}
