import Foundation

struct DesktopAsyncQuestion: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let options: [String]

    static func parseAgentMessage(_ item: [String: Any]) -> [Self] {
        guard item["type"] as? String == "agentMessage",
              item["delivery"] as? String == "async",
              let questions = item["questions"] as? [[String: Any]] else { return [] }
        return questions.enumerated().compactMap { index, question in
            guard let title = question["title"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Self(id: String(index), title: title, options: question["options"] as? [String] ?? [])
        }
    }
}

struct DesktopAsyncQuestionRequest: Codable, Equatable, Identifiable {
    let threadID: String
    let itemID: String
    var questions: [DesktopAsyncQuestion]
    var answers: [String: String] = [:]
    var resolution: String?
    var id: String { threadID + "\u{1f}" + itemID }
    var answerClientID: String { "async-answer-" + Data(id.utf8).base64EncodedString() }

    func answer(for question: DesktopAsyncQuestion) -> String {
        answers[question.id] ?? question.options.first ?? ""
    }

    var answerMessage: String? {
        guard !questions.isEmpty else { return nil }
        let replies = questions.map { answer(for: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard replies.allSatisfy({ !$0.isEmpty }) else { return nil }
        return zip(questions, replies).map { "\($0.title)\n\($1)" }.joined(separator: "\n\n")
    }
}
