import SwiftUI

/// Captures the visible patch along with its path and side, so a later refresh cannot change a comment's context.
struct DesktopDiffCommentEditor: View {
    let path: String
    let side: DesktopGitDiffSide
    let hunk: DesktopGitDiffHunk
    let addToDraft: (String) -> Void
    @State private var selection = Set<String>()
    @State private var comment = ""
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(expanded ? "Cancel comment" : "Comment on lines…", systemImage: "text.bubble") {
                expanded.toggle()
            }
            .buttonStyle(.borderless).controlSize(.small)
            if expanded {
                Text("Select the lines to include").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(hunk.lines.filter { $0.kind != .metadata }) { line in
                            Toggle(isOn: Binding(get: { selection.contains(line.id) }, set: { selected in
                                if selected { selection.insert(line.id) } else { selection.remove(line.id) }
                            })) {
                                Text("\(line.newLineNumber ?? line.oldLineNumber ?? 0)  \(line.text)")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }.toggleStyle(.checkbox)
                        }
                    }
                }.frame(maxHeight: 180)
                TextField("What should Codex change?", text: $comment, axis: .vertical)
                    .lineLimit(2...6).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Adds to your draft").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add comment") {
                        let lines = hunk.lines.filter { selection.contains($0.id) }
                        let excerpt = lines.map { line in
                            "old:\(line.oldLineNumber.map(String.init) ?? "–") new:\(line.newLineNumber.map(String.init) ?? "–") \(line.text)"
                        }.joined(separator: "\n")
                        let label = "Review · " + path + (lines.first?.newLineNumber.map { ":\($0)" } ?? "")
                        let reference = DesktopInlineContext.reference(label, kind: "review", value: path, line: lines.first?.newLineNumber)
                        addToDraft("\(reference) (\(side.title.lowercased())):\n\(comment.trimmingCharacters(in: .whitespacesAndNewlines))\n\nSelected patch lines:\n" + excerpt.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n"))
                        comment = ""; selection = []; expanded = false
                    }.disabled(selection.isEmpty || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.padding(10)
    }
}
