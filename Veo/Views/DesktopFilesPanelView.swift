// FILE: DesktopFilesPanelView.swift
// Purpose: Workspace tree, native text editing, and Quick Look previews.
// Layer: Desktop app view

import AppKit
import QuickLookUI
import SwiftUI

struct DesktopFilesPanelView: View {
    @ObservedObject var files: DesktopFilesModel
    let repository: DesktopGitRepositorySnapshot?
    let openInBrowser: (URL, URL) -> Void

    var body: some View {
        let gitBadges = DesktopFileGitBadgeIndex(repository: repository)
        VStack(spacing: 0) {
            filesToolbar
            Divider()

            HSplitView {
                fileTree(gitBadges: gitBadges)
                    .frame(minWidth: 170, idealWidth: 210, maxWidth: 280)
                fileContent
                    .frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
            }

            if let message = files.message, !message.isEmpty {
                Divider()
                Label(message, systemImage: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(files.saveState == .conflict ? .orange : .secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var filesToolbar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter files", text: $files.searchText)
                .textFieldStyle(.plain)
            Spacer()
            Button { files.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh Files")
            Button { files.revealSelected() } label: { Image(systemName: "finder") }
                .help("Reveal in Finder")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 9)
        .frame(height: 38)
    }

    private func fileTree(gitBadges: DesktopFileGitBadgeIndex) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(files.visibleRows) { row in
                    DesktopFileTreeRow(
                        files: files,
                        row: row,
                        gitBadge: gitBadges.badge(for: row.entry)
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color.primary.opacity(0.02))
    }

    @ViewBuilder
    private var fileContent: some View {
        if files.document != nil {
            VStack(spacing: 0) {
                editorHeader
                Divider()
                DesktopNativeTextEditor(text: $files.editorText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let entry = files.selectedEntry {
            VStack(spacing: 0) {
                HStack {
                    Text(entry.relativePath)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if entry.isEditableText {
                        Button("Edit") { files.openSelectedForEditing() }
                    }
                    if entry.isHTML, let workspace = files.workspaceURL {
                        Button("Open in Browser") { openInBrowser(entry.url, workspace) }
                    }
                }
                .controlSize(.small)
                .padding(9)
                Divider()
                if entry.isSymbolicLink {
                    ContentUnavailableView(
                        "Symbolic link",
                        systemImage: "link.badge.plus",
                        description: Text("Veo does not preview symbolic links outside the workspace file boundary.")
                    )
                } else if let workspace = files.workspaceURL {
                    DesktopQuickLookPreview(url: entry.url, workspaceURL: workspace)
                }
            }
        } else {
            ContentUnavailableView(
                "Select a file",
                systemImage: "doc",
                description: Text("Preview files or open text files for manual editing.")
            )
        }
    }

    private var editorHeader: some View {
        HStack(spacing: 8) {
            Text(files.document?.relativePath ?? "")
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(files.saveState.title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(saveStateColor)
            if files.saveState == .conflict {
                Button("Reload") { files.reloadFromDisk() }
                Button("Overwrite") { _ = files.flushPendingSave(overwrite: true) }
            }
            Button("Save") { _ = files.flushPendingSave() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(files.saveState == .saved || files.saveState == .saving)
        }
        .controlSize(.small)
        .padding(9)
    }

    private var saveStateColor: Color {
        switch files.saveState {
        case .saved: return .green
        case .conflict, .failed: return .orange
        case .unsaved: return .secondary
        default: return Color(nsColor: .tertiaryLabelColor)
        }
    }

}

private struct DesktopFileTreeRow: View {
    @ObservedObject var files: DesktopFilesModel
    let row: DesktopWorkspaceVisibleFileRow
    let gitBadge: String?

    var body: some View {
        Button { files.select(row.entry) } label: {
            HStack(spacing: 6) {
                if row.entry.isDirectory, !row.displaysRelativePath {
                    Image(systemName: files.expandedPaths.contains(row.entry.relativePath) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
                Image(systemName: desktopFileIcon(row.entry))
                    .foregroundStyle(row.entry.isDirectory ? .secondary : .primary)
                    .frame(width: 14)
                Text(row.displaysRelativePath ? row.entry.relativePath : row.entry.name)
                    .font(row.displaysRelativePath
                        ? .system(size: 11, design: .monospaced)
                        : .system(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(row.displaysRelativePath ? .middle : .tail)
                Spacer()
                if let gitBadge {
                    Text(gitBadge)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, row.displaysRelativePath ? 8 : CGFloat(row.depth * 13) + 6)
            .padding(.trailing, 6)
            .frame(height: 27)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(files.selectedEntry?.id == row.entry.id ? Color.accentColor.opacity(0.18) : .clear)
                    .padding(.horizontal, 3)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct DesktopFileGitBadgeIndex {
    private let changesByRelativePath: [String: DesktopGitFileChange]
    private let changedDirectoryPaths: Set<String>

    init(repository: DesktopGitRepositorySnapshot?) {
        guard let repository else {
            changesByRelativePath = [:]
            changedDirectoryPaths = []
            return
        }

        let rawWorkspacePrefix = repository.workspaceRelativePath?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let workspacePrefix = rawWorkspacePrefix == "." ? "" : rawWorkspacePrefix
        var changes: [String: DesktopGitFileChange] = [:]
        var directories = Set<String>()
        for change in repository.files where change.isInWorkspace {
            let relativePath: String
            if workspacePrefix.isEmpty {
                relativePath = change.path
            } else {
                let prefix = workspacePrefix + "/"
                guard change.path.hasPrefix(prefix) else { continue }
                relativePath = String(change.path.dropFirst(prefix.count))
            }
            changes[relativePath] = change

            let components = relativePath.split(separator: "/")
            guard components.count > 1 else { continue }
            var directory = ""
            for component in components.dropLast() {
                directory = directory.isEmpty ? String(component) : directory + "/" + component
                directories.insert(directory)
            }
        }
        changesByRelativePath = changes
        changedDirectoryPaths = directories
    }

    func badge(for entry: DesktopWorkspaceFileEntry) -> String? {
        if entry.isDirectory {
            return changedDirectoryPaths.contains(entry.relativePath) ? "•" : nil
        }
        guard let change = changesByRelativePath[entry.relativePath] else { return nil }
        if change.isUnmerged { return "!" }
        if change.isUntracked { return "U" }
        if change.indexStatus == .added { return "A" }
        if change.indexStatus == .deleted || change.worktreeStatus == .deleted { return "D" }
        return "M"
    }
}

private func desktopFileIcon(_ entry: DesktopWorkspaceFileEntry) -> String {
    if entry.isDirectory { return "folder" }
    if entry.isSymbolicLink { return "link" }
    if entry.contentType?.conforms(to: .image) == true { return "photo" }
    if entry.contentType?.conforms(to: .pdf) == true { return "doc.richtext" }
    if entry.contentType?.conforms(to: .audio) == true { return "waveform" }
    if entry.contentType?.conforms(to: .movie) == true { return "film" }
    if entry.isEditableText { return "doc.text" }
    return "doc"
}

private struct DesktopQuickLookPreview: NSViewRepresentable {
    let url: URL
    let workspaceURL: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView(frame: .zero)!
        view.autostarts = false
        view.shouldCloseWithWindow = true
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        let workspace = workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = url.standardizedFileURL
        var status = stat()
        let isRegularFile = Darwin.lstat(candidate.path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG
        let resolved = candidate.resolvingSymlinksInPath()
        let isContained = resolved.path.hasPrefix(workspace.path + "/")
        view.previewItem = isRegularFile && isContained ? resolved as NSURL : nil
        view.refreshPreviewItem()
    }
}

private struct DesktopNativeTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let contentSize = scrollView.contentSize
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: container)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 9, height: 9)
        textView.autoresizingMask = [NSView.AutoresizingMask.width]
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        scrollView.documentView = textView

        let ruler = DesktopLineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView, textView.string != text else { return }
        let selection = textView.selectedRanges
        textView.string = text
        textView.selectedRanges = selection
        context.coordinator.ruler?.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        weak var ruler: NSRulerView?

        init(text: Binding<String>) { _text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            ruler?.needsDisplay = true
        }
    }
}

private final class DesktopLineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 42
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        let visible = textView.enclosingScrollView?.contentView.bounds ?? .zero
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let text = textView.string as NSString
        var lineNumber = 1
        var location = 0
        while location < text.length, location < layoutManager.characterIndexForGlyph(at: glyphRange.location) {
            location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            lineNumber += 1
        }
        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineRange = text.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: lineGlyphRange, in: container)
            let y = rect.minY + textView.textContainerInset.height - visible.minY
            let label = NSAttributedString(
                string: String(lineNumber),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]
            )
            let size = label.size()
            label.draw(at: NSPoint(x: ruleThickness - size.width - 7, y: y))
            glyphIndex = NSMaxRange(lineGlyphRange)
            lineNumber += 1
        }
    }
}
