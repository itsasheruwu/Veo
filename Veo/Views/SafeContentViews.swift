// FILE: SafeContentViews.swift
// Purpose: Presents local citations, tool artifacts, and Mermaid diagrams without implicit external execution.
// Layer: Desktop app view

import AppKit
import Darwin
import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - External URLs

enum SafeExternalURLPolicy {
    static func validatedHTTPSURL(_ candidate: URL) -> URL? {
        guard candidate.scheme?.lowercased() == "https",
              candidate.host?.isEmpty == false,
              candidate.user == nil,
              candidate.password == nil else { return nil }
        return candidate
    }

    /// Call only from a visible Button, Link, or SwiftUI openURL user action.
    @MainActor
    static func openFromUserAction(_ candidate: URL) -> Bool {
        guard let url = validatedHTTPSURL(candidate) else { return false }
        return NSWorkspace.shared.open(url)
    }
}

// MARK: - Local file validation

private enum SafeLocalFileKind {
    case text
    case image
    case pdf
    case other
}

private struct SafeLocalFileDescriptor {
    static let maximumTextBytes: Int64 = 1_048_576
    static let maximumImageBytes: Int64 = 16_777_216
    static let maximumPDFBytes: Int64 = 26_214_400

    let url: URL
    let canonicalPath: String
    let displayLabel: String
    let isOutsideWorkspace: Bool
    let workspaceScopeKnown: Bool
    let contentType: UTType
    let kind: SafeLocalFileKind
    let byteCount: Int64
    let deviceID: UInt64
    let inode: UInt64

    static func inspect(
        path: String,
        declaredMIMEType: String? = nil,
        workspaceURL: URL?
    ) throws -> SafeLocalFileDescriptor {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SafeContentError.invalidPath }

        let candidate: URL
        if NSString(string: trimmed).isAbsolutePath {
            candidate = URL(fileURLWithPath: trimmed)
        } else if let workspaceURL {
            candidate = workspaceURL.appendingPathComponent(trimmed)
        } else {
            throw SafeContentError.ambiguousRelativePath
        }

        let canonicalURL = candidate.standardizedFileURL.resolvingSymlinksInPath()
        var fileStatus = stat()
        guard Darwin.lstat(canonicalURL.path, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG else {
            throw SafeContentError.notRegularFile
        }
        let values = try canonicalURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentTypeKey,
        ])
        guard values.isRegularFile == true else { throw SafeContentError.notRegularFile }

        let byteCount = Int64(values.fileSize ?? 0)
        guard byteCount >= 0 else { throw SafeContentError.invalidFileSize }
        guard let contentType = values.contentType
                ?? UTType(filenameExtension: canonicalURL.pathExtension) else {
            throw SafeContentError.unknownFileType
        }

        let kind = kind(for: contentType)
        if let declaredMIMEType, !declaredMIMEType.isEmpty {
            guard let declaredType = UTType(mimeType: declaredMIMEType),
                  kindsAreCompatible(kind, Self.kind(for: declaredType)) else {
                throw SafeContentError.mimeTypeMismatch
            }
        }

        let canonicalWorkspace = workspaceURL?
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let insideWorkspace = canonicalWorkspace.map {
            contains(canonicalURL, inside: $0)
        } ?? false
        let displayLabel: String
        if let canonicalWorkspace, insideWorkspace {
            displayLabel = relativePath(from: canonicalWorkspace, to: canonicalURL)
        } else {
            displayLabel = canonicalURL.lastPathComponent.nilIfEmpty ?? canonicalURL.path
        }

        return SafeLocalFileDescriptor(
            url: canonicalURL,
            canonicalPath: canonicalURL.path,
            displayLabel: displayLabel,
            isOutsideWorkspace: !insideWorkspace,
            workspaceScopeKnown: canonicalWorkspace != nil,
            contentType: contentType,
            kind: kind,
            byteCount: byteCount,
            deviceID: UInt64(fileStatus.st_dev),
            inode: UInt64(fileStatus.st_ino)
        )
    }

    func validateReadLimit() throws {
        switch kind {
        case .text:
            guard byteCount <= Self.maximumTextBytes else { throw SafeContentError.fileTooLarge }
        case .image:
            guard byteCount <= Self.maximumImageBytes else { throw SafeContentError.fileTooLarge }
        case .pdf:
            guard byteCount <= Self.maximumPDFBytes else { throw SafeContentError.fileTooLarge }
        case .other:
            throw SafeContentError.unsupportedPreviewType
        }
    }

    private static func kind(for type: UTType) -> SafeLocalFileKind {
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .text)
            || type.conforms(to: .sourceCode)
            || type.conforms(to: .json)
            || type.conforms(to: .xml) {
            return .text
        }
        return .other
    }

    private static func kindsAreCompatible(_ lhs: SafeLocalFileKind, _ rhs: SafeLocalFileKind) -> Bool {
        switch (lhs, rhs) {
        case (.text, .text), (.image, .image), (.pdf, .pdf), (.other, .other): return true
        default: return false
        }
    }

    private static func contains(_ candidate: URL, inside root: URL) -> Bool {
        let candidateComponents = candidate.pathComponents
        let rootComponents = root.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }

    private static func relativePath(from root: URL, to file: URL) -> String {
        let rootComponents = root.pathComponents
        let fileComponents = file.pathComponents
        let suffix = fileComponents.dropFirst(rootComponents.count)
        return suffix.isEmpty ? file.lastPathComponent : suffix.joined(separator: "/")
    }
}

