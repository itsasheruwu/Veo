// FILE: DesktopGitModels.swift
// Purpose: Defines repository snapshots and typed requests/results for Veo's local Git controls.
// Layer: Desktop app model
// Depends on: Foundation

import Foundation

struct DesktopGitSnapshotID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    var description: String { rawValue }
}

struct DesktopGitFileID: Hashable, Sendable, Codable, Identifiable {
    let path: String
    let originalPath: String?

    var id: String {
        if let originalPath {
            return "\(originalPath)\u{0}\(path)"
        }
        return path
    }
}

enum DesktopGitStatusCode: String, Sendable, Codable, Hashable {
    case unchanged = "."
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case typeChanged = "T"
    case unmerged = "U"
    case unknown = "?"

    init(character: Character?) {
        guard let character else {
            self = .unknown
            return
        }
        self = DesktopGitStatusCode(rawValue: String(character)) ?? .unknown
    }

    var isChanged: Bool { self != .unchanged }

    var label: String {
        switch self {
        case .unchanged: return "Unchanged"
        case .modified: return "Modified"
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .typeChanged: return "Type changed"
        case .unmerged: return "Unmerged"
        case .unknown: return "Changed"
        }
    }
}

enum DesktopGitRecordKind: String, Sendable, Codable, Hashable {
    case ordinary
    case renameOrCopy
    case unmerged
    case untracked
}

struct DesktopGitFileChange: Sendable, Codable, Hashable, Identifiable {
    let id: DesktopGitFileID
    let recordKind: DesktopGitRecordKind
    let indexStatus: DesktopGitStatusCode
    let worktreeStatus: DesktopGitStatusCode
    let submoduleState: String
    let headMode: String?
    let indexMode: String?
    let worktreeMode: String?
    let headObjectID: String?
    let indexObjectID: String?
    let isInWorkspace: Bool

    var path: String { id.path }
    var originalPath: String? { id.originalPath }
    var isUntracked: Bool { recordKind == .untracked }
    var isUnmerged: Bool { recordKind == .unmerged }
    var isSubmodule: Bool { submoduleState.first == "S" }
    var hasStagedChanges: Bool { !isUntracked && indexStatus.isChanged }
    var hasUnstagedChanges: Bool { isUntracked || worktreeStatus.isChanged }
    var isPartiallyStaged: Bool { hasStagedChanges && hasUnstagedChanges }

    var mutationPaths: [String] {
        var paths: [String] = []
        // A rename moves the source path, so both sides belong to the mutation.
        // A copy only creates/updates the destination; including its source would
        // let a destination-only selection modify unrelated source state.
        if (indexStatus == .renamed || worktreeStatus == .renamed),
           let originalPath {
            paths.append(originalPath)
        }
        paths.append(path)
        return paths
    }

    var worktreeMutationPaths: [String] {
        var paths: [String] = []
        if worktreeStatus == .renamed, let originalPath {
            paths.append(originalPath)
        }
        paths.append(path)
        return paths
    }

    var displayStatus: String {
        if isUntracked { return "Untracked" }
        if isUnmerged { return "Conflict" }
        if isPartiallyStaged { return "Partially staged" }
        if hasStagedChanges { return indexStatus.label }
        return worktreeStatus.label
    }
}

enum DesktopGitOperationState: String, Sendable, Codable, Hashable {
    case none
    case merge
    case rebase
    case cherryPick
    case revert
    case bisect
    case sequencer

    var label: String {
        switch self {
        case .none: return "Ready"
        case .merge: return "Merge in progress"
        case .rebase: return "Rebase in progress"
        case .cherryPick: return "Cherry-pick in progress"
        case .revert: return "Revert in progress"
        case .bisect: return "Bisect in progress"
        case .sequencer: return "Git operation in progress"
        }
    }
}

struct DesktopGitRepositorySnapshot: Sendable, Codable, Hashable {
    let id: DesktopGitSnapshotID
    let workspacePath: String
    let workspaceRelativePath: String?
    let rootPath: String
    let gitDirectoryPath: String
    let commonDirectoryPath: String
    let headObjectID: String?
    let branchName: String?
    let isDetached: Bool
    let isUnborn: Bool
    let operationState: DesktopGitOperationState
    let isIndexLocked: Bool
    let files: [DesktopGitFileChange]
    let capturedAt: Date

    var stagedFiles: [DesktopGitFileChange] {
        files.filter(\.hasStagedChanges)
    }

    var unstagedFiles: [DesktopGitFileChange] {
        files.filter { $0.hasUnstagedChanges && !$0.isUntracked && !$0.isUnmerged }
    }

    var untrackedFiles: [DesktopGitFileChange] {
        files.filter(\.isUntracked)
    }

    var conflictedFiles: [DesktopGitFileChange] {
        files.filter(\.isUnmerged)
    }

    var mutationBlocker: String? {
        if operationState != .none { return operationState.label }
        if isIndexLocked { return "Another Git process is using this repository." }
        if !conflictedFiles.isEmpty { return "Resolve repository conflicts before using Veo Git actions." }
        return nil
    }

    var canMutate: Bool { mutationBlocker == nil }
}

enum DesktopGitDiscardMode: String, Sendable, Codable, Hashable {
    case unstagedOnly
    case allChanges
}

enum DesktopGitDiffSide: String, Sendable, Codable, Hashable, Identifiable {
    case staged
    case unstaged

    var id: Self { self }
    var title: String { self == .staged ? "Staged" : "Unstaged" }
}

enum DesktopGitDiffLineKind: String, Sendable, Codable, Hashable {
    case context
    case addition
    case deletion
    case metadata
}

