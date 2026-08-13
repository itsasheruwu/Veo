// FILE: DesktopFilesModel.swift
// Purpose: Window-scoped state for workspace browsing, previews, and safe text editing.
// Layer: Desktop app model

import AppKit
import Foundation

enum DesktopFileSaveState: Equatable {
    case preview
    case saved
    case unsaved
    case saving
    case conflict
    case failed(String)

    var title: String {
        switch self {
        case .preview: return "Preview"
        case .saved: return "Saved"
        case .unsaved: return "Unsaved"
        case .saving: return "Saving…"
        case .conflict: return "Changed on disk"
        case .failed: return "Save failed"
        }
    }
}

@MainActor
final class DesktopFilesModel: ObservableObject {
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var rootEntries: [DesktopWorkspaceFileEntry] = []
    @Published private(set) var childrenByPath: [String: [DesktopWorkspaceFileEntry]] = [:]
    @Published var expandedPaths = Set<String>()
    @Published var searchText = ""
    @Published var selectedEntry: DesktopWorkspaceFileEntry?
    @Published private(set) var document: DesktopWorkspaceTextDocument?
    @Published var editorText = "" {
        didSet {
            guard !isReplacingText, document != nil, editorText != document?.text else { return }
            saveState = .unsaved
            scheduleAutosave()
        }
    }
    @Published private(set) var saveState: DesktopFileSaveState = .preview
    @Published private(set) var message: String?

    private let service = DesktopWorkspaceFileService()
    private var autosaveTask: Task<Void, Never>?
    private var isReplacingText = false

    var filteredRootEntries: [DesktopWorkspaceFileEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rootEntries }
        return allLoadedEntries.filter {
            $0.relativePath.localizedCaseInsensitiveContains(query)
        }
    }

    private var allLoadedEntries: [DesktopWorkspaceFileEntry] {
        var seen: [String: DesktopWorkspaceFileEntry] = [:]
        for entry in rootEntries { seen[entry.id] = entry }
        for entries in childrenByPath.values {
            for entry in entries { seen[entry.id] = entry }
        }
        return seen.values.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    func switchWorkspace(to url: URL?) {
        guard workspaceURL?.path != url?.path else { return }
        guard flushPendingSave() else { return }
        workspaceURL = url
        rootEntries = []
        childrenByPath = [:]
        expandedPaths = []
        selectedEntry = nil
        replaceDocument(nil)
        message = nil
        refresh()
    }

    func refresh() {
        guard let workspaceURL else {
            rootEntries = []
            message = "Open a project to browse files."
            return
        }
        do {
            rootEntries = try service.listChildren(of: workspaceURL, workspaceURL: workspaceURL)
            for path in expandedPaths {
                if let directory = allLoadedEntries.first(where: { $0.relativePath == path && $0.isDirectory }) {
                    childrenByPath[path] = try service.listChildren(of: directory.url, workspaceURL: workspaceURL)
                }
            }
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func toggleDirectory(_ entry: DesktopWorkspaceFileEntry) {
        guard entry.isDirectory, let workspaceURL else { return }
        if expandedPaths.contains(entry.relativePath) {
            expandedPaths.remove(entry.relativePath)
            return
        }
        do {
            childrenByPath[entry.relativePath] = try service.listChildren(of: entry.url, workspaceURL: workspaceURL)
            expandedPaths.insert(entry.relativePath)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func select(_ entry: DesktopWorkspaceFileEntry) {
        if entry.isDirectory {
            toggleDirectory(entry)
            return
        }
        if selectedEntry?.id == entry.id { return }
        guard flushPendingSave() else { return }
        selectedEntry = entry
        replaceDocument(nil)
        saveState = .preview
        message = nil
    }

    func openSelectedForEditing() {
        guard let entry = selectedEntry, let workspaceURL, entry.isEditableText else { return }
        do {
            let loaded = try service.readText(entry, workspaceURL: workspaceURL)
            replaceDocument(loaded)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    @discardableResult
    func flushPendingSave(overwrite: Bool = false) -> Bool {
        autosaveTask?.cancel()
        guard var document, let workspaceURL else { return true }
        guard editorText != document.text || overwrite else { return true }
        saveState = .saving
        document.text = editorText
        do {
            document.fingerprint = try service.save(document, workspaceURL: workspaceURL, overwrite: overwrite)
            self.document = document
            saveState = .saved
            message = nil
            return true
        } catch DesktopWorkspaceFileError.changedOnDisk {
            saveState = .conflict
            message = DesktopWorkspaceFileError.changedOnDisk.localizedDescription
            return false
        } catch {
            saveState = .failed(error.localizedDescription)
            message = error.localizedDescription
            return false
        }
    }

    func reloadFromDisk() {
        guard let entry = selectedEntry else { return }
        autosaveTask?.cancel()
        selectedEntry = entry
        openSelectedForEditing()
    }

    func revealSelected() {
        let url = selectedEntry?.url ?? workspaceURL
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func replaceDocument(_ document: DesktopWorkspaceTextDocument?) {
        isReplacingText = true
        self.document = document
        editorText = document?.text ?? ""
        saveState = document == nil ? .preview : .saved
        isReplacingText = false
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(850))
            guard !Task.isCancelled else { return }
            _ = self?.flushPendingSave()
        }
    }
}
