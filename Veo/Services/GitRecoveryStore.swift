// FILE: GitRecoveryStore.swift
// Purpose: Creates target-scoped recovery bundles before destructive local Git actions.
// Layer: Desktop app service
// Depends on: DesktopGitModels, Foundation

import Foundation

actor DesktopGitRecoveryStore {
    private struct Manifest: Codable {
        let version: Int
        let createdAt: Date
        let repositoryRoot: String
        let workspacePath: String
        let snapshotID: String
        let headObjectID: String?
        let branchName: String?
        let paths: [String]
        let copiedPaths: [String]
        let stagedPatchFile: String
        let worktreePatchFile: String
    }

    private let fileManager: FileManager
    private let baseDirectoryURL: URL

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        if let baseDirectoryURL {
            self.baseDirectoryURL = baseDirectoryURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.baseDirectoryURL = applicationSupport
                .appendingPathComponent("com.ash.Veo", isDirectory: true)
                .appendingPathComponent("GitRecovery", isDirectory: true)
        }
    }

    func createBundle(
        repository: DesktopGitRepositorySnapshot,
        paths: [String],
        stagedPatch: Data,
        worktreePatch: Data
    ) throws -> DesktopGitRecoveryReceipt {
        let identifier = UUID().uuidString
        let createdAt = Date()
        let bundleURL = baseDirectoryURL.appendingPathComponent(identifier, isDirectory: true)
        let filesURL = bundleURL.appendingPathComponent("files", isDirectory: true)

        do {
            try fileManager.createDirectory(at: filesURL, withIntermediateDirectories: true)
            try stagedPatch.write(
                to: bundleURL.appendingPathComponent("staged.patch"),
                options: .atomic
            )
            try worktreePatch.write(
                to: bundleURL.appendingPathComponent("worktree.patch"),
                options: .atomic
            )

            let rootURL = URL(fileURLWithPath: repository.rootPath, isDirectory: true)
            var copiedPaths: [String] = []
            for path in paths.sorted() {
                let sourceURL = rootURL.appendingPathComponent(path, isDirectory: false)
                let sourceExists = fileManager.fileExists(atPath: sourceURL.path)
                    || (try? fileManager.attributesOfItem(atPath: sourceURL.path)) != nil
                guard sourceExists else { continue }

                let destinationURL = filesURL.appendingPathComponent(path, isDirectory: false)
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                copiedPaths.append(path)
            }

            let manifest = Manifest(
                version: 1,
                createdAt: createdAt,
                repositoryRoot: repository.rootPath,
                workspacePath: repository.workspacePath,
                snapshotID: repository.id.rawValue,
                headObjectID: repository.headObjectID,
                branchName: repository.branchName,
                paths: paths.sorted(),
                copiedPaths: copiedPaths,
                stagedPatchFile: "staged.patch",
                worktreePatchFile: "worktree.patch"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: bundleURL.appendingPathComponent("manifest.json"),
                options: .atomic
            )
        } catch {
            try? fileManager.removeItem(at: bundleURL)
            throw DesktopGitError.recoveryFailed(error.localizedDescription)
        }

        return DesktopGitRecoveryReceipt(
            id: identifier,
            bundlePath: bundleURL.path,
            repositoryRoot: repository.rootPath,
            paths: paths.sorted(),
            createdAt: createdAt
        )
    }

    func moveItemsToTrash(_ urls: [URL]) throws {
        for url in urls {
            var resultingURL: NSURL?
            do {
                try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
            } catch {
                throw DesktopGitError.trashFailed(
                    "The recovery bundle is intact, but \(url.lastPathComponent) could not be moved to Trash: \(error.localizedDescription)"
                )
            }
        }
    }
}
