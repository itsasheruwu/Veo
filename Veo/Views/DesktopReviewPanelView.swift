// FILE: DesktopReviewPanelView.swift
// Purpose: Presents repository changes, rich diffs, Git actions, and inline Codex review controls.
// Layer: Desktop app view

import SwiftUI

struct DesktopReviewPanelView: View {
    private struct DiscardPrompt: Identifiable {
        let file: DesktopGitFileChange
        let mode: DesktopGitDiscardMode
        var id: String { "\(file.id.id):\(mode.rawValue)" }
    }

    @ObservedObject var store: DesktopCodexStore
    @Binding var presentsAIReview: Bool
    @AppStorage(DesktopUtilityPreferences.reviewLayoutKey) private var layoutRaw = DesktopReviewLayout.unified.rawValue
    @AppStorage(DesktopUtilityPreferences.hideWhitespaceKey) private var hidesWhitespace = false
    @State private var selectedDiffID: DesktopGitFileDiffID?
    @State private var commitMessage = ""
    @State private var selectedCommitFileIDs = Set<DesktopGitFileID>()
    @State private var branchName = ""
    @State private var showsRepositoryActions = false
    @State private var discardPrompt: DiscardPrompt?

    private var layout: DesktopReviewLayout {
        get { DesktopReviewLayout(rawValue: layoutRaw) ?? .unified }
        nonmutating set { layoutRaw = newValue.rawValue }
    }

    private var selectedDiff: DesktopGitFileDiff? {
        let files = store.gitReviewSnapshot?.files ?? []
        return files.first(where: { $0.id == selectedDiffID }) ?? files.first
    }

