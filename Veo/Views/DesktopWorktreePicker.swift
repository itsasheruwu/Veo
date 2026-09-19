import AppKit
import SwiftUI

struct DesktopWorktreePicker: View {
    @Bindable var store: DesktopCodexStore
    let projectURL: URL
    let runSetup: (DesktopProjectAction, URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.veoAccent) private var accent
    @State private var worktrees: [DesktopWorktree] = []
    @State private var bases: [String] = []
    @State private var base = "HEAD"
    @State private var branch = ""
    @State private var customDestination: URL?
    @State private var selectedPath: String?
    @State private var createsNew = true
    @State private var error: String?
    @State private var isLoading = true
    @State private var isBusy = false
    @State private var runSetupActions = false
    private let git = LocalGitService()

    private var branchName: String { branch.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var destination: URL {
        customDestination ?? projectURL.deletingLastPathComponent().appendingPathComponent(
            projectURL.lastPathComponent + "-" + branchName.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
    }
    private var setup: [DesktopProjectAction] {
        DesktopProjectPreferences.shared.configuration(for: projectURL.path).actions.filter(\.runOnWorktreeCreate)
    }
    private var validation: String? {
        if branchName.isEmpty { return "Enter a name for the new branch." }
        if bases.contains(branchName) { return "That branch already exists. Choose a new name, or open an existing worktree." }
        if branchName.hasPrefix("-") || branchName.hasSuffix("/") || branchName.contains("..")
            || branchName.contains(where: { $0.isWhitespace || "~^:?*[\\".contains($0) }) {
            return "Use a branch name without spaces or Git special characters, such as codex/settings-fix."
        }
        if FileManager.default.fileExists(atPath: destination.path) { return "That folder already exists. Change the branch name or choose another location." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Worktrees").font(.title2.weight(.semibold))
                Text("Work on a task in a separate folder, with its own branch.")
                    .foregroundStyle(.secondary)
                Text(projectURL.lastPathComponent).font(.caption.weight(.medium))
                    .help(projectURL.path)
            }
            Picker("Worktree", selection: $createsNew) {
                Text("New worktree").tag(true)
                Text("Existing worktrees").tag(false)
            }.pickerStyle(.segmented).disabled(isBusy)

            Group {
                if isLoading {
                    ProgressView("Loading worktrees…").frame(maxWidth: .infinity, minHeight: 260)
                } else if createsNew {
                    creationForm
                } else {
                    existingWorktrees
                }
            }.disabled(isBusy)

            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                if isBusy {
                    ProgressView().controlSize(.small)
                    Text("Creating worktree…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.disabled(isBusy)
                Button(createsNew ? "Create & start chat" : "Start chat here") {
                    if createsNew { create() } else if let selectedPath { open(path: selectedPath) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading || isBusy || (createsNew ? validation != nil : selectedPath == nil))
            }
        }
        .padding(24).frame(width: 560)
        .interactiveDismissDisabled(isBusy)
        .task { await load() }
    }

    private var creationForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New branch").font(.subheadline.weight(.medium))
                TextField("codex/settings-fix", text: $branch)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("New branch")
                Text("Give this task a short name. Veo chooses a matching folder automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Start from", selection: $base) {
                Text("Project’s current commit (HEAD)").tag("HEAD")
                ForEach(bases, id: \.self) { Text($0).tag($0) }
            }
            Text("The new folder starts from the selected commit. Uncommitted edits stay in their current folder.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Location").font(.subheadline.weight(.medium))
                    Spacer()
                    if customDestination != nil {
                        Button("Use suggested") { customDestination = nil }
                    }
                    Button("Change…") { chooseDestination() }
                }
                Text(destination.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let validation {
                Text(validation).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !setup.isEmpty {
                Toggle("Run project setup", isOn: $runSetupActions)
                Text(setup.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            Text("Opens a new chat in this worktree. Your current chat stays in its original folder.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var existingWorktrees: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a folder for a new chat.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(worktrees) { tree in
                        Button { selectedPath = tree.path; error = nil } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(tree.branch ?? "Detached HEAD").fontWeight(.medium)
                                        if URL(fileURLWithPath: tree.path).resolvingSymlinksInPath() == store.effectiveWorkspaceURL.resolvingSymlinksInPath() {
                                            Text("Current folder").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(tree.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 8)
                                if selectedPath == tree.path { Image(systemName: "checkmark").foregroundStyle(accent) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(selectedPath == tree.path ? accent.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedPath == tree.path ? .isSelected : [])
                    }
                }
            }.frame(height: 260)
            Text("Each chat keeps its own working folder when you switch between chats.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        do {
            worktrees = try await git.worktrees(at: projectURL)
            bases = try await git.worktreeBaseBranches(at: projectURL)
            selectedPath = worktrees.first(where: {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == store.effectiveWorkspaceURL.resolvingSymlinksInPath()
            })?.path ?? worktrees.first?.path
            var number = 1
            while true {
                let candidate = "codex/task-\(number)"
                let folder = projectURL.deletingLastPathComponent().appendingPathComponent(projectURL.lastPathComponent + "-" + candidate.replacingOccurrences(of: "/", with: "-"))
                if !bases.contains(candidate), !FileManager.default.fileExists(atPath: folder.path) { branch = candidate; break }
                number += 1
            }
        } catch { self.error = error.localizedDescription }
        isLoading = false
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "New worktree folder"
        panel.prompt = "Choose"
        panel.nameFieldStringValue = destination.lastPathComponent
        panel.directoryURL = destination.deletingLastPathComponent()
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { customDestination = panel.url }
    }

    private func open(path: String) {
        DesktopProjectPreferences.shared.registerWorktree(path, project: projectURL.path)
        store.beginProjectChat(at: URL(fileURLWithPath: path), offerWorktree: false)
        dismiss()
    }

    private func create() {
        guard validation == nil else { return }
        let destination = destination, branch = branchName, base = base
        let setupCommand = setup.map { "(\n" + $0.command + "\n)" }.joined(separator: " && ")
        guard !runSetupActions || setupCommand.utf8.count <= 32_768 else {
            error = "Combined setup actions exceed 32 KB. Put the setup in a project script or create the worktree without running setup."
            return
        }
        isBusy = true; error = nil
        Task {
            defer { isBusy = false }
            do {
                let snapshot = try await git.repositorySnapshot(for: projectURL)
                let created = try await git.createWorktree(at: destination, branch: branch, base: base, repository: snapshot)
                DesktopProjectPreferences.shared.registerWorktree(created.path, project: projectURL.path)
                let shouldRunSetup = runSetupActions
                store.beginProjectChat(at: destination, offerWorktree: false) {
                    if shouldRunSetup { runSetup(.init(name: "Worktree setup", command: setupCommand), destination) }
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
