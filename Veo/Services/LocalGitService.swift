// FILE: LocalGitService.swift
// Purpose: Reads and mutates one local Git repository without touching unrelated work.
// Layer: Desktop app service
// Depends on: DesktopGitModels, GitRecoveryStore, Foundation, CryptoKit

@preconcurrency import Foundation
import CryptoKit

actor LocalGitService {
    private static let maximumReviewPatchBytes = 8 * 1_024 * 1_024

    private struct GitProcessResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    private struct ParsedStatus {
        let branchName: String?
        let headObjectID: String?
        let isDetached: Bool
        let isUnborn: Bool
        let files: [DesktopGitFileChange]
    }

    private struct RepositoryContext {
        let snapshot: DesktopGitRepositorySnapshot
        let indexEntries: [String: [String]]
        let worktreeFingerprints: [String: String]
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func set(_ data: Data) {
            lock.lock()
            storage = data
            lock.unlock()
        }

        func value() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private let gitExecutableURL: URL
    private let sandboxExecutableURL: URL
    private let fileManager: FileManager
    private let recoveryStore: DesktopGitRecoveryStore

    init(
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        sandboxExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
        fileManager: FileManager = .default,
        recoveryStore: DesktopGitRecoveryStore = DesktopGitRecoveryStore()
    ) {
        self.gitExecutableURL = gitExecutableURL.path == "/usr/bin/git"
            ? Self.selectedSystemGitExecutable(fileManager: fileManager) ?? gitExecutableURL
            : gitExecutableURL
        self.sandboxExecutableURL = sandboxExecutableURL
        self.fileManager = fileManager
        self.recoveryStore = recoveryStore
    }

    private static func selectedSystemGitExecutable(fileManager: FileManager) -> URL? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--print-path"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "LANG": "C",
        ]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard data.count <= 4_096,
              let developerPath = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !developerPath.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: developerPath, isDirectory: true)
            .appendingPathComponent("usr/bin/git", isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let path = candidate.path
        let isTrustedLocation = path == "/Library/Developer/CommandLineTools/usr/bin/git"
            || (path.hasPrefix("/Applications/")
                && path.hasSuffix(".app/Contents/Developer/usr/bin/git"))
        guard isTrustedLocation,
              fileManager.isExecutableFile(atPath: path),
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return nil
        }
        // Xcode betas installed through Apple's downloader can be owned by the
        // installing user rather than root. xcode-select is the system source
        // of truth, and the candidate is still constrained to an Xcode or CLT
        // developer directory before it is admitted to the exec sandbox.
        return candidate
    }

    func repositorySnapshot(for workspaceURL: URL) async throws -> DesktopGitRepositorySnapshot {
        try loadContext(for: workspaceURL).snapshot
    }

    func reviewSnapshot(
        for expectedRepository: DesktopGitRepositorySnapshot
    ) async throws -> DesktopGitReviewSnapshot {
        let current = try loadContext(
            for: URL(fileURLWithPath: expectedRepository.workspacePath, isDirectory: true)
        )
        guard current.snapshot.id == expectedRepository.id,
              current.snapshot.rootPath == expectedRepository.rootPath else {
            throw DesktopGitError.staleSnapshot
        }

        var diffs: [DesktopGitFileDiff] = []
        for change in current.snapshot.files where change.isInWorkspace {
            if change.hasStagedChanges {
                diffs.append(try fileDiff(for: change, side: .staged, repository: current.snapshot))
            }
            if change.hasUnstagedChanges {
                diffs.append(try fileDiff(for: change, side: .unstaged, repository: current.snapshot))
            }
        }
        return DesktopGitReviewSnapshot(
            repositoryID: current.snapshot.id,
            files: diffs,
            capturedAt: Date()
        )
    }

    func applyHunk(
        _ selection: DesktopGitHunkSelection,
        in expectedRepository: DesktopGitRepositorySnapshot
    ) async throws -> DesktopGitMutationResult {
        let before = try validatedContext(expectedRepository)
        let change = try selectedChanges([selection.fileDiffID.fileID], in: before.snapshot)[0]
        guard !change.isUnmerged,
              !change.isSubmodule,
              change.originalPath == nil else {
            throw DesktopGitError.hunkUnavailable(change.path)
        }
        let file = try fileDiff(for: change, side: selection.fileDiffID.side, repository: before.snapshot)
        guard !file.isBinary,
              file.unavailableReason == nil,
              let hunk = file.hunks.first(where: { $0.id == selection.hunkID }) else {
            throw DesktopGitError.hunkUnavailable(change.path)
        }
        let patch = (file.headerLines + [hunk.patch]).joined(separator: "\n") + "\n"
        guard let patchData = patch.data(using: .utf8),
              patchData.count <= Self.maximumReviewPatchBytes else {
            throw DesktopGitError.diffUnavailable(change.path)
        }

        var arguments = [
            "--literal-pathspecs", "-C", before.snapshot.rootPath,
            "apply", "--cached", "--recount", "--whitespace=nowarn",
        ]
        if selection.fileDiffID.side == .staged {
            arguments.append("--reverse")
        }
        arguments.append("-")
        try runRequired(arguments, operation: selection.fileDiffID.side == .staged
            ? "unstaging the selected hunk"
            : "staging the selected hunk", stdin: patchData)

        let affectedPaths = Set(try validatedMutationPaths(for: [change], repository: before.snapshot))
        let after = try loadContext(
            for: URL(fileURLWithPath: before.snapshot.workspacePath, isDirectory: true)
        )
        try verifyUnrelatedState(before: before, after: after, affectedPaths: affectedPaths)
        try verifySelectedWorktreeWasNotModified(before: before, affectedPaths: affectedPaths)
        return DesktopGitMutationResult(repository: after.snapshot, recovery: nil)
    }

    func stage(
        _ fileIDs: [DesktopGitFileID],
        in expectedRepository: DesktopGitRepositorySnapshot
    ) async throws -> DesktopGitMutationResult {
        let before = try validatedContext(expectedRepository)
        let changes = try selectedChanges(fileIDs, in: before.snapshot)
        for change in changes where change.isPartiallyStaged {
            throw DesktopGitError.partialStaging(change.path)
        }
        let affectedPaths = try validatedMutationPaths(for: changes, repository: before.snapshot)
        guard changes.contains(where: \.hasUnstagedChanges) else {
            throw DesktopGitError.nothingToDo
        }

        try runRequired(
            ["--literal-pathspecs", "-C", before.snapshot.rootPath, "add", "--all", "--"] + affectedPaths,
            operation: "staging selected files"
        )

        let after = try loadContext(for: URL(fileURLWithPath: before.snapshot.workspacePath, isDirectory: true))
        try verifyUnrelatedState(before: before, after: after, affectedPaths: Set(affectedPaths))
        try verifySelectedWorktreeWasNotModified(before: before, affectedPaths: Set(affectedPaths))
        return DesktopGitMutationResult(repository: after.snapshot, recovery: nil)
    }

    func unstage(
        _ fileIDs: [DesktopGitFileID],
        in expectedRepository: DesktopGitRepositorySnapshot
    ) async throws -> DesktopGitMutationResult {
        let before = try validatedContext(expectedRepository)
        let changes = try selectedChanges(fileIDs, in: before.snapshot)
        let stagedChanges = changes.filter(\.hasStagedChanges)
        guard !stagedChanges.isEmpty else { throw DesktopGitError.nothingToDo }
        let affectedPaths = try validatedMutationPaths(for: stagedChanges, repository: before.snapshot)

        if before.snapshot.isUnborn {
            try runRequired(
                ["--literal-pathspecs", "-C", before.snapshot.rootPath, "update-index", "--force-remove", "--"] + affectedPaths,
                operation: "unstaging selected files"
            )
        } else {
            try runRequired(
                [
                    "--literal-pathspecs", "-C", before.snapshot.rootPath,
                    "restore", "--staged", "--source=HEAD", "--",
                ] + affectedPaths,
                operation: "unstaging selected files"
            )
        }

        let after = try loadContext(for: URL(fileURLWithPath: before.snapshot.workspacePath, isDirectory: true))
        try verifyUnrelatedState(before: before, after: after, affectedPaths: Set(affectedPaths))
        try verifySelectedWorktreeWasNotModified(before: before, affectedPaths: Set(affectedPaths))
        return DesktopGitMutationResult(repository: after.snapshot, recovery: nil)
    }

    func discard(
        _ fileIDs: [DesktopGitFileID],
        mode: DesktopGitDiscardMode,
        in expectedRepository: DesktopGitRepositorySnapshot
    ) async throws -> DesktopGitMutationResult {
        let before = try validatedContext(expectedRepository)
        let requestedChanges = try selectedChanges(fileIDs, in: before.snapshot)
        let changes: [DesktopGitFileChange]
        switch mode {
        case .unstagedOnly:
            changes = requestedChanges.filter(\.hasUnstagedChanges)
        case .allChanges:
            changes = requestedChanges.filter { $0.hasStagedChanges || $0.hasUnstagedChanges }
        }
        guard !changes.isEmpty else { throw DesktopGitError.nothingToDo }

        let affectedPaths = try validatedMutationPaths(for: changes, repository: before.snapshot)
        let patches = try recoveryPatches(for: affectedPaths, context: before)
        let recovery = try await recoveryStore.createBundle(
            repository: before.snapshot,
            paths: affectedPaths,
            stagedPatch: patches.staged,
            worktreePatch: patches.worktree
        )

        let tracked = changes.filter { !$0.isUntracked }
        let untracked = changes.filter(\.isUntracked)
        let trackedPaths: [String]
        switch mode {
        case .unstagedOnly:
            trackedPaths = try validatedPaths(
                tracked.flatMap(\.worktreeMutationPaths),
                repository: before.snapshot
            )
        case .allChanges:
            trackedPaths = try validatedMutationPaths(for: tracked, repository: before.snapshot)
        }

        switch mode {
        case .unstagedOnly:
            if !trackedPaths.isEmpty {
                try runRequired(
                    [
                        "--literal-pathspecs", "-C", before.snapshot.rootPath,
                        "restore", "--worktree", "--no-recurse-submodules", "--",
                    ] + trackedPaths,
                    operation: "discarding unstaged changes"
                )
            }
        case .allChanges:
            if !trackedPaths.isEmpty {
                if before.snapshot.isUnborn {
                    try runRequired(
                        [
                            "--literal-pathspecs", "-C", before.snapshot.rootPath,
                            "update-index", "--force-remove", "--",
                        ] + trackedPaths,
                        operation: "unstaging initial files before discard"
                    )
                } else {
                    try runRequired(
                        [
                            "--literal-pathspecs", "-C", before.snapshot.rootPath,
                            "restore", "--source=HEAD", "--staged", "--worktree",
                            "--no-recurse-submodules", "--",
                        ] + trackedPaths,
                        operation: "discarding selected changes"
                    )
                }
            }
        }

        var trashPaths = untracked.flatMap(\.mutationPaths)
        if mode == .allChanges, before.snapshot.isUnborn {
            trashPaths.append(contentsOf: trackedPaths)
        }
        let trashURLs = trashPaths
            .uniquedAndSorted()
            .compactMap { path -> URL? in
                let url = URL(fileURLWithPath: before.snapshot.rootPath, isDirectory: true)
                    .appendingPathComponent(path, isDirectory: false)
                return itemExistsWithoutFollowingFinalSymlink(at: url) ? url : nil
            }
        if !trashURLs.isEmpty {
            try await recoveryStore.moveItemsToTrash(trashURLs)
        }

        let after = try loadContext(for: URL(fileURLWithPath: before.snapshot.workspacePath, isDirectory: true))
        let affectedSet = Set(affectedPaths)
        try verifyUnrelatedState(before: before, after: after, affectedPaths: affectedSet)
        if mode == .unstagedOnly {
            guard before.indexEntries == after.indexEntries else {
                throw DesktopGitError.postconditionFailed("Discarding unstaged changes unexpectedly changed the Git index.")
            }
        }
        return DesktopGitMutationResult(repository: after.snapshot, recovery: recovery)
    }

    func commit(
        message: String,
        fileIDs: [DesktopGitFileID],
        in expectedRepository: DesktopGitRepositorySnapshot
    ) async throws -> DesktopGitCommitResult {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty, !message.contains("\u{0}") else {
            throw DesktopGitError.commitMessageRequired
        }

        let before = try validatedContext(expectedRepository)
        guard !before.snapshot.isDetached else { throw DesktopGitError.detachedHead }
        let changes = try selectedChanges(fileIDs, in: before.snapshot)
        for change in changes {
            guard change.hasStagedChanges, !change.hasUnstagedChanges else {
                throw DesktopGitError.commitSelectionRequiresFullyStaged(change.path)
            }
        }
        let affectedPaths = try validatedMutationPaths(for: changes, repository: before.snapshot)
        let affectedSet = Set(affectedPaths)

        var arguments = [
            "--literal-pathspecs",
            "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgSign=false",
            "-C", before.snapshot.rootPath,
            "commit", "--no-verify", "--no-gpg-sign",
            "--cleanup=verbatim", "-m", message,
        ]

        if before.snapshot.isUnborn {
            let allStagedPaths = Set(before.snapshot.stagedFiles.flatMap(\.mutationPaths))
            guard affectedSet == allStagedPaths else {
                throw DesktopGitError.postconditionFailed(
                    "The first commit must include every staged file. Unstage anything that should remain outside it."
                )
            }
        } else {
            arguments.append("--only")
            arguments.append("--")
            arguments.append(contentsOf: affectedPaths)
        }

        try runRequired(arguments, operation: "committing selected files")
        let commitObjectID = try requiredText(
            ["-C", before.snapshot.rootPath, "rev-parse", "--verify", "HEAD"],
            operation: "reading the new commit"
        )
        let committedPathsData = try runRequired(
            [
                "--literal-pathspecs", "-C", before.snapshot.rootPath,
                "diff-tree", "--root", "--no-commit-id", "--name-only", "-r", "-z",
                "--no-renames", "--no-ext-diff", "--no-textconv", "HEAD",
            ],
            operation: "verifying the new commit"
        ).stdout
        let committedPaths = try nulTerminatedStrings(committedPathsData, context: "verifying committed paths")
        guard Set(committedPaths) == affectedSet else {
            throw DesktopGitError.postconditionFailed(
                "The commit contains paths outside the explicit selection. Inspect the repository before continuing."
            )
        }

        let after = try loadContext(for: URL(fileURLWithPath: before.snapshot.workspacePath, isDirectory: true))
        try verifyUnrelatedState(before: before, after: after, affectedPaths: affectedSet)
        try verifySelectedWorktreeWasNotModified(before: before, affectedPaths: affectedSet)
        return DesktopGitCommitResult(commitObjectID: commitObjectID, repository: after.snapshot)
    }

    func createAndSwitchBranch(
        named requestedName: String,
        in expectedRepository: DesktopGitRepositorySnapshot
    ) async throws -> DesktopGitBranchResult {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name == requestedName,
              !name.hasPrefix("-"),
              !name.contains("\u{0}") else {
            throw DesktopGitError.invalidBranchName(requestedName)
        }

        let before = try validatedContext(expectedRepository)
        guard !before.snapshot.isUnborn, let expectedHead = before.snapshot.headObjectID else {
            throw DesktopGitError.unbornHead
        }

        let validation = try runGit(["-C", before.snapshot.rootPath, "check-ref-format", "--branch", name])
        guard validation.status == 0,
              try requiredString(validation.stdout, context: "validating the branch name") == name else {
            throw DesktopGitError.invalidBranchName(name)
        }

        let existence = try runGit([
            "-C", before.snapshot.rootPath,
            "show-ref", "--verify", "--quiet", "refs/heads/\(name)",
        ])
        if existence.status == 0 { throw DesktopGitError.branchAlreadyExists(name) }
        if existence.status != 1 {
            throw commandFailure(existence, operation: "checking the branch name")
        }

        try runRequired(
            [
                "-c", "core.hooksPath=/dev/null",
                "-C", before.snapshot.rootPath,
                "switch", "--no-guess", "--no-recurse-submodules", "-c", name,
            ],
            operation: "creating the branch"
        )
        let after = try loadContext(for: URL(fileURLWithPath: before.snapshot.workspacePath, isDirectory: true))
        guard after.snapshot.branchName == name,
              after.snapshot.headObjectID == expectedHead,
              before.indexEntries == after.indexEntries,
              before.worktreeFingerprints == after.worktreeFingerprints else {
            throw DesktopGitError.postconditionFailed(
                "The branch changed unexpected repository state. Inspect the repository before continuing."
            )
        }
        return DesktopGitBranchResult(branchName: name, repository: after.snapshot)
    }

    // MARK: - Review diffs

    private func fileDiff(
        for change: DesktopGitFileChange,
        side: DesktopGitDiffSide,
        repository: DesktopGitRepositorySnapshot
    ) throws -> DesktopGitFileDiff {
        if change.isSubmodule {
            return unavailableDiff(change: change, side: side, reason: "Submodule diffs are not edited in Veo.")
        }
        if change.isUnmerged {
            return unavailableDiff(change: change, side: side, reason: "Resolve this conflict before staging hunks.")
        }
        if change.originalPath != nil {
            return unavailableDiff(change: change, side: side, reason: "Rename and copy changes use whole-file actions.")
        }

        let result: GitProcessResult
        if change.isUntracked && side == .unstaged {
            let fileURL = URL(fileURLWithPath: repository.rootPath, isDirectory: true)
                .appendingPathComponent(change.path, isDirectory: false)
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard !data.isEmpty,
                  data.count <= Self.maximumReviewPatchBytes,
                  let text = String(data: data, encoding: .utf8),
                  text.hasSuffix("\n") else {
                return unavailableDiff(change: change, side: side, reason: "This untracked file is empty, binary, unreadable, or larger than 8 MiB. Use Stage File.")
            }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last?.isEmpty == true { lines.removeLast() }
            let body = lines.map { "+" + $0 }.joined(separator: "\n")
            let mode = fileManager.isExecutableFile(atPath: fileURL.path) ? "100755" : "100644"
            let patch = """
            diff --git a/\(change.path) b/\(change.path)
            new file mode \(mode)
            --- /dev/null
            +++ b/\(change.path)
            @@ -0,0 +1,\(lines.count) @@
            \(body)
            """
            return parseFileDiff(patch, change: change, side: side)
        } else {
            var arguments = [
                "--literal-pathspecs", "-C", repository.rootPath,
                "diff", "--no-ext-diff", "--no-textconv", "--unified=3",
                "--src-prefix=a/", "--dst-prefix=b/",
            ]
            if side == .staged { arguments.append("--cached") }
            arguments.append(contentsOf: ["--", change.path])
            result = try runRequired(arguments, operation: "reading the \(side.rawValue) diff")
        }

        guard result.stdout.count <= Self.maximumReviewPatchBytes,
              let rawPatch = String(data: result.stdout, encoding: .utf8) else {
            return unavailableDiff(change: change, side: side, reason: "This patch is binary, unreadable, or larger than 8 MiB.")
        }
        if rawPatch.contains("Binary files ") || rawPatch.contains("GIT binary patch") {
            return DesktopGitFileDiff(
                id: .init(fileID: change.id, side: side),
                path: change.path,
                originalPath: change.originalPath,
                status: change.displayStatus,
                rawPatch: rawPatch,
                headerLines: [],
                hunks: [],
                additions: 0,
                deletions: 0,
                isBinary: true,
                unavailableReason: "Binary files use whole-file actions."
            )
        }
        return parseFileDiff(rawPatch, change: change, side: side)
    }

    private func unavailableDiff(
        change: DesktopGitFileChange,
        side: DesktopGitDiffSide,
        reason: String
    ) -> DesktopGitFileDiff {
        DesktopGitFileDiff(
            id: .init(fileID: change.id, side: side),
            path: change.path,
            originalPath: change.originalPath,
            status: change.displayStatus,
            rawPatch: "",
            headerLines: [],
            hunks: [],
            additions: 0,
            deletions: 0,
            isBinary: false,
            unavailableReason: reason
        )
    }

    private func parseFileDiff(
        _ rawPatch: String,
        change: DesktopGitFileChange,
        side: DesktopGitDiffSide
    ) -> DesktopGitFileDiff {
        var sourceLines = rawPatch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if sourceLines.last?.isEmpty == true { sourceLines.removeLast() }
        let firstHunkIndex = sourceLines.firstIndex(where: { $0.hasPrefix("@@ ") || $0.hasPrefix("@@-") })
            ?? sourceLines.count
        let headerLines = Array(sourceLines[..<firstHunkIndex])
        var hunks: [DesktopGitDiffHunk] = []
        var index = firstHunkIndex
        while index < sourceLines.count {
            guard sourceLines[index].hasPrefix("@@") else { index += 1; continue }
            let start = index
            index += 1
            while index < sourceLines.count, !sourceLines[index].hasPrefix("@@") { index += 1 }
            let patchLines = Array(sourceLines[start..<index])
            hunks.append(parseHunk(patchLines, ordinal: hunks.count))
        }
        return DesktopGitFileDiff(
            id: .init(fileID: change.id, side: side),
            path: change.path,
            originalPath: change.originalPath,
            status: change.displayStatus,
            rawPatch: rawPatch,
            headerLines: headerLines,
            hunks: hunks,
            additions: hunks.reduce(0) { $0 + $1.additions },
            deletions: hunks.reduce(0) { $0 + $1.deletions },
            isBinary: false,
            unavailableReason: rawPatch.isEmpty ? "No textual diff is available." : nil
        )
    }

    private func parseHunk(_ patchLines: [String], ordinal: Int) -> DesktopGitDiffHunk {
        let header = patchLines.first ?? "@@"
        let ranges = parseHunkRanges(header)
        var oldLine = ranges.old
        var newLine = ranges.new
        var lines: [DesktopGitDiffLine] = []
        var additions = 0
        var deletions = 0
        for (lineIndex, source) in patchLines.dropFirst().enumerated() {
            let kind: DesktopGitDiffLineKind
            let oldNumber: Int?
            let newNumber: Int?
            if source.hasPrefix("+") {
                kind = .addition
                oldNumber = nil
                newNumber = newLine
                newLine += 1
                additions += 1
            } else if source.hasPrefix("-") {
                kind = .deletion
                oldNumber = oldLine
                newNumber = nil
                oldLine += 1
                deletions += 1
            } else if source.hasPrefix("\\") {
                kind = .metadata
                oldNumber = nil
                newNumber = nil
            } else {
                kind = .context
                oldNumber = oldLine
                newNumber = newLine
                oldLine += 1
                newLine += 1
            }
            lines.append(DesktopGitDiffLine(
                id: "\(ordinal):\(lineIndex)",
                oldLineNumber: oldNumber,
                newLineNumber: newNumber,
                kind: kind,
                text: source
            ))
        }
        let patch = patchLines.joined(separator: "\n")
        let id = SHA256.hash(data: Data(patch.utf8)).map { String(format: "%02x", $0) }.joined()
        return DesktopGitDiffHunk(
            id: id,
            header: header,
            patch: patch,
            lines: lines,
            additions: additions,
            deletions: deletions
        )
    }

    private func parseHunkRanges(_ header: String) -> (old: Int, new: Int) {
        let parts = header.split(separator: " ")
        func start(_ token: Substring?, marker: Character) -> Int {
            guard let token, token.first == marker else { return 0 }
            return Int(token.dropFirst().split(separator: ",").first ?? "0") ?? 0
        }
        return (start(parts[safe: 1], marker: "-"), start(parts[safe: 2], marker: "+"))
    }

    // MARK: - Snapshot loading

    private func loadContext(for workspaceURL: URL) throws -> RepositoryContext {
        let workspacePath = try canonicalWorkspacePath(workspaceURL)
        let rootResult = try runGit([
            "-C", workspacePath,
            "rev-parse", "--path-format=absolute", "--show-toplevel",
        ])
        guard rootResult.status == 0 else {
            throw DesktopGitError.repositoryNotFound(workspacePath)
        }
        let rootPath = try canonicalPath(
            requiredString(rootResult.stdout, context: "discovering the repository root")
        )
        guard path(workspacePath, isInside: rootPath) else {
            throw DesktopGitError.invalidWorkspace(workspacePath)
        }

        let gitDirectoryPath = try canonicalPath(requiredText(
            ["-C", rootPath, "rev-parse", "--path-format=absolute", "--git-dir"],
            operation: "discovering the Git directory"
        ))
        let commonDirectoryPath = try canonicalPath(requiredText(
            ["-C", rootPath, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            operation: "discovering the common Git directory"
        ))

        let workspaceRelativePath = relativePath(workspacePath, inside: rootPath)
        let statusData = try runRequired(
            [
                "-C", rootPath,
                "status", "--porcelain=v2", "--branch", "-z",
                "--untracked-files=all", "--ignore-submodules=none",
            ],
            operation: "reading repository status"
        ).stdout
        let parsedStatus = try parseStatus(
            statusData,
            workspaceRelativePath: workspaceRelativePath,
            repositoryRoot: rootPath
        )
        let indexData = try runRequired(
            ["-C", rootPath, "ls-files", "--stage", "-z"],
            operation: "reading the Git index"
        ).stdout
        let indexEntries = try parseIndexEntries(indexData)
        let operationState = detectOperation(gitDirectoryPath: gitDirectoryPath, commonDirectoryPath: commonDirectoryPath)
        let indexLockPath = URL(fileURLWithPath: gitDirectoryPath, isDirectory: true)
            .appendingPathComponent("index.lock").path
        let isIndexLocked = fileManager.fileExists(atPath: indexLockPath)

        var fingerprints: [String: String] = [:]
        for path in Set(parsedStatus.files.flatMap(\.mutationPaths)).sorted() {
            try validateRepositoryRelativePath(path, repositoryRoot: rootPath)
            fingerprints[path] = try worktreeFingerprint(repositoryRoot: rootPath, relativePath: path)
        }

        let snapshotID = makeSnapshotID(
            workspacePath: workspacePath,
            rootPath: rootPath,
            gitDirectoryPath: gitDirectoryPath,
            commonDirectoryPath: commonDirectoryPath,
            statusData: statusData,
            indexData: indexData,
            operationState: operationState,
            isIndexLocked: isIndexLocked,
            fingerprints: fingerprints
        )
        let snapshot = DesktopGitRepositorySnapshot(
            id: snapshotID,
            workspacePath: workspacePath,
            workspaceRelativePath: workspaceRelativePath,
            rootPath: rootPath,
            gitDirectoryPath: gitDirectoryPath,
            commonDirectoryPath: commonDirectoryPath,
            headObjectID: parsedStatus.headObjectID,
            branchName: parsedStatus.branchName,
            isDetached: parsedStatus.isDetached,
            isUnborn: parsedStatus.isUnborn,
            operationState: operationState,
            isIndexLocked: isIndexLocked,
            files: parsedStatus.files,
            capturedAt: Date()
        )
        return RepositoryContext(
            snapshot: snapshot,
            indexEntries: indexEntries,
            worktreeFingerprints: fingerprints
        )
    }

    private func validatedContext(_ expected: DesktopGitRepositorySnapshot) throws -> RepositoryContext {
        let current = try loadContext(
            for: URL(fileURLWithPath: expected.workspacePath, isDirectory: true)
        )
        guard current.snapshot.id == expected.id,
              current.snapshot.rootPath == expected.rootPath,
              current.snapshot.commonDirectoryPath == expected.commonDirectoryPath else {
            throw DesktopGitError.staleSnapshot
        }
        if current.snapshot.operationState != .none {
            throw DesktopGitError.operationInProgress(current.snapshot.operationState)
        }
        if current.snapshot.isIndexLocked { throw DesktopGitError.indexLocked }
        if !current.snapshot.conflictedFiles.isEmpty { throw DesktopGitError.conflictsPresent }
        return current
    }

    // MARK: - Selection and safety

    private func selectedChanges(
        _ fileIDs: [DesktopGitFileID],
        in repository: DesktopGitRepositorySnapshot
    ) throws -> [DesktopGitFileChange] {
        guard !fileIDs.isEmpty, Set(fileIDs).count == fileIDs.count else {
            throw DesktopGitError.invalidSelection
        }
        let changesByID = Dictionary(uniqueKeysWithValues: repository.files.map { ($0.id, $0) })
        let changes = try fileIDs.map { id -> DesktopGitFileChange in
            guard let change = changesByID[id] else { throw DesktopGitError.invalidSelection }
            guard change.isInWorkspace else { throw DesktopGitError.pathOutsideWorkspace(change.path) }
            guard !change.isSubmodule else {
                throw DesktopGitError.submoduleMutationUnsupported(change.path)
            }
            return change
        }
        return changes
    }

    private func validatedMutationPaths(
        for changes: [DesktopGitFileChange],
        repository: DesktopGitRepositorySnapshot
    ) throws -> [String] {
        try validatedPaths(changes.flatMap(\.mutationPaths), repository: repository)
    }

    private func validatedPaths(
        _ requestedPaths: [String],
        repository: DesktopGitRepositorySnapshot
    ) throws -> [String] {
        var paths: [String] = []
        for path in requestedPaths {
            try validateRepositoryRelativePath(path, repositoryRoot: repository.rootPath)
            guard pathIsInWorkspace(path, workspaceRelativePath: repository.workspaceRelativePath) else {
                throw DesktopGitError.pathOutsideWorkspace(path)
            }
            paths.append(path)
        }
        return paths.uniquedAndSorted()
    }

    private func validateRepositoryRelativePath(_ path: String, repositoryRoot: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\u{0}"),
              !path.contains("//") else {
            throw DesktopGitError.invalidPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains("."),
              !components.contains(".."),
              components.first?.lowercased() != ".git" else {
            throw DesktopGitError.invalidPath(path)
        }
        let rootURL = URL(fileURLWithPath: repositoryRoot, isDirectory: true)
        let candidateURL = rootURL
            .appendingPathComponent(path, isDirectory: false)
            .standardizedFileURL
        let candidate = candidateURL.path
        guard self.path(candidate, isInside: repositoryRoot), candidate != repositoryRoot else {
            throw DesktopGitError.invalidPath(path)
        }
        let resolvedParent = candidateURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().path
        guard self.path(resolvedParent, isInside: repositoryRoot) else {
            throw DesktopGitError.invalidPath(path)
        }
    }

    private func verifyUnrelatedState(
        before: RepositoryContext,
        after: RepositoryContext,
        affectedPaths: Set<String>
    ) throws {
        let beforeIndex = before.indexEntries.filter { !affectedPaths.contains($0.key) }
        let afterIndex = after.indexEntries.filter { !affectedPaths.contains($0.key) }
        guard beforeIndex == afterIndex else { throw DesktopGitError.unrelatedIndexChanged }

        let beforeWorktree = before.worktreeFingerprints.filter { !affectedPaths.contains($0.key) }
        let afterWorktree = after.worktreeFingerprints.filter { !affectedPaths.contains($0.key) }
        guard beforeWorktree == afterWorktree else {
            throw DesktopGitError.postconditionFailed(
                "A working-tree file outside the explicit selection changed during the Git action."
            )
        }
    }

    private func verifySelectedWorktreeWasNotModified(
        before: RepositoryContext,
        affectedPaths: Set<String>
    ) throws {
        for path in affectedPaths {
            guard let expected = before.worktreeFingerprints[path] else { continue }
            let current = try worktreeFingerprint(
                repositoryRoot: before.snapshot.rootPath,
                relativePath: path
            )
            guard current == expected else {
                throw DesktopGitError.postconditionFailed(
                    "\(path) changed while Git was running. Refresh and inspect it before continuing."
                )
            }
        }
    }

    // MARK: - Recovery

    private func recoveryPatches(
        for paths: [String],
        context: RepositoryContext
    ) throws -> (staged: Data, worktree: Data) {
        let base: String
        if let head = context.snapshot.headObjectID {
            base = head
        } else {
            base = try requiredText(
                ["-C", context.snapshot.rootPath, "hash-object", "-t", "tree", "--stdin"],
                operation: "computing the empty tree",
                stdin: Data()
            )
        }
        let staged = try runRequired(
            [
                "--literal-pathspecs", "-C", context.snapshot.rootPath,
                "diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv",
                "--cached", base, "--",
            ] + paths,
            operation: "creating the staged recovery patch"
        ).stdout
        let worktree = try runRequired(
            [
                "--literal-pathspecs", "-C", context.snapshot.rootPath,
                "diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "--",
            ] + paths,
            operation: "creating the worktree recovery patch"
        ).stdout
        return (staged, worktree)
    }

    // MARK: - Porcelain parsing

    private func parseStatus(
        _ data: Data,
        workspaceRelativePath: String?,
        repositoryRoot: String
    ) throws -> ParsedStatus {
        let records = data.split(separator: 0, omittingEmptySubsequences: true)
        var branchName: String?
        var headObjectID: String?
        var isDetached = false
        var isUnborn = false
        var files: [DesktopGitFileChange] = []
        var index = 0

        while index < records.count {
            let recordData = records[index]
            guard let record = String(bytes: recordData, encoding: .utf8) else {
                throw DesktopGitError.malformedGitOutput("decoding a repository path")
            }
            if record.hasPrefix("# branch.oid ") {
                let value = String(record.dropFirst("# branch.oid ".count))
                if value == "(initial)" {
                    isUnborn = true
                } else {
                    headObjectID = value
                }
            } else if record.hasPrefix("# branch.head ") {
                let value = String(record.dropFirst("# branch.head ".count))
                if value == "(detached)" {
                    isDetached = true
                } else {
                    branchName = value
                }
            } else if record.hasPrefix("1 ") {
                let parsed = try fixedTokensAndPath(record, tokenCount: 8)
                files.append(try ordinaryChange(
                    tokens: parsed.tokens,
                    path: parsed.path,
                    originalPath: nil,
                    kind: .ordinary,
                    workspaceRelativePath: workspaceRelativePath,
                    repositoryRoot: repositoryRoot
                ))
            } else if record.hasPrefix("2 ") {
                let parsed = try fixedTokensAndPath(record, tokenCount: 9)
                index += 1
                guard index < records.count,
                      let originalPath = String(bytes: records[index], encoding: .utf8) else {
                    throw DesktopGitError.malformedGitOutput("reading a renamed path")
                }
                files.append(try ordinaryChange(
                    tokens: parsed.tokens,
                    path: parsed.path,
                    originalPath: originalPath,
                    kind: .renameOrCopy,
                    workspaceRelativePath: workspaceRelativePath,
                    repositoryRoot: repositoryRoot
                ))
            } else if record.hasPrefix("u ") {
                let parsed = try fixedTokensAndPath(record, tokenCount: 10)
                let xy = parsed.tokens[1]
                try validateRepositoryRelativePath(parsed.path, repositoryRoot: repositoryRoot)
                files.append(DesktopGitFileChange(
                    id: DesktopGitFileID(path: parsed.path, originalPath: nil),
                    recordKind: .unmerged,
                    indexStatus: .unmerged,
                    worktreeStatus: .unmerged,
                    submoduleState: parsed.tokens[2],
                    headMode: parsed.tokens[3],
                    indexMode: parsed.tokens[4],
                    worktreeMode: parsed.tokens[6],
                    headObjectID: parsed.tokens[7],
                    indexObjectID: parsed.tokens[8],
                    isInWorkspace: pathIsInWorkspace(parsed.path, workspaceRelativePath: workspaceRelativePath)
                ))
                _ = xy
            } else if record.hasPrefix("? ") {
                let path = String(record.dropFirst(2))
                try validateRepositoryRelativePath(path, repositoryRoot: repositoryRoot)
                files.append(DesktopGitFileChange(
                    id: DesktopGitFileID(path: path, originalPath: nil),
                    recordKind: .untracked,
                    indexStatus: .unchanged,
                    worktreeStatus: .unknown,
                    submoduleState: "N...",
                    headMode: nil,
                    indexMode: nil,
                    worktreeMode: nil,
                    headObjectID: nil,
                    indexObjectID: nil,
                    isInWorkspace: pathIsInWorkspace(path, workspaceRelativePath: workspaceRelativePath)
                ))
            } else if !record.hasPrefix("# ") && !record.hasPrefix("! ") {
                throw DesktopGitError.malformedGitOutput("parsing porcelain v2 status")
            }
            index += 1
        }

        return ParsedStatus(
            branchName: branchName,
            headObjectID: headObjectID,
            isDetached: isDetached,
            isUnborn: isUnborn,
            files: files.sorted { lhs, rhs in
                lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
        )
    }

    private func ordinaryChange(
        tokens: [String],
        path: String,
        originalPath: String?,
        kind: DesktopGitRecordKind,
        workspaceRelativePath: String?,
        repositoryRoot: String
    ) throws -> DesktopGitFileChange {
        guard tokens.count >= 8, tokens[1].count == 2 else {
            throw DesktopGitError.malformedGitOutput("parsing a changed file")
        }
        try validateRepositoryRelativePath(path, repositoryRoot: repositoryRoot)
        if let originalPath {
            try validateRepositoryRelativePath(originalPath, repositoryRoot: repositoryRoot)
        }
        let xy = Array(tokens[1])
        let indexStatus = DesktopGitStatusCode(character: xy.first)
        let worktreeStatus = DesktopGitStatusCode(character: xy.last)
        let mutatesOriginalPath = indexStatus == .renamed || worktreeStatus == .renamed
        let inWorkspace = pathIsInWorkspace(path, workspaceRelativePath: workspaceRelativePath)
            && (!mutatesOriginalPath
                || originalPath.map {
                    pathIsInWorkspace($0, workspaceRelativePath: workspaceRelativePath)
                } != false)
        return DesktopGitFileChange(
            id: DesktopGitFileID(path: path, originalPath: originalPath),
            recordKind: kind,
            indexStatus: indexStatus,
            worktreeStatus: worktreeStatus,
            submoduleState: tokens[2],
            headMode: tokens[3],
            indexMode: tokens[4],
            worktreeMode: tokens[5],
            headObjectID: tokens[6],
            indexObjectID: tokens[7],
            isInWorkspace: inWorkspace
        )
    }

    private func fixedTokensAndPath(
        _ record: String,
        tokenCount: Int
    ) throws -> (tokens: [String], path: String) {
        var tokens: [String] = []
        var cursor = record.startIndex
        for _ in 0..<tokenCount {
            guard let separator = record[cursor...].firstIndex(of: " ") else {
                throw DesktopGitError.malformedGitOutput("parsing a status record")
            }
            tokens.append(String(record[cursor..<separator]))
            cursor = record.index(after: separator)
        }
        let path = String(record[cursor...])
        guard !path.isEmpty else {
            throw DesktopGitError.malformedGitOutput("reading a status path")
        }
        return (tokens, path)
    }

    private func parseIndexEntries(_ data: Data) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: 0x09),
                  let metadata = String(bytes: record[..<tab], encoding: .utf8),
                  let path = String(bytes: record[record.index(after: tab)...], encoding: .utf8) else {
                throw DesktopGitError.malformedGitOutput("reading Git index entries")
            }
            result[path, default: []].append(metadata)
        }
        return result.mapValues { $0.sorted() }
    }

    // MARK: - Repository fingerprints

    private func makeSnapshotID(
        workspacePath: String,
        rootPath: String,
        gitDirectoryPath: String,
        commonDirectoryPath: String,
        statusData: Data,
        indexData: Data,
        operationState: DesktopGitOperationState,
        isIndexLocked: Bool,
        fingerprints: [String: String]
    ) -> DesktopGitSnapshotID {
        var hasher = SHA256()
        for value in [workspacePath, rootPath, gitDirectoryPath, commonDirectoryPath, operationState.rawValue, String(isIndexLocked)] {
            update(&hasher, with: Data(value.utf8))
        }
        update(&hasher, with: statusData)
        update(&hasher, with: indexData)
        for key in fingerprints.keys.sorted() {
            update(&hasher, with: Data(key.utf8))
            update(&hasher, with: Data((fingerprints[key] ?? "").utf8))
        }
        return DesktopGitSnapshotID(rawValue: hexString(hasher.finalize()))
    }

    private func update(_ hasher: inout SHA256, with data: Data) {
        hasher.update(data: Data("\(data.count):".utf8))
        hasher.update(data: data)
    }

    private func worktreeFingerprint(repositoryRoot: String, relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: repositoryRoot, isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return "absent"
        } catch {
            if !itemExistsWithoutFollowingFinalSymlink(at: url) { return "absent" }
            throw error
        }

        let type = attributes[.type] as? FileAttributeType
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.stringValue ?? ""
        var hasher = SHA256()
        update(&hasher, with: Data((type?.rawValue ?? "unknown").utf8))
        update(&hasher, with: Data(permissions.utf8))

        if type == .typeSymbolicLink {
            let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            update(&hasher, with: Data(destination.utf8))
        } else if type == .typeRegular {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } else {
            let size = (attributes[.size] as? NSNumber)?.stringValue ?? ""
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970.description ?? ""
            update(&hasher, with: Data("\(size):\(modified)".utf8))
        }
        return hexString(hasher.finalize())
    }

    private func detectOperation(
        gitDirectoryPath: String,
        commonDirectoryPath: String
    ) -> DesktopGitOperationState {
        let gitDirectory = URL(fileURLWithPath: gitDirectoryPath, isDirectory: true)
        let commonDirectory = URL(fileURLWithPath: commonDirectoryPath, isDirectory: true)
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: gitDirectory.appendingPathComponent(name).path)
                || fileManager.fileExists(atPath: commonDirectory.appendingPathComponent(name).path)
        }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        if exists("BISECT_LOG") { return .bisect }
        if exists("sequencer") { return .sequencer }
        return .none
    }

    // MARK: - Paths

    private func canonicalWorkspacePath(_ url: URL) throws -> String {
        guard url.isFileURL else { throw DesktopGitError.invalidWorkspace(url.absoluteString) }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DesktopGitError.invalidWorkspace(path)
        }
        return path
    }

    private func canonicalPath(_ path: String) throws -> String {
        let canonical = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath().path
        guard !canonical.isEmpty else { throw DesktopGitError.invalidWorkspace(path) }
        return canonical
    }

    private func relativePath(_ candidate: String, inside root: String) -> String? {
        guard candidate != root else { return nil }
        return String(candidate.dropFirst(root.count + 1))
    }

    private func path(_ candidate: String, isInside root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root + "/")
    }

    private func pathIsInWorkspace(_ path: String, workspaceRelativePath: String?) -> Bool {
        guard let prefix = workspaceRelativePath, !prefix.isEmpty else { return true }
        return path == prefix || path.hasPrefix(prefix + "/")
    }

    private func itemExistsWithoutFollowingFinalSymlink(at url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) { return true }
        return (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    // MARK: - Process execution

    @discardableResult
    private func runRequired(
        _ arguments: [String],
        operation: String,
        stdin: Data? = nil
    ) throws -> GitProcessResult {
        let result = try runGit(arguments, stdin: stdin)
        guard result.status == 0 else { throw commandFailure(result, operation: operation) }
        return result
    }

    private func requiredText(
        _ arguments: [String],
        operation: String,
        stdin: Data? = nil
    ) throws -> String {
        let result = try runRequired(arguments, operation: operation, stdin: stdin)
        return try requiredString(result.stdout, context: operation)
    }

    private func requiredString(_ data: Data, context: String) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw DesktopGitError.malformedGitOutput(context)
        }
        return value.trimmingCharacters(in: .newlines)
    }

    private func nulTerminatedStrings(_ data: Data, context: String) throws -> [String] {
        try data.split(separator: 0, omittingEmptySubsequences: true).map { record in
            guard let value = String(bytes: record, encoding: .utf8) else {
                throw DesktopGitError.malformedGitOutput(context)
            }
            return value
        }
    }

    private func commandFailure(_ result: GitProcessResult, operation: String) -> DesktopGitError {
        let stderr = String(data: result.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = stderr?.isEmpty == false ? stderr! : "Git failed while \(operation)."
        return .gitCommandFailed(operation: operation, status: result.status, message: message)
    }

    private func runGit(_ arguments: [String], stdin: Data? = nil) throws -> GitProcessResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        let outputBox = DataBox()
        let errorBox = DataBox()
        let group = DispatchGroup()

        guard fileManager.isExecutableFile(atPath: sandboxExecutableURL.path),
              fileManager.isExecutableFile(atPath: gitExecutableURL.path) else {
            throw DesktopGitError.gitLaunchFailed("The trusted Git sandbox is unavailable.")
        }
        let hardenedArguments = [
            "-c", "core.fsmonitor=false",
            "-c", "core.untrackedCache=false",
            "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgSign=false",
            "-c", "tag.gpgSign=false",
            "-c", "credential.helper=",
        ] + arguments
        process.executableURL = sandboxExecutableURL
        process.arguments = [
            "-p", gitSandboxProfile(),
            gitExecutableURL.path,
        ] + hardenedArguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") {
            environment.removeValue(forKey: key)
        }
        environment.removeValue(forKey: "DEVELOPER_DIR")
        environment.removeValue(forKey: "TOOLCHAINS")
        environment.removeValue(forKey: "SDKROOT")
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GCM_INTERACTIVE"] = "Never"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_ATTR_NOSYSTEM"] = "1"
        process.environment = environment

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.set(outputPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorBox.set(errorPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        do {
            try process.run()
        } catch {
            inputPipe.fileHandleForWriting.closeFile()
            outputPipe.fileHandleForReading.closeFile()
            errorPipe.fileHandleForReading.closeFile()
            group.wait()
            throw DesktopGitError.gitLaunchFailed(error.localizedDescription)
        }

        if let stdin, !stdin.isEmpty {
            inputPipe.fileHandleForWriting.write(stdin)
        }
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        group.wait()
        return GitProcessResult(
            status: process.terminationStatus,
            stdout: outputBox.value(),
            stderr: errorBox.value()
        )
    }

    private func gitSandboxProfile() -> String {
        let escapedGitPath = gitExecutableURL.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny process-exec)
        (allow process-exec (literal "\(escapedGitPath)"))
        """
    }
}

private extension Array where Element == String {
    func uniquedAndSorted() -> [String] {
        Array(Set(self)).sorted()
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private func hexString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
    digest.map { String(format: "%02x", $0) }.joined()
}
