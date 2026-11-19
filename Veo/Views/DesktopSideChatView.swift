import SwiftUI

struct DesktopSideChatView: View {
    @Bindable var store: DesktopCodexStore
    @State private var question = ""
    @FocusState private var isQuestionFocused: Bool

    var body: some View {
        if store.selectedThreadID == nil {
            ContentUnavailableView("Open a chat first", systemImage: "bubble.left.and.bubble.right")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if store.selectedSideChat?.exchanges.isEmpty != false {
                            Text("Ask a question about this chat.").foregroundStyle(.secondary)
                        }
                        ForEach(store.selectedSideChat?.exchanges ?? []) { exchange in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(exchange.question).fontWeight(.semibold).textSelection(.enabled)
                                if let answer = exchange.answer {
                                    MarkdownMessageView(source: answer, workspaceURL: store.effectiveWorkspaceURL)
                                    Button("Add to main chat") {
                                        store.appendContextToDraft("Side question: \(exchange.question)\n\n\(answer)")
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if store.selectedSideChat?.isRunning == true {
                            ProgressView("Working…").controlSize(.small)
                        }
                        if let error = store.selectedSideChat?.error {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                    .padding(12)
                }
                Divider()
                HStack(alignment: .bottom) {
                    TextField("Ask a side question", text: $question, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($isQuestionFocused)
                    Button("Ask", action: submit)
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.selectedSideChat?.isRunning == true)
                }
                .padding([.horizontal, .bottom], 12)
            }
            .onAppear { isQuestionFocused = true }
            .onChange(of: store.selectedThreadID) { _, _ in question = "" }
        }
    }

    private func submit() {
        if store.askSideQuestion(question) { question = "" }
    }
}