private enum SafeContentError: LocalizedError {
    case invalidPath
    case ambiguousRelativePath
    case notRegularFile
    case invalidFileSize
    case unknownFileType
    case mimeTypeMismatch
    case fileTooLarge
    case unsupportedPreviewType
    case unreadableText
    case unreadableImage
    case unreadablePDF
    case fileChanged

    var errorDescription: String? {
        switch self {
        case .invalidPath: return "The file path is empty or invalid."
        case .ambiguousRelativePath: return "A relative path cannot be resolved without a workspace."
        case .notRegularFile: return "This path is not a regular local file."
        case .invalidFileSize: return "The file size is invalid."
        case .unknownFileType: return "The file type could not be verified."
        case .mimeTypeMismatch: return "The declared MIME type does not match the local file."
        case .fileTooLarge: return "The file is too large for an inline preview."
        case .unsupportedPreviewType: return "This verified file type has no safe inline preview."
        case .unreadableText: return "The file is not valid UTF-8 or UTF-16 text."
        case .unreadableImage: return "The image could not be decoded safely."
        case .unreadablePDF: return "The PDF could not be decoded safely."
        case .fileChanged: return "The file changed after Veo verified it. Preview it again."
        }
    }
}

// MARK: - Citations

struct SafeCitationListView: View {
    let citations: [DesktopCitationEntry]
    let workspaceURL: URL?

    var body: some View {
        if !citations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Sources", systemImage: "quote.opening")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(citations) { citation in
                    SafeCitationRow(citation: citation, workspaceURL: workspaceURL)
                }
            }
        }
    }
}

private struct SafeCitationRow: View {
    let citation: DesktopCitationEntry
    let workspaceURL: URL?
    @State private var showsPreview = false
    @State private var previewText: String?
    @State private var failureMessage: String?
    @State private var isLoading = false

