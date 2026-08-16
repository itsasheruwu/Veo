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

struct DesktopWorkspaceVisibleFileRow: Identifiable, Hashable {
    let entry: DesktopWorkspaceFileEntry
    let depth: Int
    let displaysRelativePath: Bool

    var id: String { entry.id }
}

@MainActor
final class DesktopFilesModel: ObservableObject {
    @Published private(set) var workspaceURL: URL?
    @Published private(set) var rootEntries: [DesktopWorkspaceFileEntry] = []
    @Published private(set) var childrenByPath: [String: [DesktopWorkspaceFileEntry]] = [:]
    @Published private(set) var visibleRows: [DesktopWorkspaceVisibleFileRow] = []
    @Published var expandedPaths = Set<String>()
    @Published var searchText = "" {
        didSet { rebuildVisibleRows() }
    }
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
    private var treeLoadTask: Task<Void, Never>?
    private var directoryLoadTasks: [String: Task<Void, Never>] = [:]
    private var documentLoadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var treeLoadToken = UUID()
    private var directoryLoadTokens: [String: UUID] = [:]
    private var documentLoadToken = UUID()
    private var saveToken = UUID()
    private var deferredActionAfterSave: (() -> Void)?
    private var loadedEntriesByPath: [String: DesktopWorkspaceFileEntry] = [:]
    private var sortedLoadedEntries: [DesktopWorkspaceFileEntry] = []
    private var isReplacingText = false

    deinit {
        autosaveTask?.cancel()
        treeLoadTask?.cancel()
        directoryLoadTasks.values.forEach { $0.cancel() }
        documentLoadTask?.cancel()
        saveTask?.cancel()
    }

    func switchWorkspace(to url: URL?) {
        guard workspaceURL?.path != url?.path else { return }
        continueAfterSaving { [weak self] in
            self?.applyWorkspace(url)
        }
    }

    private func applyWorkspace(_ url: URL?) {
        treeLoadToken = UUID()
        treeLoadTask?.cancel()
        treeLoadTask = nil
        directoryLoadTasks.values.forEach { $0.cancel() }
        directoryLoadTasks.removeAll()
        directoryLoadTokens.removeAll()
        documentLoadToken = UUID()
        documentLoadTask?.cancel()
        documentLoadTask = nil
        workspaceURL = url
        rootEntries = []
        childrenByPath = [:]
        visibleRows = []
        loadedEntriesByPath = [:]
        sortedLoadedEntries = []
        expandedPaths = []
        selectedEntry = nil
        replaceDocument(nil)
        message = nil
        refresh()
    }

    func refresh() {
        treeLoadTask?.cancel()
        directoryLoadTasks.values.forEach { $0.cancel() }
        directoryLoadTasks.removeAll()
        directoryLoadTokens.removeAll()
        let token = UUID()
        treeLoadToken = token
        guard let workspaceURL else {
            rootEntries = []
            childrenByPath = [:]
            visibleRows = []
            loadedEntriesByPath = [:]
            sortedLoadedEntries = []
            message = "Open a project to browse files."
            return
        }
        let expandedPaths = expandedPaths
        let service = self.service
        treeLoadTask = Task { [weak self, service] in
            do {
                let snapshot = try await service.loadTree(
                    in: workspaceURL,
                    expandedPaths: expandedPaths
                )
                guard !Task.isCancelled,
                      let self,
                      self.treeLoadToken == token,
                      self.workspaceURL?.path == workspaceURL.path else { return }
                self.apply(snapshot)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.treeLoadToken == token,
                      self.workspaceURL?.path == workspaceURL.path else { return }
                self.message = error.localizedDescription
            }
        }
    }

