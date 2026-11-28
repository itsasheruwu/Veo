// Purpose: Finds complete Markdown paragraphs without revealing unfinished fenced code.

import Foundation

enum DesktopParagraphStreaming {
    static func completedPrefix(in source: String, appendingAfter previouslyVisible: String = "") -> String {
        var lineStart = source.startIndex
        // A completed paragraph ends outside a fence. Only its unfinished tail needs parsing.
        // Callers supply this prefix only for a confirmed append. A split CR/LF can move its boundary.
        if !previouslyVisible.isEmpty {
            let boundary = source.utf8.index(source.utf8.startIndex, offsetBy: previouslyVisible.utf8.count)
            if let index = boundary.samePosition(in: source) { lineStart = index }
        }
        let scanStart = lineStart
        var visibleEnd = lineStart
        var fence: (marker: Character, length: Int)?

        func processLine(endingAt end: String.Index, nextLine: String.Index, terminated: Bool) {
            let line = source[lineStart..<end].trimmingCharacters(in: .whitespaces)
            if let marker = line.first, marker == "`" || marker == "~" {
                let length = line.prefix(while: { $0 == marker }).count
                if let openFence = fence {
                    if terminated, marker == openFence.marker, length >= openFence.length,
                       line.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty {
                        fence = nil
                        visibleEnd = nextLine
                    }
                } else if length >= 3, terminated {
                    // The fence starts a new block, completing any preceding prose.
                    visibleEnd = lineStart
                    fence = (marker, length)
                }
            } else if line.isEmpty, terminated, fence == nil {
                visibleEnd = nextLine
            }
        }

        for index in source[scanStart...].indices where source[index].isNewline {
            let nextLine = source.index(after: index)
            processLine(endingAt: index, nextLine: nextLine, terminated: true)
            lineStart = nextLine
        }
        // Wait for a newline before accepting a closing fence: a later delta can
        // still append code to that line. Completion always flushes the full source.
        if visibleEnd == scanStart && scanStart != source.startIndex { return previouslyVisible }
        return String(source[..<visibleEnd])
    }
}