    private var inspection: Result<SafeLocalFileDescriptor, Error> {
        Result {
            try SafeLocalFileDescriptor.inspect(path: citation.path, workspaceURL: workspaceURL)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayLabel)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    Text("Lines \(max(1, citation.lineStart))–\(max(citation.lineStart, citation.lineEnd))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if isOutsideWorkspace {
                    Label("Outside workspace", systemImage: "exclamationmark.shield")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                Button(showsPreview ? "Hide" : "Preview") {
                    togglePreview()
                }
                .buttonStyle(.borderless)
                .disabled(isLoading)
            }

            if isOutsideWorkspace {
                Text(scopeDisclosure)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !citation.note.isEmpty {
                Text(citation.note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if isLoading {
                ProgressView().controlSize(.small)
            } else if let previewText, showsPreview {
                SafeTextLinePreview(
                    text: previewText,
                    lineStart: citation.lineStart,
                    lineEnd: citation.lineEnd
                )
                .frame(height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else if let failureMessage, showsPreview {
                Label(failureMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private var descriptor: SafeLocalFileDescriptor? { try? inspection.get() }
    private var displayLabel: String { descriptor?.displayLabel ?? citation.path }
    private var isOutsideWorkspace: Bool { descriptor?.isOutsideWorkspace ?? true }
    private var scopeDisclosure: String {
        guard let descriptor else { return "The path could not be verified inside the current workspace. \(citation.path)" }
        if descriptor.workspaceScopeKnown {
            return "This citation resolves outside the current workspace: \(descriptor.canonicalPath)"
        }
        return "Workspace scope was not supplied; treating this path as outside: \(descriptor.canonicalPath)"
    }

    private func togglePreview() {
        if showsPreview {
            showsPreview = false
            return
        }
        showsPreview = true
        guard previewText == nil else { return }
        failureMessage = nil
        isLoading = true
        let result = inspection
        Task {
            do {
                let descriptor = try result.get()
                guard descriptor.kind == .text else { throw SafeContentError.unsupportedPreviewType }
                try descriptor.validateReadLimit()
                let text = try await SafeLocalLoader.readText(descriptor)
                guard showsPreview else { return }
                previewText = text
            } catch {
                failureMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private enum SafeLocalLoader {
    static func readText(_ descriptor: SafeLocalFileDescriptor) async throws -> String {
        let data = try await readData(descriptor, maximumBytes: SafeLocalFileDescriptor.maximumTextBytes)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        throw SafeContentError.unreadableText
    }

    static func readImage(_ descriptor: SafeLocalFileDescriptor) async throws -> NSImage {
        let data = try await readData(descriptor, maximumBytes: SafeLocalFileDescriptor.maximumImageBytes)
        guard let image = NSImage(data: data), image.isValid else { throw SafeContentError.unreadableImage }
        return image
    }

    static func readPDFData(_ descriptor: SafeLocalFileDescriptor) async throws -> Data {
        let data = try await readData(descriptor, maximumBytes: SafeLocalFileDescriptor.maximumPDFBytes)
        guard data.starts(with: Data("%PDF-".utf8)), PDFDocument(data: data) != nil else {
            throw SafeContentError.unreadablePDF
        }
        return data
    }

    private static func readData(
        _ descriptor: SafeLocalFileDescriptor,
        maximumBytes: Int64
    ) async throws -> Data {
        guard descriptor.byteCount <= maximumBytes else { throw SafeContentError.fileTooLarge }
        return try await Task.detached(priority: .utility) {
            let descriptorFlags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            let fileDescriptor = Darwin.open(descriptor.canonicalPath, descriptorFlags)
            guard fileDescriptor >= 0 else { throw SafeContentError.fileChanged }
            var openedStatus = stat()
            guard Darwin.fstat(fileDescriptor, &openedStatus) == 0,
                  (openedStatus.st_mode & S_IFMT) == S_IFREG,
                  UInt64(openedStatus.st_dev) == descriptor.deviceID,
                  UInt64(openedStatus.st_ino) == descriptor.inode,
                  openedStatus.st_size >= 0,
                  openedStatus.st_size <= maximumBytes else {
                Darwin.close(fileDescriptor)
                throw SafeContentError.fileChanged
            }
            let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Int(maximumBytes + 1)) ?? Data()
            guard data.count <= maximumBytes else { throw SafeContentError.fileTooLarge }
            return data
        }.value
    }
}

private struct SafeTextLinePreview: NSViewRepresentable {
    let text: String
    let lineStart: Int
    let lineEnd: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        update(textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(textView, coordinator: context.coordinator)
    }

    private func update(_ textView: NSTextView, coordinator: Coordinator) {
        let signature = "\(text.hashValue):\(lineStart):\(lineEnd)"
        guard coordinator.signature != signature else { return }
        coordinator.signature = signature

        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: NSColor.textColor,
            ]
        )
        let highlightedRange = Self.lineRange(
            in: text,
            from: max(1, lineStart),
            through: max(lineStart, lineEnd)
        )
        if highlightedRange.location != NSNotFound, highlightedRange.length > 0 {
            attributed.addAttribute(
                .backgroundColor,
                value: NSColor.controlAccentColor.withAlphaComponent(0.2),
                range: highlightedRange
            )
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        if highlightedRange.location != NSNotFound {
            DispatchQueue.main.async {
                textView.scrollRangeToVisible(highlightedRange)
            }
        } else {
            textView.scrollRangeToVisible(fullRange.length > 0 ? NSRange(location: 0, length: 1) : fullRange)
        }
    }

    private static func lineRange(in text: String, from startLine: Int, through endLine: Int) -> NSRange {
        let value = text as NSString
        guard value.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        var line = 1
        var position = 0
        var selectionStart: Int?
        var selectionEnd: Int?

        while position < value.length {
            let range = value.lineRange(for: NSRange(location: position, length: 0))
            if line == startLine { selectionStart = range.location }
            if line == endLine {
                selectionEnd = NSMaxRange(range)
                break
            }
            let next = NSMaxRange(range)
            guard next > position else { break }
            position = next
            line += 1
        }

        guard let selectionStart else { return NSRange(location: NSNotFound, length: 0) }
        let end = selectionEnd ?? value.length
        return NSRange(location: selectionStart, length: max(0, end - selectionStart))
    }

    final class Coordinator {
        var signature: String?
    }
}

// MARK: - Tool artifacts

struct SafeToolArtifactListView: View {
    let artifacts: [DesktopToolArtifact]
    let workspaceURL: URL?
    let blockedURL: (String) -> Void

    var body: some View {
        if !artifacts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Artifacts", systemImage: "shippingbox")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(artifacts) { artifact in
                    SafeToolArtifactRow(
                        artifact: artifact,
                        workspaceURL: workspaceURL,
                        blockedURL: blockedURL
                    )
                }
            }
        }
    }
}

private struct SafeToolArtifactRow: View {
    let artifact: DesktopToolArtifact
    let workspaceURL: URL?
    let blockedURL: (String) -> Void
    @State private var showsText = false
    @State private var showsPDF = false
    @State private var allowsOutsideWorkspacePreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(artifact.displayName)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(detailLabel)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                action
            }

            switch artifact.kind {
            case .text where showsText:
                ScrollView {
                    Text(boundedArtifactText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))

            case .localFile:
                localPreview

            case .inlineImage:
                SafeInlineArtifactImage(artifact: artifact)

            default:
                EmptyView()
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var action: some View {
        switch artifact.kind {
        case .text:
            Button(showsText ? "Hide" : "Show") { showsText.toggle() }
                .buttonStyle(.borderless)
        case .remoteImage, .remoteAudio, .resource:
            Button("Open") {
                guard let url = URL(string: artifact.source),
                      SafeExternalURLPolicy.openFromUserAction(url) else {
                    blockedURL("Only HTTPS artifact links can be opened.")
                    return
                }
            }
            .buttonStyle(.borderless)
        case .localFile, .inlineImage, .inlineAudio, .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private var localPreview: some View {
        switch localInspection {
        case .success(let descriptor):
            if descriptor.isOutsideWorkspace {
                Label(outsideDisclosure(descriptor), systemImage: "exclamationmark.shield")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if descriptor.isOutsideWorkspace && !allowsOutsideWorkspacePreview {
                Button("Allow preview outside workspace") {
                    allowsOutsideWorkspacePreview = true
                }
                .buttonStyle(.borderless)
            } else {
                validatedLocalPreview(descriptor)
            }
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func validatedLocalPreview(_ descriptor: SafeLocalFileDescriptor) -> some View {
        switch descriptor.kind {
        case .image:
            SafeLocalImagePreview(descriptor: descriptor)
        case .pdf:
            Button(showsPDF ? "Hide PDF preview" : "Preview PDF") {
                showsPDF.toggle()
            }
            .buttonStyle(.borderless)
            if showsPDF {
                SafeLocalPDFPreview(descriptor: descriptor)
            }
        case .text, .other:
            Label("Verified local file; no automatic preview.", systemImage: "doc")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    private var localInspection: Result<SafeLocalFileDescriptor, Error> {
        Result {
            try SafeLocalFileDescriptor.inspect(
                path: artifact.source,
                declaredMIMEType: artifact.mimeType,
                workspaceURL: workspaceURL
            )
        }
    }

    private var localDescriptor: SafeLocalFileDescriptor? { try? localInspection.get() }
    private var iconName: String {
        switch artifact.kind {
        case .text: return "doc.text"
        case .localFile:
            switch localDescriptor?.kind {
            case .image: return "photo"
            case .pdf: return "doc.richtext"
            default: return "doc"
            }
        case .inlineImage: return "photo"
        case .inlineAudio: return "waveform"
        case .remoteImage: return "photo.badge.arrow.down"
        case .remoteAudio: return "waveform.badge.magnifyingglass"
        case .resource: return "link"
        case .unknown: return "questionmark.square.dashed"
        }
    }

    private var detailLabel: String {
        switch artifact.kind {
        case .localFile:
            return localDescriptor?.displayLabel ?? artifact.source
        case .inlineImage: return artifact.mimeType ?? "Inline image"
        case .inlineAudio: return "Inline audio preview unavailable"
        case .remoteImage: return "Remote image — never fetched inline"
        case .remoteAudio: return "Remote audio — never fetched inline"
        case .resource: return artifact.source
        case .text: return artifact.mimeType ?? "text/plain"
        case .unknown(let type): return "Unsupported artifact: \(type)"
        }
    }

    private var boundedArtifactText: String {
        let limit = 131_072
        guard artifact.source.count > limit else { return artifact.source }
        return String(artifact.source.prefix(limit)) + "\n\n[Text artifact truncated for inline display.]"
    }

    private func outsideDisclosure(_ descriptor: SafeLocalFileDescriptor) -> String {
        if descriptor.workspaceScopeKnown {
            return "Outside workspace: \(descriptor.canonicalPath)"
        }
        return "Workspace scope unavailable; treated as outside: \(descriptor.canonicalPath)"
    }
}

private struct SafeInlineArtifactImage: View {
    let artifact: DesktopToolArtifact

    var body: some View {
        if let image = decodedImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: 520, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Label("Inline image data was invalid or exceeded the 8 MiB preview limit.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
        }
    }

    private var decodedImage: NSImage? {
        guard artifact.mimeType?.lowercased().hasPrefix("image/") != false,
              artifact.source.utf8.count <= 12_000_000,
              let data = Data(base64Encoded: artifact.source, options: [.ignoreUnknownCharacters]),
              data.count <= 8 * 1_024 * 1_024 else { return nil }
        return NSImage(data: data)
    }
}

private struct SafeLocalImagePreview: View {
    let descriptor: SafeLocalFileDescriptor
    @State private var image: NSImage?
    @State private var failureMessage: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: 520, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if let failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: descriptor.canonicalPath) {
            do {
                try descriptor.validateReadLimit()
                guard descriptor.kind == .image else { throw SafeContentError.unsupportedPreviewType }
                image = try await SafeLocalLoader.readImage(descriptor)
            } catch {
                failureMessage = error.localizedDescription
            }
        }
    }
}

private struct SafeLocalPDFPreview: View {
    let descriptor: SafeLocalFileDescriptor
    @State private var data: Data?
    @State private var failureMessage: String?

    var body: some View {
        Group {
            if let data {
                SafePDFKitView(data: data)
                    .frame(height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else if let failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: descriptor.canonicalPath) {
            do {
                try descriptor.validateReadLimit()
                guard descriptor.kind == .pdf else { throw SafeContentError.unreadablePDF }
                data = try await SafeLocalLoader.readPDFData(descriptor)
            } catch {
                failureMessage = error.localizedDescription
            }
        }
    }
}

private struct SafePDFKitView: NSViewRepresentable {
    let data: Data

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        update(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        update(view, coordinator: context.coordinator)
    }

    private func update(_ view: PDFView, coordinator: Coordinator) {
        let signature = data.hashValue
        guard coordinator.signature != signature else { return }
        coordinator.signature = signature
        guard let document = PDFDocument(data: data) else {
            view.document = nil
            return
        }
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                annotation.action = nil
                annotation.removeValue(forAnnotationKey: .action)
                annotation.removeValue(forAnnotationKey: .additionalActions)
            }
        }
        view.document = document
    }

    final class Coordinator {
        var signature: Int?
    }
}

// MARK: - Conservative Mermaid rendering

struct SafeMermaidDiagram: Hashable {
    enum Direction: Hashable {
        case topDown
        case leftRight
    }

    enum NodeShape: Hashable {
        case rectangle
        case rounded
        case decision
    }

    struct Node: Identifiable, Hashable {
        let id: String
        let label: String
        let shape: NodeShape
    }

    struct Edge: Hashable {
        let sourceID: String
        let destinationID: String
    }

    let direction: Direction
    let nodes: [Node]
    let edges: [Edge]
    let levels: [[String]]

    static func parse(_ source: String) -> SafeMermaidDiagram? {
        guard source.utf8.count <= 12_288 else { return nil }
        let lines = source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let header = lines.first else { return nil }

        let headerParts = header.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard headerParts.count == 2,
              headerParts[0].lowercased() == "flowchart" || headerParts[0].lowercased() == "graph" else {
            return nil
        }
        let direction: Direction
        switch headerParts[1].uppercased() {
        case "TD", "TB": direction = .topDown
        case "LR": direction = .leftRight
        default: return nil
        }

        var nodesByID: [String: Node] = [:]
        var edges: [Edge] = []
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            guard !["click ", "style ", "class ", "classdef ", "subgraph", "end"].contains(where: lower.hasPrefix),
                  !line.contains("<"), !line.contains(">"), !line.contains(";") else { return nil }

            let parts = line.components(separatedBy: "-->")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard !parts.isEmpty, parts.count <= 8 else { return nil }
            var parsedNodes: [Node] = []
            for part in parts {
                guard let node = parseNode(part) else { return nil }
                if let existing = nodesByID[node.id], existing != node { return nil }
                nodesByID[node.id] = node
                parsedNodes.append(node)
            }
            if parsedNodes.count > 1 {
                for pair in zip(parsedNodes, parsedNodes.dropFirst()) {
                    edges.append(Edge(sourceID: pair.0.id, destinationID: pair.1.id))
                }
            }
            guard nodesByID.count <= 24, edges.count <= 32 else { return nil }
        }
        guard !nodesByID.isEmpty else { return nil }

        let nodes = nodesByID.values.sorted { $0.id < $1.id }
        guard let levels = topologicalLevels(nodes: nodes, edges: edges) else { return nil }
        return SafeMermaidDiagram(direction: direction, nodes: nodes, edges: edges, levels: levels)
    }

    private static func parseNode(_ token: String) -> Node? {
        let pattern = #"^([A-Za-z][A-Za-z0-9_-]*)(?:\[([^\]]+)\]|\(([^\)]+)\)|\{([^\}]+)\})?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: token,
                range: NSRange(token.startIndex..., in: token)
              ),
              match.range == NSRange(token.startIndex..., in: token),
              let idRange = Range(match.range(at: 1), in: token) else { return nil }
        let id = String(token[idRange])
        let groups = 2...4
        var label = id
        var shape: NodeShape = .rectangle
        for group in groups where match.range(at: group).location != NSNotFound {
            guard let range = Range(match.range(at: group), in: token) else { continue }
            label = String(token[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            shape = group == 3 ? .rounded : (group == 4 ? .decision : .rectangle)
        }
        if label.hasPrefix("\"") && label.hasSuffix("\"") && label.count >= 2 {
            label.removeFirst()
            label.removeLast()
        }
        guard !label.isEmpty, label.count <= 100 else { return nil }
        return Node(id: id, label: label, shape: shape)
    }

    private static func topologicalLevels(nodes: [Node], edges: [Edge]) -> [[String]]? {
        var incoming = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        var outgoing: [String: [String]] = [:]
        for edge in edges {
            incoming[edge.destinationID, default: 0] += 1
            outgoing[edge.sourceID, default: []].append(edge.destinationID)
        }
        var ready = incoming.filter { $0.value == 0 }.map(\.key).sorted()
        var levels: [[String]] = []
        var visited = Set<String>()
        while !ready.isEmpty {
            let level = ready
            levels.append(level)
            ready = []
            for id in level {
                guard visited.insert(id).inserted else { return nil }
                for destination in outgoing[id, default: []] {
                    incoming[destination, default: 0] -= 1
                    if incoming[destination] == 0 { ready.append(destination) }
                }
            }
            ready.sort()
        }
        return visited.count == nodes.count ? levels : nil
    }
}

struct SafeMermaidPreviewView: View {
    let diagram: SafeMermaidDiagram
    let source: String
    @Environment(\.colorScheme) private var colorScheme

    private let nodeSize = CGSize(width: 152, height: 52)
    private let levelGap: CGFloat = 58
    private let peerGap: CGFloat = 22
    private let inset: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Mermaid preview", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Native · non-executing")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            ScrollView([.horizontal, .vertical]) {
                Canvas { context, _ in
                    drawEdges(in: &context)
                    drawNodes(in: &context)
                }
                .frame(width: canvasSize.width, height: canvasSize.height)
            }
            .frame(maxWidth: .infinity)
            .frame(height: min(canvasSize.height, 360))
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))

            DisclosureGroup("Mermaid source") {
                Text(source)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .font(.system(size: 10.5, weight: .medium))
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var canvasSize: CGSize {
        let maximumPeers = CGFloat(diagram.levels.map(\.count).max() ?? 1)
        let levelCount = CGFloat(max(1, diagram.levels.count))
        switch diagram.direction {
        case .topDown:
            return CGSize(
                width: max(360, inset * 2 + maximumPeers * nodeSize.width + max(0, maximumPeers - 1) * peerGap),
                height: inset * 2 + levelCount * nodeSize.height + max(0, levelCount - 1) * levelGap
            )
        case .leftRight:
            return CGSize(
                width: max(360, inset * 2 + levelCount * nodeSize.width + max(0, levelCount - 1) * levelGap),
                height: inset * 2 + maximumPeers * nodeSize.height + max(0, maximumPeers - 1) * peerGap
            )
        }
    }

    private var nodeCenters: [String: CGPoint] {
        var centers: [String: CGPoint] = [:]
        for (levelIndex, level) in diagram.levels.enumerated() {
            for (peerIndex, id) in level.enumerated() {
                switch diagram.direction {
                case .topDown:
                    let levelWidth = CGFloat(level.count) * nodeSize.width
                        + CGFloat(max(0, level.count - 1)) * peerGap
                    let originX = (canvasSize.width - levelWidth) / 2
                    centers[id] = CGPoint(
                        x: originX + nodeSize.width / 2 + CGFloat(peerIndex) * (nodeSize.width + peerGap),
                        y: inset + nodeSize.height / 2 + CGFloat(levelIndex) * (nodeSize.height + levelGap)
                    )
                case .leftRight:
                    let levelHeight = CGFloat(level.count) * nodeSize.height
                        + CGFloat(max(0, level.count - 1)) * peerGap
                    let originY = (canvasSize.height - levelHeight) / 2
                    centers[id] = CGPoint(
                        x: inset + nodeSize.width / 2 + CGFloat(levelIndex) * (nodeSize.width + levelGap),
                        y: originY + nodeSize.height / 2 + CGFloat(peerIndex) * (nodeSize.height + peerGap)
                    )
                }
            }
        }
        return centers
    }

    private func drawEdges(in context: inout GraphicsContext) {
        let centers = nodeCenters
        for edge in diagram.edges {
            guard let source = centers[edge.sourceID], let destination = centers[edge.destinationID] else { continue }
            let start: CGPoint
            let end: CGPoint
            switch diagram.direction {
            case .topDown:
                start = CGPoint(x: source.x, y: source.y + nodeSize.height / 2)
                end = CGPoint(x: destination.x, y: destination.y - nodeSize.height / 2)
            case .leftRight:
                start = CGPoint(x: source.x + nodeSize.width / 2, y: source.y)
                end = CGPoint(x: destination.x - nodeSize.width / 2, y: destination.y)
            }
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(.secondary.opacity(0.65)), lineWidth: 1.4)

            let angle = atan2(end.y - start.y, end.x - start.x)
            let arrowLength: CGFloat = 8
            var arrow = Path()
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(
                x: end.x - arrowLength * cos(angle - .pi / 6),
                y: end.y - arrowLength * sin(angle - .pi / 6)
            ))
            arrow.move(to: end)
            arrow.addLine(to: CGPoint(
                x: end.x - arrowLength * cos(angle + .pi / 6),
                y: end.y - arrowLength * sin(angle + .pi / 6)
            ))
            context.stroke(arrow, with: .color(.secondary.opacity(0.65)), lineWidth: 1.4)
        }
    }

    private func drawNodes(in context: inout GraphicsContext) {
        let centers = nodeCenters
        for node in diagram.nodes {
            guard let center = centers[node.id] else { continue }
            let rect = CGRect(
                x: center.x - nodeSize.width / 2,
                y: center.y - nodeSize.height / 2,
                width: nodeSize.width,
                height: nodeSize.height
            )
            var path = Path()
            switch node.shape {
            case .rectangle:
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 6, height: 6))
            case .rounded:
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 18, height: 18))
            case .decision:
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                path.closeSubpath()
            }
            context.fill(path, with: .color(colorScheme == .dark ? .black.opacity(0.35) : .white.opacity(0.9)))
            context.stroke(path, with: .color(.accentColor.opacity(0.72)), lineWidth: 1.3)

            let text = Text(node.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
            context.draw(context.resolve(text), at: center, anchor: .center)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
