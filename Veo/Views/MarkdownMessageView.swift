// FILE: MarkdownMessageView.swift
// Purpose: Renders assistant markdown with real line breaks and separated code blocks.
// Layer: Desktop app view
// Depends on: SwiftUI, AppKit

import AppKit
import SwiftUI

struct MarkdownMessageView: View {
    let source: String
    let fontSize: CGFloat
    let artifacts: [DesktopToolArtifact]
    let citations: [DesktopCitationEntry]
    let workspaceURL: URL?
    var isStreaming = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blockedURLMessage: String?
    @State private var displayedCharacterCount = 0
    @State private var targetCharacterCount = 0
    @State private var previousSource = ""
    @State private var revealTask: Task<Void, Never>?

    init(
        source: String,
        fontSize: CGFloat = 14,
        artifacts: [DesktopToolArtifact] = [],
        citations: [DesktopCitationEntry] = [],
        workspaceURL: URL? = nil,
        isStreaming: Bool = false
    ) {
        self.source = source
        self.fontSize = fontSize
        self.artifacts = artifacts
        self.citations = citations
        self.workspaceURL = workspaceURL
        self.isStreaming = isStreaming
    }

    var body: some View {
        let blocks = MarkdownBlock.parse(renderedSource)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                switch block.kind {
                case .prose:
                    if shouldAnimateTextStream, index == blocks.count - 1 {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                            proseText(
                                block.text,
                                cursorOpacity: Self.cursorOpacity(at: context.date)
                            )
                        }
                    } else {
                        proseText(block.text)
                    }
                case .code:
                    if block.language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid",
                       let diagram = SafeMermaidDiagram.parse(block.text) {
                        SafeMermaidPreviewView(diagram: diagram, source: block.text)
                    } else {
                        CodeBlockView(code: block.text, language: block.language)
                    }
                }
            }

            if shouldAnimateTextStream, blocks.last?.kind == .code {
                DesktopStreamingTextCursor()
            }

            SafeToolArtifactListView(
                artifacts: artifacts,
                workspaceURL: workspaceURL,
                blockedURL: { blockedURLMessage = $0 }
            )
            SafeCitationListView(citations: citations, workspaceURL: workspaceURL)

            if let blockedURLMessage {
                Label(blockedURLMessage, systemImage: "hand.raised.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Blocked unsafe link")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if SafeExternalURLPolicy.openFromUserAction(url) {
                blockedURLMessage = nil
            } else {
                blockedURLMessage = "Blocked link. Veo opens only HTTPS links after a user click."
            }
            return .handled
        })
        .onAppear(perform: prepareInitialReveal)
        .onChange(of: source) { _, updatedSource in
            receiveStreamUpdate(updatedSource)
        }
        .onChange(of: isStreaming) { _, _ in
            updateStreamingState()
        }
        .onChange(of: reduceMotion) { _, _ in
            updateStreamingState()
        }
        .onDisappear {
            revealTask?.cancel()
            revealTask = nil
        }
    }

    private var shouldAnimateTextStream: Bool {
        isStreaming && !reduceMotion && !renderedSource.isEmpty
    }

    private var renderedSource: String {
        guard isStreaming, !reduceMotion else { return source }
        return String(source.prefix(min(displayedCharacterCount, source.count)))
    }

    private func proseText(_ source: String, cursorOpacity: Double? = nil) -> some View {
        Text(attributedProse(source, cursorOpacity: cursorOpacity))
            .font(.system(size: fontSize))
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func attributedProse(_ source: String, cursorOpacity: Double?) -> AttributedString {
        var attributed = Self.inlineAttributed(source)
        if let cursorOpacity {
            var cursor = AttributedString(" ▍")
            cursor.foregroundColor = Color.primary.opacity(cursorOpacity)
            attributed += cursor
        }
        return attributed
    }

    private func prepareInitialReveal() {
        previousSource = source
        targetCharacterCount = source.count
        guard isStreaming, !reduceMotion else {
            displayedCharacterCount = source.count
            return
        }

        // A row restored mid-turn should remain readable; only fresh, short opening
        // chunks animate in from zero.
        displayedCharacterCount = source.count > 160 ? source.count : 0
        startRevealLoopIfNeeded()
    }

    private func receiveStreamUpdate(_ updatedSource: String) {
        let isAppend = updatedSource.hasPrefix(previousSource)
        previousSource = updatedSource
        targetCharacterCount = updatedSource.count

        guard isStreaming, !reduceMotion else {
            displayedCharacterCount = updatedSource.count
            return
        }

        if !isAppend {
            // A reconciliation can replace text rather than append it. Show the
            // corrected content immediately instead of replaying stale characters.
            displayedCharacterCount = updatedSource.count
            return
        }

        displayedCharacterCount = min(displayedCharacterCount, updatedSource.count)
        startRevealLoopIfNeeded()
    }

    private func updateStreamingState() {
        targetCharacterCount = source.count
        previousSource = source
        guard isStreaming, !reduceMotion else {
            revealTask?.cancel()
            revealTask = nil
            displayedCharacterCount = source.count
            return
        }
        displayedCharacterCount = min(displayedCharacterCount, source.count)
        startRevealLoopIfNeeded()
    }

    private func startRevealLoopIfNeeded() {
        guard revealTask == nil,
              isStreaming,
              !reduceMotion,
              displayedCharacterCount < targetCharacterCount else { return }

        revealTask = Task { @MainActor in
            while !Task.isCancelled,
                  isStreaming,
                  !reduceMotion,
                  displayedCharacterCount < targetCharacterCount {
                let remaining = targetCharacterCount - displayedCharacterCount
                displayedCharacterCount += min(max(1, remaining / 6), 10)
                try? await Task.sleep(for: .milliseconds(18))
            }
            if !Task.isCancelled {
                revealTask = nil
                if isStreaming, !reduceMotion, displayedCharacterCount < targetCharacterCount {
                    startRevealLoopIfNeeded()
                }
            }
        }
    }

    private static func cursorOpacity(at date: Date) -> Double {
        let period = 0.9
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        return 0.32 + (0.68 * (0.5 + 0.5 * sin(phase * .pi * 2)))
    }

    /// `AttributedString(markdown:)` defaults to full block parsing, which throws away
    /// paragraph breaks when flattened into a single run. Inline-only keeps the whitespace.
    static func inlineAttributed(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
    }
}