struct DesktopGitDiffLine: Sendable, Codable, Hashable, Identifiable {
    let id: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let kind: DesktopGitDiffLineKind
    let text: String
}

struct DesktopGitDiffHunk: Sendable, Codable, Hashable, Identifiable {
    let id: String
    let header: String
    let patch: String
    let lines: [DesktopGitDiffLine]
    let additions: Int
    let deletions: Int

    var isWhitespaceOnly: Bool {
        let removed = lines.filter { $0.kind == .deletion }.map(\.text)
        let added = lines.filter { $0.kind == .addition }.map(\.text)
        guard !removed.isEmpty || !added.isEmpty else { return false }
        return removed.map(Self.withoutWhitespace) == added.map(Self.withoutWhitespace)
    }

    private static func withoutWhitespace(_ value: String) -> String {
        value.filter { !$0.isWhitespace }
    }
}

struct DesktopGitFileDiffID: Sendable, Codable, Hashable, Identifiable {
    let fileID: DesktopGitFileID
    let side: DesktopGitDiffSide

    var id: String { "\(side.rawValue):\(fileID.id)" }
}

struct DesktopGitFileDiff: Sendable, Codable, Hashable, Identifiable {
    let id: DesktopGitFileDiffID
    let path: String
    let originalPath: String?
    let status: String
    let rawPatch: String
    let headerLines: [String]
    let hunks: [DesktopGitDiffHunk]
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let unavailableReason: String?

    var side: DesktopGitDiffSide { id.side }
}

struct DesktopGitReviewSnapshot: Sendable, Codable, Hashable {
    let repositoryID: DesktopGitSnapshotID
    let files: [DesktopGitFileDiff]
    let capturedAt: Date
}

struct DesktopGitHunkSelection: Sendable, Codable, Hashable {
    let fileDiffID: DesktopGitFileDiffID
    let hunkID: String
}

struct DesktopGitRecoveryReceipt: Sendable, Codable, Hashable, Identifiable {
    let id: String
    let bundlePath: String
    let repositoryRoot: String
    let paths: [String]
    let createdAt: Date
}

struct DesktopGitMutationResult: Sendable {
    let repository: DesktopGitRepositorySnapshot
    let recovery: DesktopGitRecoveryReceipt?
}

struct DesktopGitCommitResult: Sendable {
    let commitObjectID: String
    let repository: DesktopGitRepositorySnapshot
}

struct DesktopGitBranchResult: Sendable {
    let branchName: String
    let repository: DesktopGitRepositorySnapshot
}

enum DesktopGitError: LocalizedError, Sendable {
    case invalidWorkspace(String)
    case repositoryNotFound(String)
    case invalidPath(String)
    case pathOutsideWorkspace(String)
    case invalidSelection
    case staleSnapshot
    case operationInProgress(DesktopGitOperationState)
    case indexLocked
    case conflictsPresent
    case partialStaging(String)
    case submoduleMutationUnsupported(String)
    case nothingToDo
    case detachedHead
    case unbornHead
    case invalidBranchName(String)
    case branchAlreadyExists(String)
    case commitMessageRequired
    case commitSelectionRequiresFullyStaged(String)
    case gitLaunchFailed(String)
    case gitCommandFailed(operation: String, status: Int32, message: String)
    case malformedGitOutput(String)
    case unrelatedIndexChanged
    case postconditionFailed(String)
    case recoveryFailed(String)
    case trashFailed(String)
    case diffUnavailable(String)
    case hunkUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace(let path):
            return "The selected workspace is not a readable folder: \(path)"
        case .repositoryNotFound(let path):
            return "No Git repository contains \(path)."
        case .invalidPath(let path):
            return "Git returned an unsafe path and Veo refused to use it: \(path)"
        case .pathOutsideWorkspace(let path):
            return "\(path) is outside the selected workspace."
        case .invalidSelection:
            return "The selected files no longer match this repository snapshot."
        case .staleSnapshot:
            return "The repository changed. Refresh Changes and try again."
        case .operationInProgress(let operation):
            return operation.label + ". Finish it in Git before using these actions."
        case .indexLocked:
            return "Another Git process is using this repository."
        case .conflictsPresent:
            return "Resolve repository conflicts before using Veo Git actions."
        case .partialStaging(let path):
            return "\(path) is partially staged. Choose an action that preserves its staged split."
        case .submoduleMutationUnsupported(let path):
            return "Veo will not modify nested submodule state for \(path)."
        case .nothingToDo:
            return "There are no matching changes to apply."
        case .detachedHead:
            return "Create or select a branch before committing."
        case .unbornHead:
            return "This action requires an existing commit."
        case .invalidBranchName(let name):
            return "\(name) is not a valid Git branch name."
        case .branchAlreadyExists(let name):
            return "A local branch named \(name) already exists."
        case .commitMessageRequired:
            return "Enter a commit message."
        case .commitSelectionRequiresFullyStaged(let path):
            return "\(path) must be staged with no remaining unstaged changes before committing it."
        case .gitLaunchFailed(let message):
            return "Git could not start: \(message)"
        case .gitCommandFailed(_, _, let message):
            return message
        case .malformedGitOutput(let context):
            return "Git returned unreadable data while \(context)."
        case .unrelatedIndexChanged:
            return "Git changed an index entry outside the requested files. Refresh before continuing."
        case .postconditionFailed(let message):
            return message
        case .recoveryFailed(let message):
            return "A recovery copy could not be created: \(message)"
        case .trashFailed(let message):
            return message
        case .diffUnavailable(let path):
            return "The diff for \(path) is unavailable or too large to review safely."
        case .hunkUnavailable(let path):
            return "That hunk in \(path) is no longer available. Refresh Review and try again."
        }
    }
}
