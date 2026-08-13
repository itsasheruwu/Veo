// FILE: DesktopWorkspaceFileService.swift
// Purpose: Safely enumerates, reads, fingerprints, and atomically saves files inside one workspace.
// Layer: Desktop app service

import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

struct DesktopWorkspaceFileEntry: Identifiable, Hashable {
    let url: URL
    let relativePath: String
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let contentType: UTType?
    let byteCount: Int64

    var id: String { relativePath }

    var isEditableText: Bool {
        guard !isDirectory, !isSymbolicLink, let contentType else { return false }
        return contentType.conforms(to: .text) || contentType.conforms(to: .sourceCode)
    }

    var isHTML: Bool {
        contentType?.conforms(to: .html) == true
    }
}

enum DesktopWorkspaceTextEncoding: String, Hashable {
    case utf8
    case utf8BOM
    case utf16LittleEndian
    case utf16BigEndian
}

enum DesktopWorkspaceNewline: String, Hashable {
    case lineFeed
    case carriageReturnLineFeed
}

struct DesktopWorkspaceFileFingerprint: Hashable {
    let digest: String
    let permissions: Int
}

struct DesktopWorkspaceTextDocument: Hashable {
    let url: URL
    let relativePath: String
    var text: String
    let encoding: DesktopWorkspaceTextEncoding
    let newline: DesktopWorkspaceNewline
    var fingerprint: DesktopWorkspaceFileFingerprint
}

enum DesktopWorkspaceFileError: LocalizedError {
    case noWorkspace
    case unsafePath
    case notDirectory
    case notRegularFile
    case unsupportedText
    case fileTooLarge
    case changedOnDisk
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noWorkspace: return "Open a workspace to browse files."
        case .unsafePath: return "Veo refused a path outside the selected workspace."
        case .notDirectory: return "That folder is no longer available."
        case .notRegularFile: return "That item is not a regular file."
        case .unsupportedText: return "This file is not supported by Veo's text editor."
        case .fileTooLarge: return "Text files larger than 8 MiB are preview-only."
        case .changedOnDisk: return "This file changed on disk after it was opened."
        case .saveFailed(let message): return "The file could not be saved: \(message)"
        }
    }
}

struct DesktopWorkspaceFileService {
    private static let maximumTextBytes = 8 * 1_024 * 1_024
    private let fileManager = FileManager.default