    var body: some View {
        VStack(spacing: 0) {
            reviewToolbar
            Divider()

            if let repository = store.gitRepository {
                if layout == .split {
                    ViewThatFits(in: .horizontal) {
                        reviewWorkspace(repository, effectiveLayout: .split)
                            .frame(minWidth: 680)
                        reviewWorkspace(repository, effectiveLayout: .unified)
                    }
                } else {
                    reviewWorkspace(repository, effectiveLayout: .unified)
                }
            } else if store.isRefreshingGit {
                ProgressView("Reading repository…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let liveDiff = store.selectedTurnDiff, !liveDiff.isEmpty {
                DesktopLiveTurnDiffView(diff: liveDiff)
            } else {
                ContentUnavailableView(
                    "Git unavailable",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(store.gitMessage ?? "Open a project inside a Git repository.")
                )
            }

            if presentsAIReview {
                Divider()
                DesktopInlineReviewCard(store: store) {
                    presentsAIReview = false
                }
            }

            if showsRepositoryActions, let repository = store.gitRepository {
                Divider()
                repositoryActions(repository)
            }
        }
        .onAppear {
            store.refreshGitRepository()
            reconcileSelection()
        }
        .onChange(of: store.gitReviewSnapshot) { _, _ in reconcileSelection() }
        .alert(
            discardAlertTitle,
            isPresented: Binding(
                get: { discardPrompt != nil },
                set: { if !$0 { discardPrompt = nil } }
            ),
            presenting: discardPrompt
        ) { prompt in
            Button(prompt.file.isUntracked ? "Move to Trash" : "Discard", role: .destructive) {
                store.discardGitFile(prompt.file.id, mode: prompt.mode)
                discardPrompt = nil
            }
            Button("Cancel", role: .cancel) { discardPrompt = nil }
        } message: { prompt in
            Text(discardMessage(prompt))
        }
    }

    private func reviewWorkspace(
        _ repository: DesktopGitRepositorySnapshot,
        effectiveLayout: DesktopReviewLayout
    ) -> some View {
        HStack(spacing: 0) {
            changedFiles(repository)
                .frame(width: effectiveLayout == .split ? 220 : 190)
            Divider()
            diffPane(selectedDiff, effectiveLayout: effectiveLayout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var reviewToolbar: some View {
        HStack(spacing: 8) {
            if let repository = store.gitRepository {
                Text(repository.branchName ?? (repository.isDetached ? "Detached HEAD" : "Unborn branch"))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            } else {
                Text("Review").font(.system(size: 12.5, weight: .semibold))
            }
            Spacer(minLength: 4)
            Menu {
                Picker("Diff layout", selection: Binding(get: { layout }, set: { layout = $0 })) {
                    ForEach(DesktopReviewLayout.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Toggle("Hide whitespace-only hunks", isOn: $hidesWhitespace)
            } label: {
                Image(systemName: layout == .unified ? "rectangle.compress.vertical" : "rectangle.split.2x1")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)

            Button {
                presentsAIReview.toggle()
            } label: {
                Image(systemName: "sparkles")
            }
            .help("AI Review")
            .disabled(store.isBusyTurn)

            Button {
                showsRepositoryActions.toggle()
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .help("Commit and branch actions")

            Button {
                store.refreshGitRepository()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh Review")
            .disabled(store.isRefreshingGit || store.isMutatingGit)

            if store.isRefreshingGit || store.isRefreshingGitReview || store.isMutatingGit {
                ProgressView().controlSize(.small)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private func changedFiles(_ repository: DesktopGitRepositorySnapshot) -> some View {
        List(selection: $selectedDiffID) {
            if !repository.conflictedFiles.isEmpty {
                fileSection("Conflicts", repository.conflictedFiles, preferredSide: .unstaged)
            }
            if !repository.stagedFiles.isEmpty {
                fileSection("Staged", repository.stagedFiles, preferredSide: .staged)
            }
            if !repository.unstagedFiles.isEmpty {
                fileSection("Changes", repository.unstagedFiles, preferredSide: .unstaged)
            }
            if !repository.untrackedFiles.isEmpty {
                fileSection("Untracked", repository.untrackedFiles, preferredSide: .unstaged)
            }
            if repository.files.isEmpty {
                ContentUnavailableView("Working tree clean", systemImage: "checkmark.circle")
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func fileSection(
        _ title: String,
        _ files: [DesktopGitFileChange],
        preferredSide: DesktopGitDiffSide
    ) -> some View {
        Section(title) {
            ForEach(files) { file in
                let id = DesktopGitFileDiffID(fileID: file.id, side: preferredSide)
                HStack(spacing: 7) {
                    Image(systemName: file.isUnmerged ? "exclamationmark.triangle" : "doc.text")
                        .foregroundStyle(file.isUnmerged ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(URL(fileURLWithPath: file.path).lastPathComponent)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        Text(file.path)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 2)
                    Text(shortStatus(file))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(statusColor(file))
                }
                .tag(id)
                .contextMenu { fileContextMenu(file, side: preferredSide) }
            }
        }
    }

    @ViewBuilder
    private func fileContextMenu(_ file: DesktopGitFileChange, side: DesktopGitDiffSide) -> some View {
        if side == .staged {
            Button("Unstage File") { store.unstageGitFiles([file.id]) }
                .disabled(store.isMutatingGit || file.isUnmerged || file.isSubmodule)
        } else {
            Button("Stage File") { store.stageGitFiles([file.id]) }
                .disabled(store.isMutatingGit || file.isUnmerged || file.isSubmodule || file.isPartiallyStaged)
            Divider()
            Button(role: .destructive) {
                discardPrompt = .init(file: file, mode: .unstagedOnly)
            } label: {
                Text(file.isUntracked ? "Move to Trash…" : "Discard Unstaged Changes…")
            }
            .disabled(store.isMutatingGit)
        }
    }

    @ViewBuilder
    private func diffPane(_ file: DesktopGitFileDiff?, effectiveLayout: DesktopReviewLayout) -> some View {
        if let file {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.path)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(file.side.title)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("+\(file.additions)").foregroundStyle(.green)
                    Text("−\(file.deletions)").foregroundStyle(.red)
                    Button(file.side == .staged ? "Unstage File" : "Stage File") {
                        if file.side == .staged {
                            store.unstageGitFiles([file.id.fileID])
                        } else {
                            store.stageGitFiles([file.id.fileID])
                        }
                    }
                    .controlSize(.small)
                    .disabled(store.isMutatingGit)
                }
                .font(.system(size: 10.5, weight: .medium))
                .padding(10)

                Divider()

                if let reason = file.unavailableReason {
                    ContentUnavailableView(
                        file.isBinary ? "Binary file" : "Diff unavailable",
                        systemImage: file.isBinary ? "doc.badge.gearshape" : "exclamationmark.triangle",
                        description: Text(reason)
                    )
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleHunks(file)) { hunk in
                                DesktopDiffHunkView(
                                    hunk: hunk,
                                    layout: effectiveLayout,
                                    actionTitle: file.side == .staged ? "Unstage Hunk" : "Stage Hunk"
                                ) {
                                    store.applyGitHunk(.init(fileDiffID: file.id, hunkID: hunk.id))
                                }
                            }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "No change selected",
                systemImage: "arrow.left.arrow.right",
                description: Text("Select a changed file to review its diff.")
            )
        }
    }

    private func visibleHunks(_ file: DesktopGitFileDiff) -> [DesktopGitDiffHunk] {
        hidesWhitespace ? file.hunks.filter { !$0.isWhitespaceOnly } : file.hunks
    }

    private func repositoryActions(_ repository: DesktopGitRepositorySnapshot) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Commit message", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
                Menu("\(selectedCommitFileIDs.count) files") {
                    ForEach(repository.stagedFiles.filter(fileCanBeCommitted)) { file in
                        Toggle(file.path, isOn: commitSelection(for: file.id))
                    }
                }
                Button("Commit") {
                    store.commitGitFiles(
                        message: commitMessage,
                        fileIDs: selectedCommitFileIDs.sorted { $0.id < $1.id }
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedCommitFileIDs.isEmpty)
            }
            HStack(spacing: 8) {
                TextField("codex/feature-name", text: $branchName)
                    .textFieldStyle(.roundedBorder)
                Button("Create Branch") { store.createGitBranch(named: branchName) }
                    .disabled(branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let message = store.gitMessage, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .onChange(of: repository.id) { _, _ in reconcileCommitSelection(repository) }
    }

    private func reconcileSelection() {
        let files = store.gitReviewSnapshot?.files ?? []
        if selectedDiffID == nil || !files.contains(where: { $0.id == selectedDiffID }) {
            selectedDiffID = files.first?.id
        }
        if let repository = store.gitRepository { reconcileCommitSelection(repository) }
    }

    private func reconcileCommitSelection(_ repository: DesktopGitRepositorySnapshot) {
        let eligible = Set(repository.stagedFiles.filter(fileCanBeCommitted).map(\.id))
        selectedCommitFileIDs.formIntersection(eligible)
    }

    private func fileCanBeCommitted(_ file: DesktopGitFileChange) -> Bool {
        file.hasStagedChanges && !file.hasUnstagedChanges && !file.isUnmerged && !file.isSubmodule && file.isInWorkspace
    }

    private func commitSelection(for id: DesktopGitFileID) -> Binding<Bool> {
        Binding(
            get: { selectedCommitFileIDs.contains(id) },
            set: { selected in
                if selected { selectedCommitFileIDs.insert(id) } else { selectedCommitFileIDs.remove(id) }
            }
        )
    }

    private func shortStatus(_ file: DesktopGitFileChange) -> String {
        if file.isUnmerged { return "!" }
        if file.isUntracked { return "U" }
        if file.isPartiallyStaged { return "M±" }
        if file.indexStatus == .added { return "A" }
        if file.indexStatus == .deleted || file.worktreeStatus == .deleted { return "D" }
        return "M"
    }

    private func statusColor(_ file: DesktopGitFileChange) -> Color {
        if file.isUnmerged { return .orange }
        if file.isUntracked || file.indexStatus == .added { return .green }
        if file.indexStatus == .deleted || file.worktreeStatus == .deleted { return .red }
        return .secondary
    }

    private var discardAlertTitle: String {
        discardPrompt?.file.isUntracked == true ? "Move file to Trash?" : "Discard changes?"
    }

    private func discardMessage(_ prompt: DiscardPrompt) -> String {
        if prompt.file.isUntracked {
            return "\(prompt.file.path) will be copied into Veo's recovery bundle before it is moved to Trash."
        }
        return "Unstaged changes to \(prompt.file.path) will be replaced with the index. Veo creates a recovery bundle first."
    }
}

private struct DesktopLiveTurnDiffView: View {
    let diff: DesktopTurnDiff

    private var text: String {
        if !diff.unifiedDiff.isEmpty { return diff.unifiedDiff }
        return diff.files.map { "### \($0.path)\n\($0.diff)" }.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Live turn changes", systemImage: "bolt.horizontal.circle")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text("Updates while Codex edits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { index, raw in
                        let line = String(raw)
                        HStack(spacing: 0) {
                            Text(String(index + 1))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 42, alignment: .trailing)
                                .padding(.trailing, 6)
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                        }
                        .frame(minHeight: 20)
                        .background(line.hasPrefix("+") ? Color.green.opacity(0.13) : (line.hasPrefix("-") ? Color.red.opacity(0.13) : .clear))
                    }
                }
            }
        }
    }
}

private struct DesktopDiffHunkView: View {
    let hunk: DesktopGitDiffHunk
    let layout: DesktopReviewLayout
    let actionTitle: String
    let action: () -> Void
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { isExpanded.toggle() } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                Text(hunk.header)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(actionTitle, action: action)
                    .controlSize(.mini)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(Color.primary.opacity(0.045))

            if isExpanded {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        if layout == .split {
                            DesktopSplitDiffLines(lines: hunk.lines)
                                .frame(minWidth: 640, alignment: .leading)
                        } else {
                            ForEach(Array(hunk.lines.indices), id: \.self) { index in
                                DesktopUnifiedDiffLine(
                                    line: hunk.lines[index],
                                    counterpart: pairedCounterpart(for: index)
                                )
                            }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func pairedCounterpart(for index: Int) -> String? {
        let line = hunk.lines[index]
        guard line.kind == .addition || line.kind == .deletion else { return nil }
        var start = index
        while start > 0 && isChanged(hunk.lines[start - 1]) {
            start -= 1
        }
        var end = index
        while end + 1 < hunk.lines.count && isChanged(hunk.lines[end + 1]) {
            end += 1
        }
        let group = Array(hunk.lines[start...end])
        let sameKind = group.filter { $0.kind == line.kind }
        let otherKind = group.filter { $0.kind != line.kind }
        guard let offset = sameKind.firstIndex(where: { $0.id == line.id }),
              otherKind.indices.contains(offset) else { return nil }
        return otherKind[offset].text
    }

    private func isChanged(_ line: DesktopGitDiffLine) -> Bool {
        line.kind == .addition || line.kind == .deletion
    }
}

private struct DesktopUnifiedDiffLine: View {
    let line: DesktopGitDiffLine
    let counterpart: String?

    var body: some View {
        HStack(spacing: 0) {
            lineNumber(line.oldLineNumber)
            lineNumber(line.newLineNumber)
            DesktopIntralineDiffText(source: line.text, counterpart: counterpart, kind: line.kind)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
        }
        .frame(minHeight: 20)
        .background(background)
    }

    private func lineNumber(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 36, alignment: .trailing)
            .padding(.trailing, 5)
            .background(Color.primary.opacity(0.025))
    }

    private var background: Color {
        switch line.kind {
        case .addition: return .green.opacity(0.13)
        case .deletion: return .red.opacity(0.13)
        default: return .clear
        }
    }
}

private struct DesktopSplitDiffLines: View {
    let lines: [DesktopGitDiffLine]

    private var rows: [(DesktopGitDiffLine?, DesktopGitDiffLine?)] {
        var output: [(DesktopGitDiffLine?, DesktopGitDiffLine?)] = []
        var deletions: [DesktopGitDiffLine] = []
        var additions: [DesktopGitDiffLine] = []
        func flush() {
            let count = max(deletions.count, additions.count)
            for index in 0..<count {
                output.append((deletions.indices.contains(index) ? deletions[index] : nil,
                               additions.indices.contains(index) ? additions[index] : nil))
            }
            deletions = []
            additions = []
        }
        for line in lines {
            switch line.kind {
            case .deletion: deletions.append(line)
            case .addition: additions.append(line)
            default:
                flush()
                output.append((line, line))
            }
        }
        flush()
        return output
    }

    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            HStack(spacing: 0) {
                splitLine(row.0, counterpart: row.1?.text, isOld: true)
                Divider()
                splitLine(row.1, counterpart: row.0?.text, isOld: false)
            }
            .frame(minHeight: 20)
        }
    }

    private func splitLine(_ line: DesktopGitDiffLine?, counterpart: String?, isOld: Bool) -> some View {
        HStack(spacing: 0) {
            Text((isOld ? line?.oldLineNumber : line?.newLineNumber).map(String.init) ?? "")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 5)
            DesktopIntralineDiffText(
                source: line.map { String($0.text.dropFirst($0.kind == .context || $0.kind == .metadata ? 0 : 1)) } ?? "",
                counterpart: counterpart.map { other in
                    String(other.dropFirst(other.hasPrefix("+") || other.hasPrefix("-") ? 1 : 0))
                },
                kind: line?.kind ?? .context
            )
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 5)
        }
        .background(isOld ? Color.red.opacity(line == nil ? 0 : 0.12) : Color.green.opacity(line == nil ? 0 : 0.12))
    }
}

private struct DesktopIntralineDiffText: View {
    let source: String
    let counterpart: String?
    let kind: DesktopGitDiffLineKind

    var body: some View {
        highlightedText
    }

    private var highlightedText: Text {
        guard let counterpart,
              kind == .addition || kind == .deletion else { return Text(source) }
        let sourceHasMarker = source.hasPrefix("+") || source.hasPrefix("-")
        let counterpartHasMarker = counterpart.hasPrefix("+") || counterpart.hasPrefix("-")
        let sourceMarker = sourceHasMarker ? String(source.prefix(1)) : ""
        let sourceBody = Array(source.dropFirst(sourceHasMarker ? 1 : 0))
        let otherBody = Array(counterpart.dropFirst(counterpartHasMarker ? 1 : 0))

        var prefixCount = 0
        while prefixCount < min(sourceBody.count, otherBody.count),
              sourceBody[prefixCount] == otherBody[prefixCount] {
            prefixCount += 1
        }
        var suffixCount = 0
        while suffixCount < min(sourceBody.count - prefixCount, otherBody.count - prefixCount),
              sourceBody[sourceBody.count - suffixCount - 1] == otherBody[otherBody.count - suffixCount - 1] {
            suffixCount += 1
        }
        let changedEnd = sourceBody.count - suffixCount
        guard prefixCount < changedEnd else { return Text(source) }
        let prefix = sourceMarker + String(sourceBody[..<prefixCount])
        let changed = String(sourceBody[prefixCount..<changedEnd])
        let suffix = String(sourceBody[changedEnd...])
        let color: Color = kind == .addition ? .green : .red
        return Text(prefix) + Text(changed).bold().foregroundColor(color) + Text(suffix)
    }
}

private struct DesktopInlineReviewCard: View {
    @ObservedObject var store: DesktopCodexStore
    let close: () -> Void
    @State private var request = DesktopReviewRequest()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("AI Review", systemImage: "sparkles").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            HStack(spacing: 8) {
                Picker("Target", selection: $request.target) {
                    ForEach(DesktopReviewTargetKind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                if request.target != .uncommittedChanges {
                    TextField(request.target.prompt, text: $request.value)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Picker("Result", selection: $request.delivery) {
                ForEach(DesktopReviewDelivery.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Spacer()
                Button("Start Review") {
                    store.reviewChanges(request)
                    close()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!request.isValid || store.isBusyTurn)
            }
        }
        .padding(10)
    }
}