    func toggleDirectory(_ entry: DesktopWorkspaceFileEntry) {
        guard entry.isDirectory, let workspaceURL else { return }
        if expandedPaths.contains(entry.relativePath) {
            expandedPaths.remove(entry.relativePath)
            directoryLoadTokens.removeValue(forKey: entry.relativePath)
            directoryLoadTasks.removeValue(forKey: entry.relativePath)?.cancel()
            rebuildVisibleRows()
            return
        }
        expandedPaths.insert(entry.relativePath)
        rebuildVisibleRows()
        guard childrenByPath[entry.relativePath] == nil else { return }

        let token = UUID()
        directoryLoadTokens[entry.relativePath] = token
        let service = self.service
        directoryLoadTasks[entry.relativePath] = Task { [weak self, service] in
            do {
                let children = try await service.loadChildren(of: entry.url, workspaceURL: workspaceURL)
                guard !Task.isCancelled,
                      let self,
                      self.workspaceURL?.path == workspaceURL.path,
                      self.expandedPaths.contains(entry.relativePath),
                      self.directoryLoadTokens[entry.relativePath] == token else { return }
                self.childrenByPath[entry.relativePath] = children
                self.directoryLoadTokens.removeValue(forKey: entry.relativePath)
                self.directoryLoadTasks.removeValue(forKey: entry.relativePath)
                self.insertLoadedEntries(children)
                self.rebuildVisibleRows()
                self.message = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.workspaceURL?.path == workspaceURL.path,
                      self.directoryLoadTokens[entry.relativePath] == token else { return }
                self.directoryLoadTokens.removeValue(forKey: entry.relativePath)
                self.directoryLoadTasks.removeValue(forKey: entry.relativePath)
                self.expandedPaths.remove(entry.relativePath)
                self.rebuildVisibleRows()
                self.message = error.localizedDescription
            }
        }
    }

    func select(_ entry: DesktopWorkspaceFileEntry) {
        if entry.isDirectory {
            toggleDirectory(entry)
            return
        }
        if selectedEntry?.id == entry.id { return }
        continueAfterSaving { [weak self] in
            self?.applySelection(entry)
        }
    }

    private func applySelection(_ entry: DesktopWorkspaceFileEntry) {
        documentLoadToken = UUID()
        documentLoadTask?.cancel()
        documentLoadTask = nil
        selectedEntry = entry
        replaceDocument(nil)
        saveState = .preview
        message = nil
    }

    func openSelectedForEditing() {
        guard let entry = selectedEntry, let workspaceURL, entry.isEditableText else { return }
        documentLoadTask?.cancel()
        let token = UUID()
        documentLoadToken = token
        let service = self.service
        documentLoadTask = Task { [weak self, service] in
            do {
                let loaded = try await service.readText(entry, workspaceURL: workspaceURL)
                guard !Task.isCancelled,
                      let self,
                      self.documentLoadToken == token,
                      self.workspaceURL?.path == workspaceURL.path,
                      self.selectedEntry?.id == entry.id else { return }
                self.documentLoadTask = nil
                self.replaceDocument(loaded)
                self.message = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.documentLoadToken == token,
                      self.workspaceURL?.path == workspaceURL.path,
                      self.selectedEntry?.id == entry.id else { return }
                self.documentLoadTask = nil
                self.message = error.localizedDescription
            }
        }
    }

    @discardableResult
    func flushPendingSave(overwrite: Bool = false) -> Bool {
        autosaveTask?.cancel()
        guard document != nil else { return true }
        guard hasUnsavedChanges || overwrite else { return saveTask == nil }
        guard saveTask == nil else { return false }
        beginSave(overwrite: overwrite)
        // Callers that need to block a workspace change retain the old invariant:
        // they only proceed after a completed, conflict-free save.
        return false
    }

