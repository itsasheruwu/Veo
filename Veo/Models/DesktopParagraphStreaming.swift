// Purpose: Finds complete Markdown paragraphs without revealing unfinished fenced code.

import Foundation

enum DesktopParagraphStreaming {
    static func completedPrefix(in source: String) -> String {
        var lineStart = source.startIndex
        var visibleEnd = source.startIndex
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

        for index in source.indices where source[index].isNewline {
            let nextLine = source.index(after: index)
            processLine(endingAt: index, nextLine: nextLine, terminated: true)
            lineStart = nextLine
        }
        // Wait for a newline before accepting a closing fence: a later delta can
        // still append code to that line. Completion always flushes the full source.
        return String(source[..<visibleEnd])
    }
}
