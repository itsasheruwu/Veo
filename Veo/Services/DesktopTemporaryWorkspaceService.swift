// FILE: DesktopTemporaryWorkspaceService.swift
// Purpose: Owns durable app-managed scratch directories for projectless Veo chats.
// Layer: Desktop app service
// Depends on: Foundation

import Foundation

struct DesktopTemporaryWorkspaceService {
    enum ServiceError: LocalizedError {
        case invalidWorkspace

        var errorDescription: String? {
            "The temporary workspace is outside Veo's managed storage."
        }
    }

    private let fileManager: FileManager
    private let rootURL: URL

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.rootURL = applicationSupport
                .appendingPathComponent("com.ash.Veo", isDirectory: true)
                .appendingPathComponent("Temporary Chats", isDirectory: true)
        }
    }

    func createWorkspace(forVeoID veoID: String) throws -> URL {
        let url = workspaceURL(forVeoID: veoID)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func ensureWorkspace(for thread: DesktopThread) throws {
        guard thread.origin == .veo, thread.workspaceKind.isAppManaged else { return }
        let expectedURL = workspaceURL(forVeoID: thread.id).standardizedFileURL
        let persistedURL = URL(fileURLWithPath: thread.cwd, isDirectory: true).standardizedFileURL
        guard expectedURL.path == persistedURL.path else { throw ServiceError.invalidWorkspace }
        try fileManager.createDirectory(at: expectedURL, withIntermediateDirectories: true)
    }

    func removeWorkspace(atPath path: String) throws {
        let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let root = rootURL.standardizedFileURL
        guard candidate.deletingLastPathComponent().path == root.path else { return }
        guard fileManager.fileExists(atPath: candidate.path) else { return }
        try fileManager.removeItem(at: candidate)
    }

    func importFile(at sourceURL: URL, intoWorkspaceAtPath workspacePath: String) throws -> URL {
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        let root = rootURL.standardizedFileURL
        guard workspaceURL.deletingLastPathComponent().path == root.path else {
            throw ServiceError.invalidWorkspace
        }
        let attachmentsURL = workspaceURL.appendingPathComponent("Attachments", isDirectory: true)
        try fileManager.createDirectory(at: attachmentsURL, withIntermediateDirectories: true)
        var destinationURL = attachmentsURL.appendingPathComponent(sourceURL.lastPathComponent)
        if fileManager.fileExists(atPath: destinationURL.path) {
            let suffix = String(UUID().uuidString.prefix(8)).lowercased()
            let baseName = sourceURL.deletingPathExtension().lastPathComponent
            let extensionName = sourceURL.pathExtension
            let uniqueName = extensionName.isEmpty
                ? "\(baseName)-\(suffix)"
                : "\(baseName)-\(suffix).\(extensionName)"
            destinationURL = attachmentsURL.appendingPathComponent(uniqueName)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    func removeOrphanedWorkspaces(
        keeping paths: Set<String>,
        minimumOrphanAge: TimeInterval = 3_600
    ) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let retained = Set(paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path })
        let children = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        for child in children where !retained.contains(child.standardizedFileURL.path) {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
            guard values.isDirectory == true,
                  Date().timeIntervalSince(values.creationDate ?? .now) >= minimumOrphanAge else { continue }
            try fileManager.removeItem(at: child)
        }
    }

    private func workspaceURL(forVeoID veoID: String) -> URL {
        let bareID = DesktopThreadSelection.parse(veoID).bareID
        return rootURL.appendingPathComponent(bareID, isDirectory: true)
    }
}
