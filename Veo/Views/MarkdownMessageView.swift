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
    @State private var blockedURLMessage: String?

    init(
        source: String,
        fontSize: CGFloat = 14,
        artifacts: [DesktopToolArtifact] = [],
        citations: [DesktopCitationEntry] = [],
        workspaceURL: URL? = nil
    ) {
        self.source = source
        self.fontSize = fontSize
        self.artifacts = artifacts
        self.citations = citations
        self.workspaceURL = workspaceURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MarkdownBlock.parse(source)) { block in
                switch block.kind {
                case .prose:
                    Text(Self.inlineAttributed(block.text))
                        .font(.system(size: fontSize))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code:
                    if block.language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid",
                       let diagram = SafeMermaidDiagram.parse(block.text) {
                        SafeMermaidPreviewView(diagram: diagram, source: block.text)
                    } else {
                        CodeBlockView(code: block.text, language: block.language)
                    }
                }
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
