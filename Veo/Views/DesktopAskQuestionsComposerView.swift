// FILE: DesktopAskQuestionsComposerView.swift
// Purpose: Replaces the normal composer controls while the selected chat is waiting for structured user input.
// Layer: Desktop app UI
// Depends on: DesktopCodexStore, DesktopCodexModels, SwiftUI

import SwiftUI

struct DesktopAskQuestionsComposerDraft {
    var currentIndex = 0
    var selections: [String: String] = [:]
    var customAnswers: [String: String] = [:]
    var notes: [String: String] = [:]
    var skippedQuestionIDs = Set<String>()
}

struct DesktopAskQuestionsComposerView: View {
    private enum FocusTarget: Hashable {
        case option(String)
        case custom(String)
        case note(String)
    }

    private static let otherSelection = "__veo_other__"

    @Environment(\.veoAccent) private var veoAccent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let request: DesktopPendingRequest
    @ObservedObject var store: DesktopCodexStore
    @Binding var draft: DesktopAskQuestionsComposerDraft

    @State private var hoveredOptionID: String?
    @FocusState private var focusedControl: FocusTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let question = currentQuestion {
                questionHeader(question)

                Text(question.prompt)
                    .font(.system(size: 14.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                questionControls(question)

                if let error = store.pendingRequestError(for: request), !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Answer could not be submitted. \(error)")
                }

                footer(question)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.bubble")
                    Text("Codex requested input without any questions.")
                    Spacer(minLength: 12)
                    Button("Skip") { store.skipPendingUserInput(request) }
                        .buttonStyle(.borderedProminent)
                }
                .font(.system(size: 12.5, weight: .medium))
            }
        }
        .padding(DesktopTheme.spaceM)
        .tint(veoAccent)
        .onChange(of: focusedControl) { _, target in
            if target != nil { registerInteraction() }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: draft.currentIndex)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: draft.selections)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Questions from Codex")
    }

    private var currentQuestion: DesktopRequestQuestion? {
        guard request.questions.indices.contains(draft.currentIndex) else { return nil }
        return request.questions[draft.currentIndex]
    }

    private func questionHeader(_ question: DesktopRequestQuestion) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(veoAccent)
            Text(question.header)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(veoAccent)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text("Question \(draft.currentIndex + 1) of \(request.questions.count)")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func questionControls(_ question: DesktopRequestQuestion) -> some View {
        if !question.options.isEmpty {
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(question.options) { option in
                        optionButton(
                            question: question,
                            id: option.id.uuidString,
                            selection: option.label,
                            title: option.label,
                            detail: option.description
                        )
                    }

                    if question.allowsOther {
                        optionButton(
                            question: question,
                            id: "\(question.id)-other",
                            selection: Self.otherSelection,
                            title: "Other",
                            detail: ""
                        )
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 238)
        }

        if question.options.isEmpty || draft.selections[question.id] == Self.otherSelection {
            answerField(question)
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else if let selection = draft.selections[question.id], selection != Self.otherSelection {
            notesField(question)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func optionButton(
        question: DesktopRequestQuestion,
        id: String,
        selection: String,
        title: String,
        detail: String
    ) -> some View {
        let isSelected = draft.selections[question.id] == selection
        let focus = FocusTarget.option(id)
        return Button {
            registerInteraction()
            draft.skippedQuestionIDs.remove(question.id)
            draft.selections[question.id] = selection
            if selection == Self.otherSelection {
                DispatchQueue.main.async { focusedControl = .custom(question.id) }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? veoAccent : .secondary)
                    .frame(width: 16, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        }
        .buttonStyle(
            AskQuestionOptionButtonStyle(
                accent: veoAccent,
                isSelected: isSelected,
                isHovered: hoveredOptionID == id,
                isFocused: focusedControl == focus
            )
        )
        .focused($focusedControl, equals: focus)
        .focusEffectDisabled()
        .onHover { hovering in hoveredOptionID = hovering ? id : nil }
        .accessibilityLabel(detail.isEmpty ? title : "\(title). \(detail)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    @ViewBuilder
    private func answerField(_ question: DesktopRequestQuestion) -> some View {
        let placeholder = question.options.isEmpty ? "Type your answer…" : "Describe your answer…"
        if question.isSecret {
            SecureField(placeholder, text: answerBinding(for: question))
                .focused($focusedControl, equals: .custom(question.id))
                .accessibilityLabel(question.options.isEmpty ? "Answer" : "Other answer")
                .modifier(AskQuestionFieldChrome())
        } else {
            TextField(placeholder, text: answerBinding(for: question), axis: .vertical)
                .lineLimit(1...4)
                .focused($focusedControl, equals: .custom(question.id))
                .accessibilityLabel(question.options.isEmpty ? "Answer" : "Other answer")
                .modifier(AskQuestionFieldChrome())
        }
    }

    @ViewBuilder
    private func notesField(_ question: DesktopRequestQuestion) -> some View {
        if question.isSecret {
            SecureField("Add optional details…", text: notesBinding(for: question))
                .focused($focusedControl, equals: .note(question.id))
                .accessibilityLabel("Optional details")
                .modifier(AskQuestionFieldChrome())
        } else {
            TextField("Add optional details…", text: notesBinding(for: question), axis: .vertical)
                .lineLimit(1...3)
                .focused($focusedControl, equals: .note(question.id))
                .accessibilityLabel("Optional details")
                .modifier(AskQuestionFieldChrome())
        }
    }

    private func footer(_ question: DesktopRequestQuestion) -> some View {
        HStack(spacing: 9) {
            if draft.currentIndex > 0 {
                Button("Back") {
                    registerInteraction()
                    withQuestionAnimation { draft.currentIndex -= 1 }
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Returns to the previous question without losing this answer")
            }

            Button("Skip") { skipCurrentQuestion(question) }
                .buttonStyle(.borderless)
                .accessibilityHint("Records no answer for this question")

            Spacer(minLength: 8)

            countdownLabel

            if store.isRunningTurn {
                Button {
                    store.stopTurn()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop turn (⌘.)")
            }

            Button(isLastQuestion ? submitTitle : "Next") {
                advanceOrSubmit()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canAdvance(question))
            .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 11.5, weight: .medium))
    }

    @ViewBuilder
    private var countdownLabel: some View {
        if let deadline = store.pendingUserInputCountdownDeadline(for: request) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(ceil(deadline.timeIntervalSince(context.date))))
                Label("Auto-skips in \(seconds)s", systemImage: "timer")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Automatically skips in \(seconds) seconds")
            }
        }
    }

    private var isLastQuestion: Bool {
        draft.currentIndex == request.questions.count - 1
    }

    private var submitTitle: String {
        request.questions.count == 1 ? "Submit answer" : "Submit answers"
    }

    private func canAdvance(_ question: DesktopRequestQuestion) -> Bool {
        if draft.skippedQuestionIDs.contains(question.id) { return true }
        if question.options.isEmpty || draft.selections[question.id] == Self.otherSelection {
            return !(draft.customAnswers[question.id] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        return draft.selections[question.id] != nil
    }

    private func answerBinding(for question: DesktopRequestQuestion) -> Binding<String> {
        Binding(
            get: { draft.customAnswers[question.id, default: ""] },
            set: { value in
                registerInteraction()
                draft.skippedQuestionIDs.remove(question.id)
                draft.customAnswers[question.id] = value
            }
        )
    }

    private func notesBinding(for question: DesktopRequestQuestion) -> Binding<String> {
        Binding(
            get: { draft.notes[question.id, default: ""] },
            set: { value in
                registerInteraction()
                draft.notes[question.id] = value
            }
        )
    }

    private func skipCurrentQuestion(_ question: DesktopRequestQuestion) {
        registerInteraction()
        draft.skippedQuestionIDs.insert(question.id)
        draft.selections.removeValue(forKey: question.id)
        draft.customAnswers.removeValue(forKey: question.id)
        draft.notes.removeValue(forKey: question.id)
        advanceOrSubmit()
    }

    private func advanceOrSubmit() {
        registerInteraction()
        if isLastQuestion {
            store.submitPendingAnswers(for: request, answers: collectedAnswers())
        } else {
            focusedControl = nil
            withQuestionAnimation { draft.currentIndex += 1 }
        }
    }

    private func collectedAnswers() -> [String: [String]] {
        request.questions.reduce(into: [String: [String]]()) { result, question in
            if draft.skippedQuestionIDs.contains(question.id) {
                result[question.id] = []
                return
            }
            if question.options.isEmpty || draft.selections[question.id] == Self.otherSelection {
                let value = draft.customAnswers[question.id, default: ""]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result[question.id] = value.isEmpty ? [] : [value]
                return
            }
            guard let selection = draft.selections[question.id] else {
                result[question.id] = []
                return
            }
            var values = [selection]
            let note = draft.notes[question.id, default: ""]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { values.append("user_note: \(note)") }
            result[question.id] = values
        }
    }

    private func registerInteraction() {
        store.keepPendingUserInputOpen(request)
    }

    private func withQuestionAnimation(_ changes: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16), changes)
    }
}

private struct AskQuestionOptionButtonStyle: ButtonStyle {
    let accent: Color
    let isSelected: Bool
    let isHovered: Bool
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? accent.opacity(configuration.isPressed ? 0.20 : 0.13)
                    : Color.primary.opacity(configuration.isPressed ? 0.09 : (isHovered ? 0.055 : 0.032)),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isFocused ? accent.opacity(0.62) : (isSelected ? accent.opacity(0.34) : Color.primary.opacity(0.07)),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            }
            .scaleEffect(configuration.isPressed ? 0.995 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct AskQuestionFieldChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}
