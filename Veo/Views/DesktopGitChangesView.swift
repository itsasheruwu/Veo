// FILE: DesktopGitChangesView.swift
// Purpose: Presents local repository changes through explicit callback-driven desktop actions.
// Layer: Desktop app view
// Depends on: DesktopGitModels, SwiftUI

import SwiftUI

struct DesktopGitChangesActions {
    let refresh: () -> Void
    let stage: ([DesktopGitFileID]) -> Void
    let unstage: ([DesktopGitFileID]) -> Void
    let discard: (DesktopGitFileID, DesktopGitDiscardMode) -> Void
    let commit: (_ message: String, _ files: [DesktopGitFileID]) -> Void
    let createBranch: (_ name: String) -> Void
}

struct DesktopGitChangesView: View {
    private struct DiscardPrompt: Identifiable {
        let file: DesktopGitFileChange
        let mode: DesktopGitDiscardMode

        var id: String { "\(file.id.id):\(mode.rawValue)" }
    }

    let repository: DesktopGitRepositorySnapshot?
    let isRefreshing: Bool
    let isMutating: Bool
    let message: String?
    let actions: DesktopGitChangesActions

    @State private var commitMessage = ""
    @State private var selectedCommitFileIDs = Set<DesktopGitFileID>()
    @State private var branchName = ""
    @State private var discardPrompt: DiscardPrompt?

    init(
        repository: DesktopGitRepositorySnapshot?,
        isRefreshing: Bool = false,
        isMutating: Bool = false,
        message: String? = nil,
        actions: DesktopGitChangesActions
    ) {
        self.repository = repository
        self.isRefreshing = isRefreshing
        self.isMutating = isMutating
        self.message = message
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let repository {
                repositoryContent(repository)
            } else if isRefreshing {
                ProgressView("Reading repository…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Git unavailable",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(message ?? "Open a project inside a Git repository.")
                )
            }
        }
        .frame(minWidth: 720, minHeight: 540)
        .onAppear(perform: actions.refresh)
        .onChange(of: repository?.id) { _, _ in
            reconcileCommitSelection()
        }
        .alert(
            discardAlertTitle,
            isPresented: Binding(
                get: { discardPrompt != nil },
                set: { if !$0 { discardPrompt = nil } }
            ),
            presenting: discardPrompt
        ) { prompt in
            Button(discardButtonTitle(prompt), role: .destructive) {
                actions.discard(prompt.file.id, prompt.mode)
                discardPrompt = nil
            }
            Button("Cancel", role: .cancel) {
                discardPrompt = nil
            }
        } message: { prompt in
            Text(discardMessage(prompt))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Changes", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 17, weight: .semibold))
            if let repository {
                Text(repository.branchName ?? (repository.isUnborn ? "Unborn branch" : "Detached HEAD"))
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isRefreshing || isMutating {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                actions.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing || isMutating)
        }
        .padding(14)
    }

    private func repositoryContent(_ repository: DesktopGitRepositorySnapshot) -> some View {
        HSplitView {
            changesList(repository)
                .frame(minWidth: 390, idealWidth: 500)

            actionPane(repository)
                .frame(minWidth: 270, idealWidth: 320, maxWidth: 390)
        }
    }