private struct DesktopStreamingTextCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            RoundedRectangle(cornerRadius: 0.75, style: .continuous)
                .fill(Color.primary.opacity(Self.opacity(at: context.date)))
                .frame(width: 1.5, height: 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
        .opacity(reduceMotion ? 0 : 1)
    }

    private static func opacity(at date: Date) -> Double {
        let period = 0.9
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        return 0.32 + (0.68 * (0.5 + 0.5 * sin(phase * .pi * 2)))
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String?
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language.flatMap { $0.isEmpty ? nil : $0 } ?? "code")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { didCopy = false }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider().opacity(0.4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct MarkdownBlock: Identifiable {
    enum Kind: String {
        case prose
        case code
    }

    /// A source-position identity keeps completed leading blocks mounted while a
    /// streamed tail changes. UUIDs caused every parsed block to be recreated.
    let id: String
    let kind: Kind
    let text: String
    let language: String?

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var buffer: [String] = []
        var bufferStartLine: Int?
        var isInFence = false
        var fenceLanguage: String?

        func flush(as kind: Kind, language: String?) {
            let text = buffer
                .joined(separator: "\n")
                .trimmingCharacters(in: kind == .code ? .newlines : .whitespacesAndNewlines)
            buffer.removeAll()
            defer { bufferStartLine = nil }
            guard !text.isEmpty else { return }
            let normalizedLanguage = language?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let startLine = bufferStartLine ?? 0
            blocks.append(MarkdownBlock(
                id: "\(kind.rawValue):\(normalizedLanguage ?? "plain"):\(startLine)",
                kind: kind,
                text: text,
                language: language
            ))
        }

        for (lineNumber, line) in source.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if isInFence {
                    flush(as: .code, language: fenceLanguage)
                    fenceLanguage = nil
                    isInFence = false
                } else {
                    flush(as: .prose, language: nil)
                    fenceLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    isInFence = true
                }
                continue
            }
            if buffer.isEmpty {
                bufferStartLine = lineNumber
            }
            buffer.append(line)
        }

        // An unterminated fence still streams in as code.
        flush(as: isInFence ? .code : .prose, language: isInFence ? fenceLanguage : nil)
        return blocks
    }
}
