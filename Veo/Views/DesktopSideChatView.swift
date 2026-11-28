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
                            Label("Ask a question about this chat.", systemImage: "bubble.left.and.bubble.right")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                HStack(alignment: .bottom) {
                    TextField("Ask a side question", text: $question, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused($isQuestionFocused)
                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 25, height: 25)
                            .background(.primary.opacity(0.09), in: Circle())
                    }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ask side question")
                        .help("Ask side question")
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.selectedSideChat?.isRunning == true)
                }
                .padding(8)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.09)).allowsHitTesting(false) }
                .padding([.horizontal, .bottom], 10)
            }
            .onAppear { isQuestionFocused = true }
            .onChange(of: store.selectedThreadID) { _, _ in question = "" }
        }
    }

    private func submit() {
        if store.askSideQuestion(question) { question = "" }
    }
}