    func reloadFromDisk() {
        guard selectedEntry != nil else { return }
        autosaveTask?.cancel()
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

    private var hasUnsavedChanges: Bool {
        guard let document else { return false }
        return editorText != document.text
    }

    private func continueAfterSaving(_ action: @escaping () -> Void) {
        guard prepareForWorkspaceChange(then: action) == false else {
            action()
            return
        }
    }

    /// Returns `false` only when the action has been retained and will run after a
    /// successful asynchronous save. A failed/conflicted save deliberately leaves
    /// the current workspace and selection unchanged.
    func prepareForWorkspaceChange(then action: @escaping () -> Void) -> Bool {
        guard hasUnsavedChanges || saveTask != nil else { return true }
        deferredActionAfterSave = action
        autosaveTask?.cancel()
        if saveTask == nil {
            beginSave(overwrite: false)
        }
        return false
    }

    /// Keeps a completed save from applying an older navigation request after the
    /// user explicitly stays in the current context.
    func cancelDeferredWorkspaceChange() {
        deferredActionAfterSave = nil
    }

    private func beginSave(overwrite: Bool) {
        guard saveTask == nil,
              var snapshot = document,
              let workspaceURL,
              editorText != snapshot.text || overwrite else { return }
        autosaveTask?.cancel()
        snapshot.text = editorText
        let token = UUID()
        saveToken = token
        saveState = .saving
        let service = self.service
        saveTask = Task { [weak self, service] in
            do {
                let fingerprint = try await service.save(
                    snapshot,
                    workspaceURL: workspaceURL,
                    overwrite: overwrite
                )
                guard !Task.isCancelled,
                      let self,
                      self.saveToken == token,
                      self.workspaceURL?.path == workspaceURL.path,
                      var currentDocument = self.document,
                      currentDocument.url == snapshot.url else { return }
                self.saveTask = nil
                currentDocument.text = snapshot.text
                currentDocument.fingerprint = fingerprint
                self.document = currentDocument
                self.message = nil

                if self.editorText == snapshot.text {
                    self.saveState = .saved
                    let action = self.deferredActionAfterSave
                    self.deferredActionAfterSave = nil
                    action?()
                } else {
                    self.saveState = .unsaved
                    if self.deferredActionAfterSave != nil {
                        self.beginSave(overwrite: overwrite)
                    } else {
                        self.scheduleAutosave()
                    }
                }
            } catch is CancellationError {
                return
            } catch DesktopWorkspaceFileError.changedOnDisk {
                guard !Task.isCancelled,
                      let self,
                      self.saveToken == token,
                      self.workspaceURL?.path == workspaceURL.path else { return }
                self.saveTask = nil
                self.deferredActionAfterSave = nil
                self.saveState = .conflict
                self.message = DesktopWorkspaceFileError.changedOnDisk.localizedDescription
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.saveToken == token,
                      self.workspaceURL?.path == workspaceURL.path else { return }
                self.saveTask = nil
                self.deferredActionAfterSave = nil
                self.saveState = .failed(error.localizedDescription)
                self.message = error.localizedDescription
            }
        }
    }

    private func apply(_ snapshot: DesktopWorkspaceFileTreeSnapshot) {
        rootEntries = snapshot.rootEntries
        childrenByPath = snapshot.childrenByPath
        rebuildLoadedEntryCache()
        rebuildVisibleRows()
        message = nil
        treeLoadTask = nil
    }

    private func rebuildLoadedEntryCache() {
        var entriesByPath: [String: DesktopWorkspaceFileEntry] = [:]
        for entry in rootEntries {
            entriesByPath[entry.relativePath] = entry
        }
        for entries in childrenByPath.values {
            for entry in entries {
                entriesByPath[entry.relativePath] = entry
            }
        }
        loadedEntriesByPath = entriesByPath
        sortedLoadedEntries = entriesByPath.values.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private func insertLoadedEntries(_ entries: [DesktopWorkspaceFileEntry]) {
        guard !entries.isEmpty else { return }
        let hasReplacement = entries.contains { loadedEntriesByPath[$0.relativePath] != nil }
        for entry in entries {
            loadedEntriesByPath[entry.relativePath] = entry
        }
        guard !hasReplacement else {
            sortedLoadedEntries = loadedEntriesByPath.values.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            return
        }

        let sortedNewEntries = entries.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        var merged: [DesktopWorkspaceFileEntry] = []
        merged.reserveCapacity(sortedLoadedEntries.count + sortedNewEntries.count)
        var existingIndex = 0
        var newIndex = 0
        while existingIndex < sortedLoadedEntries.count || newIndex < sortedNewEntries.count {
            if newIndex == sortedNewEntries.count || (
                existingIndex < sortedLoadedEntries.count
                    && sortedLoadedEntries[existingIndex].relativePath.localizedStandardCompare(
                        sortedNewEntries[newIndex].relativePath
                    ) != .orderedDescending
            ) {
                merged.append(sortedLoadedEntries[existingIndex])
                existingIndex += 1
            } else {
                merged.append(sortedNewEntries[newIndex])
                newIndex += 1
            }
        }
        sortedLoadedEntries = merged
    }

    private func rebuildVisibleRows() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty else {
            visibleRows = sortedLoadedEntries.compactMap { entry in
                entry.relativePath.localizedCaseInsensitiveContains(query)
                    ? DesktopWorkspaceVisibleFileRow(
                        entry: entry,
                        depth: 0,
                        displaysRelativePath: true
                    )
                    : nil
            }
            return
        }

        var rows: [DesktopWorkspaceVisibleFileRow] = []
        var visitedPaths = Set<String>()
        func append(_ entries: [DesktopWorkspaceFileEntry], depth: Int) {
            for entry in entries {
                guard visitedPaths.insert(entry.relativePath).inserted else { continue }
                rows.append(DesktopWorkspaceVisibleFileRow(
                    entry: entry,
                    depth: depth,
                    displaysRelativePath: false
                ))
                guard entry.isDirectory,
                      expandedPaths.contains(entry.relativePath),
                      let children = childrenByPath[entry.relativePath] else { continue }
                append(children, depth: depth + 1)
            }
        }
        append(rootEntries, depth: 0)
        visibleRows = rows
    }
}