    func listChildren(of directoryURL: URL, workspaceURL: URL) throws -> [DesktopWorkspaceFileEntry] {
        let workspace = try canonicalWorkspace(workspaceURL)
        let directory = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(directory, inside: workspace) else { throw DesktopWorkspaceFileError.unsafePath }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DesktopWorkspaceFileError.notDirectory
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey,
            .fileSizeKey, .nameKey,
        ]
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).compactMap { url in
            if url.lastPathComponent == ".git" { return nil }
            let values = try url.resourceValues(forKeys: keys)
            let relativePath = relativePath(from: workspace, to: url)
            guard !relativePath.isEmpty else { return nil }
            return DesktopWorkspaceFileEntry(
                url: url.standardizedFileURL,
                relativePath: relativePath,
                name: values.name ?? url.lastPathComponent,
                isDirectory: values.isDirectory == true,
                isSymbolicLink: values.isSymbolicLink == true,
                contentType: values.contentType,
                byteCount: Int64(values.fileSize ?? 0)
            )
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func readText(_ entry: DesktopWorkspaceFileEntry, workspaceURL: URL) throws -> DesktopWorkspaceTextDocument {
        guard entry.isEditableText else { throw DesktopWorkspaceFileError.unsupportedText }
        let (file, fingerprint) = try validatedRegularFile(entry.url, workspaceURL: workspaceURL)
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        guard data.count <= Self.maximumTextBytes else { throw DesktopWorkspaceFileError.fileTooLarge }
        let decoded = try decode(data)
        return DesktopWorkspaceTextDocument(
            url: file,
            relativePath: entry.relativePath,
            text: decoded.text,
            encoding: decoded.encoding,
            newline: decoded.newline,
            fingerprint: fingerprint
        )
    }

    func fingerprint(of url: URL, workspaceURL: URL) throws -> DesktopWorkspaceFileFingerprint {
        try validatedRegularFile(url, workspaceURL: workspaceURL).fingerprint
    }

    func save(
        _ document: DesktopWorkspaceTextDocument,
        workspaceURL: URL,
        overwrite: Bool
    ) throws -> DesktopWorkspaceFileFingerprint {
        let (target, current) = try validatedRegularFile(document.url, workspaceURL: workspaceURL)
        guard overwrite || current.digest == document.fingerprint.digest else {
            throw DesktopWorkspaceFileError.changedOnDisk
        }
        let normalized = document.newline == .carriageReturnLineFeed
            ? document.text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r\n")
            : document.text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let data = encode(normalized, as: document.encoding), data.count <= Self.maximumTextBytes else {
            throw DesktopWorkspaceFileError.unsupportedText
        }

        let parent = target.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".veo-save-\(UUID().uuidString)", isDirectory: false)
        do {
            try data.write(to: temporary, options: [.withoutOverwriting])
            try fileManager.setAttributes([.posixPermissions: current.permissions], ofItemAtPath: temporary.path)
            _ = try fileManager.replaceItemAt(target, withItemAt: temporary, backupItemName: nil, options: [])
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw DesktopWorkspaceFileError.saveFailed(error.localizedDescription)
        }
        return try fingerprint(of: target, workspaceURL: workspaceURL)
    }

    private func validatedRegularFile(
        _ rawURL: URL,
        workspaceURL: URL
    ) throws -> (url: URL, fingerprint: DesktopWorkspaceFileFingerprint) {
        let workspace = try canonicalWorkspace(workspaceURL)
        let raw = rawURL.standardizedFileURL
        var status = stat()
        guard Darwin.lstat(raw.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            throw DesktopWorkspaceFileError.notRegularFile
        }
        guard status.st_size <= Self.maximumTextBytes else {
            throw DesktopWorkspaceFileError.fileTooLarge
        }
        let resolved = raw.resolvingSymlinksInPath()
        guard contains(resolved, inside: workspace) else { throw DesktopWorkspaceFileError.unsafePath }
        let data = try Data(contentsOf: resolved, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (
            resolved,
            DesktopWorkspaceFileFingerprint(
                digest: digest,
                permissions: Int(status.st_mode & 0o7777)
            )
        )
    }

    private func canonicalWorkspace(_ url: URL) throws -> URL {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DesktopWorkspaceFileError.noWorkspace
        }
        return canonical
    }

    private func contains(_ candidate: URL, inside root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private func relativePath(from root: URL, to child: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        guard childPath.hasPrefix(rootPath + "/") else { return "" }
        return String(childPath.dropFirst(rootPath.count + 1))
    }

    private func decode(_ data: Data) throws -> (
        text: String,
        encoding: DesktopWorkspaceTextEncoding,
        newline: DesktopWorkspaceNewline
    ) {
        let text: String
        let encoding: DesktopWorkspaceTextEncoding
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let decoded = String(data: data.dropFirst(3), encoding: .utf8) {
            text = decoded
            encoding = .utf8BOM
        } else if data.starts(with: [0xFF, 0xFE]),
                  let decoded = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
            text = decoded
            encoding = .utf16LittleEndian
        } else if data.starts(with: [0xFE, 0xFF]),
                  let decoded = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
            text = decoded
            encoding = .utf16BigEndian
        } else if let decoded = String(data: data, encoding: .utf8) {
            text = decoded
            encoding = .utf8
        } else {
            throw DesktopWorkspaceFileError.unsupportedText
        }
        return (text, encoding, text.contains("\r\n") ? .carriageReturnLineFeed : .lineFeed)
    }

    private func encode(_ text: String, as encoding: DesktopWorkspaceTextEncoding) -> Data? {
        switch encoding {
        case .utf8:
            return text.data(using: .utf8)
        case .utf8BOM:
            guard let body = text.data(using: .utf8) else { return nil }
            return Data([0xEF, 0xBB, 0xBF]) + body
        case .utf16LittleEndian:
            guard let body = text.data(using: .utf16LittleEndian) else { return nil }
            return Data([0xFF, 0xFE]) + body
        case .utf16BigEndian:
            guard let body = text.data(using: .utf16BigEndian) else { return nil }
            return Data([0xFE, 0xFF]) + body
        }
    }
}
