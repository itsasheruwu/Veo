import SwiftUI

/// Sits above the ordinary composer: asking a question never stops the agent
/// or takes away the user's ability to write an unrelated follow-up.
struct DesktopAsyncQuestionsView: View {
    @Bindable var store: DesktopCodexStore
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(store.selectedAsyncQuestions) { request in
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(request.questions) { question in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(question.title).font(.callout.weight(.medium))
                                        .fixedSize(horizontal: false, vertical: true)
                                    if !question.options.isEmpty {
                                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                                            Button {
                                                store.asyncQuestions.answer(option, questionID: question.id, requestID: request.id)
                                            } label: {
                                                HStack(alignment: .top) {
                                                    Image(systemName: request.answer(for: question) == option ? "largecircle.fill.circle" : "circle")
                                                    Text(option).multilineTextAlignment(.leading)
                                                    Spacer(minLength: 0)
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel(option)
                                            .accessibilityValue(request.answer(for: question) == option ? "Selected" : "Not selected")
                                        }
                                    }
                                    TextField(question.options.isEmpty ? "Your answer" : "Or write your own answer", text: Binding(
                                        get: { request.answers[question.id] ?? "" },
                                        set: { store.asyncQuestions.answer($0, questionID: question.id, requestID: request.id) }
                                    ), axis: .vertical)
                                    .lineLimit(1...4)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("Answer to \(question.title)")
                                }
                            }
                            HStack {
                                Button("Dismiss") { store.asyncQuestions.resolve(request.id, as: "dismissed") }
                                    .help("Close this question without sending a message")
                                Spacer()
                                Button("Send answers") { store.submitAsyncAnswers(request) }
                                    .disabled(request.answerMessage == nil || !store.canAnswerAsyncQuestions)
                            }
                        }
                        if request.id != store.selectedAsyncQuestions.last?.id { Divider() }
                    }
                }.padding(.top, 8)
            }.frame(maxHeight: 260)
        } label: {
            Label("Questions from Codex (\(store.selectedAsyncQuestions.count))", systemImage: "questionmark.bubble")
                .font(.callout.weight(.medium))
        }
        .padding(12)
        .accessibilityElement(children: .contain)
    }
}
