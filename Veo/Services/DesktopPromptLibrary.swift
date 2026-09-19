import Foundation
import Observation

struct DesktopSavedPrompt: Identifiable, Codable {
    var id: String
    var workspacePath: String
    var text: String
    var attachments: [DesktopComposerAttachment]
    var createdAt: Date
    var title: String { text.split(separator: "\n").first.map(String.init) ?? "Attachments" }
}

@MainActor @Observable
final class DesktopPromptLibrary {
    static let shared = DesktopPromptLibrary()
    private(set) var prompts: [DesktopSavedPrompt] = []
    private let root: URL
    private var manifest: URL { root.appendingPathComponent("prompts.json") }

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ash.Veo/PromptLibrary", isDirectory: true)
        if let data = try? Data(contentsOf: manifest), let saved = try? JSONDecoder().decode([DesktopSavedPrompt].self, from: data) {
            prompts = saved
        }
    }

    func save(text: String, attachments: [DesktopComposerAttachment], workspace: String) async throws {
        let id = UUID().uuidString
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let copies = try await Task.detached(priority: .utility) { try Self.copyAttachments(attachments, to: directory) }.value
            var updated = prompts
            updated.insert(.init(id: id, workspacePath: workspace, text: text, attachments: copies, createdAt: .now), at: 0)
            try persist(updated)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func restore(_ prompt: DesktopSavedPrompt, into workspace: URL) async throws -> [DesktopComposerAttachment] {
        guard prompt.attachments.contains(where: { $0.kind == .localImage || $0.kind == .localAudio }) else { return prompt.attachments }
        let workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let directory = workspace.appendingPathComponent("Attachments/SavedPrompt-" + UUID().uuidString, isDirectory: true)
        guard directory.resolvingSymlinksInPath().path.hasPrefix(workspace.path + "/") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let attachments = prompt.attachments
            return try await Task.detached(priority: .utility) { try Self.copyAttachments(attachments, to: directory) }.value
        }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    func remove(_ prompt: DesktopSavedPrompt) throws {
        try persist(prompts.filter { $0.id != prompt.id })
        // Restored drafts have independent media copies.
        try? FileManager.default.removeItem(at: root.appendingPathComponent(prompt.id))
    }

    private func persist(_ updated: [DesktopSavedPrompt]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
        prompts = updated
    }

    nonisolated private static func copyAttachments(_ attachments: [DesktopComposerAttachment], to directory: URL) throws -> [DesktopComposerAttachment] {
        try attachments.map { attachment in
            guard attachment.kind == .localImage || attachment.kind == .localAudio else { return attachment }
            let original = URL(fileURLWithPath: attachment.source)
            let destination = directory.appendingPathComponent(UUID().uuidString + "-" + original.lastPathComponent)
            try FileManager.default.copyItem(at: original, to: destination)
            return DesktopComposerAttachment(kind: attachment.kind, source: destination.path, name: attachment.name)
        }
    }
}