    private func changesList(_ repository: DesktopGitRepositorySnapshot) -> some View {
        List {
            if let blocker = repository.mutationBlocker {
                Section {
                    Label(blocker, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if let message, !message.isEmpty {
                Section {
                    Label(message, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if !repository.conflictedFiles.isEmpty {
                Section("Conflicts") {
                    ForEach(repository.conflictedFiles) { file in
                        fileRow(file, placement: .conflict)
                    }
                }
            }

            if !repository.stagedFiles.isEmpty {
                Section("Staged") {
                    ForEach(repository.stagedFiles) { file in
                        fileRow(file, placement: .staged)
                    }
                }
            }

            if !repository.unstagedFiles.isEmpty {
                Section("Changes") {
                    ForEach(repository.unstagedFiles) { file in
                        fileRow(file, placement: .unstaged)
                    }
                }
            }

            if !repository.untrackedFiles.isEmpty {
                Section("Untracked") {
                    ForEach(repository.untrackedFiles) { file in
                        fileRow(file, placement: .untracked)
                    }
                }
            }

            if repository.files.isEmpty {
                ContentUnavailableView(
                    "Working tree clean",
                    systemImage: "checkmark.circle",
                    description: Text("There are no local changes in this repository.")
                )
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.inset)
    }

    private enum FilePlacement {
        case staged
        case unstaged
        case untracked
        case conflict
    }

    private func fileRow(_ file: DesktopGitFileChange, placement: FilePlacement) -> some View {
        HStack(spacing: 10) {
            if placement == .staged, fileCanBeCommitted(file) {
                Toggle(
                    "Select \(file.path) for commit",
                    isOn: commitSelectionBinding(for: file.id)
                )
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(isMutating)
            } else {
                Image(systemName: fileSymbol(file))
                    .foregroundStyle(file.isUnmerged ? .orange : .secondary)
                    .frame(width: 15)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.path)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let originalPath = file.originalPath {
                        Text("from \(originalPath)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(file.displayStatus)
                    }
                    if !file.isInWorkspace {
                        Text("Outside workspace")
                            .foregroundStyle(.orange)
                    } else if file.isSubmodule {
                        Text("Submodule")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            rowAction(file, placement: placement)
        }
        .contentShape(Rectangle())
        .contextMenu {
            rowContextMenu(file, placement: placement)
        }
    }

    @ViewBuilder
    private func rowAction(_ file: DesktopGitFileChange, placement: FilePlacement) -> some View {
        switch placement {
        case .staged:
            Button {
                actions.unstage([file.id])
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .help("Unstage \(file.path)")
            .disabled(!canMutate(file))
        case .unstaged, .untracked:
            Button {
                actions.stage([file.id])
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Stage \(file.path)")
            .disabled(!canStage(file))
        case .conflict:
            EmptyView()
        }
    }

    @ViewBuilder
    private func rowContextMenu(_ file: DesktopGitFileChange, placement: FilePlacement) -> some View {
        if placement == .staged {
            Button("Unstage") { actions.unstage([file.id]) }
                .disabled(!canMutate(file))
        }
        if placement == .unstaged || placement == .untracked {
            Button("Stage") { actions.stage([file.id]) }
                .disabled(!canStage(file))
            Divider()
            Button(role: .destructive) {
                discardPrompt = DiscardPrompt(file: file, mode: .unstagedOnly)
            } label: {
                Text(file.isUntracked ? "Move to Trash…" : "Discard Unstaged Changes…")
            }
            .disabled(!canMutate(file))
        }
        if placement == .staged || file.isPartiallyStaged {
            Divider()
            Button(role: .destructive) {
                discardPrompt = DiscardPrompt(file: file, mode: .allChanges)
            } label: {
                Text("Discard All Changes…")
            }
            .disabled(!canMutate(file))
        }
    }

    private func actionPane(_ repository: DesktopGitRepositorySnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                repositorySummary(repository)
                Divider()
                commitSection(repository)
                Divider()
                branchSection(repository)
            }
            .padding(16)
        }
    }

    private func repositorySummary(_ repository: DesktopGitRepositorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Repository")
                .font(.system(size: 12.5, weight: .semibold))
            Text(repository.rootPath)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if repository.workspaceRelativePath != nil {
                Label("Actions are scoped to this workspace folder.", systemImage: "folder.badge.gearshape")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                countLabel(repository.stagedFiles.count, title: "staged")
                countLabel(repository.unstagedFiles.count + repository.untrackedFiles.count, title: "unstaged")
            }
        }
    }

    private func commitSection(_ repository: DesktopGitRepositorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit")
                .font(.system(size: 12.5, weight: .semibold))
            TextField("Commit message", text: $commitMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)

            let selectedCount = selectedCommitFileIDs.count
            Text(selectedCount == 0
                ? "Select fully staged files from the Staged section."
                : "\(selectedCount) selected; other staged files will remain staged.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            Label(
                "For safety, Veo commits with repository hooks and GPG signing disabled.",
                systemImage: "lock.shield"
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            Button("Commit Selected") {
                let files = selectedCommitFileIDs.sorted { $0.id < $1.id }
                actions.commit(commitMessage, files)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isMutating
                    || repository.mutationBlocker != nil
                    || repository.isDetached
                    || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || selectedCommitFileIDs.isEmpty
            )
        }
    }

    private func branchSection(_ repository: DesktopGitRepositorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Branch")
                .font(.system(size: 12.5, weight: .semibold))
            TextField("codex/feature-name", text: $branchName)
                .textFieldStyle(.roundedBorder)
            Text("Creates the branch at the current HEAD without staging or discarding local changes.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Button("Create and Switch") {
                actions.createBranch(branchName)
            }
            .disabled(
                isMutating
                    || repository.mutationBlocker != nil
                    || repository.isUnborn
                    || branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    private func countLabel(_ count: Int, title: String) -> some View {
        Text("\(count) \(title)")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func commitSelectionBinding(for id: DesktopGitFileID) -> Binding<Bool> {
        Binding(
            get: { selectedCommitFileIDs.contains(id) },
            set: { selected in
                if selected {
                    selectedCommitFileIDs.insert(id)
                } else {
                    selectedCommitFileIDs.remove(id)
                }
            }
        )
    }

    private func reconcileCommitSelection() {
        guard let repository else {
            selectedCommitFileIDs = []
            return
        }
        let eligible = Set(repository.stagedFiles.filter(fileCanBeCommitted).map(\.id))
        selectedCommitFileIDs.formIntersection(eligible)
    }

    private func fileCanBeCommitted(_ file: DesktopGitFileChange) -> Bool {
        file.hasStagedChanges
            && !file.hasUnstagedChanges
            && !file.isUnmerged
            && !file.isSubmodule
            && file.isInWorkspace
    }

    private func canMutate(_ file: DesktopGitFileChange) -> Bool {
        !isMutating
            && repository?.mutationBlocker == nil
            && file.isInWorkspace
            && !file.isSubmodule
            && !file.isUnmerged
    }

    private func canStage(_ file: DesktopGitFileChange) -> Bool {
        canMutate(file) && !file.isPartiallyStaged
    }

    private func fileSymbol(_ file: DesktopGitFileChange) -> String {
        if file.isUnmerged { return "exclamationmark.triangle" }
        if file.originalPath != nil { return "arrow.right" }
        if file.isUntracked { return "questionmark" }
        if file.indexStatus == .deleted || file.worktreeStatus == .deleted { return "trash" }
        if file.indexStatus == .added { return "plus" }
        return "doc.text"
    }

    private var discardAlertTitle: String {
        guard let prompt = discardPrompt else { return "Discard changes?" }
        if prompt.file.isUntracked { return "Move file to Trash?" }
        return prompt.mode == .allChanges ? "Discard all changes?" : "Discard unstaged changes?"
    }

    private func discardButtonTitle(_ prompt: DiscardPrompt) -> String {
        prompt.file.isUntracked ? "Move to Trash" : "Discard"
    }

    private func discardMessage(_ prompt: DiscardPrompt) -> String {
        if prompt.file.isUntracked {
            return "\(prompt.file.path) will be copied into Veo's recovery bundle before it is moved to Trash."
        }
        if prompt.mode == .allChanges {
            return "Staged and unstaged changes to \(prompt.file.path) will be replaced with HEAD. Veo creates a recovery bundle first."
        }
        return "Only unstaged changes to \(prompt.file.path) will be discarded. Its staged contents stay intact, and Veo creates a recovery bundle first."
    }
}
