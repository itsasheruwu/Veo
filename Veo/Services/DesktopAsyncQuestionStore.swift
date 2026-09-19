import Foundation
import Observation

/// Async messages have no outstanding JSON-RPC callback. Keep their lifecycle
/// independent of blocking tool requests, turn completion, and reconnects.
@MainActor @Observable
final class DesktopAsyncQuestionStore {
    private(set) var requests: [DesktopAsyncQuestionRequest]
    private let defaults: UserDefaults
    private let key = "VeoDesktop.asyncQuestions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        requests = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([DesktopAsyncQuestionRequest].self, from: $0) } ?? []
    }

    func ingest(threadID: String, itemID: String, questions: [DesktopAsyncQuestion]) {
        guard !questions.isEmpty else { return }
        let request = DesktopAsyncQuestionRequest(threadID: threadID, itemID: itemID, questions: questions)
        if let index = requests.firstIndex(where: { $0.id == request.id }) {
            guard requests[index].resolution == nil, requests[index].questions != questions else { return }
            requests[index].questions = questions
        } else {
            requests.append(request)
        }
        persist()
    }

    func pending(threadID: String) -> [DesktopAsyncQuestionRequest] {
        requests.filter { $0.threadID == threadID && $0.resolution == nil }
    }

    func answer(_ value: String, questionID: String, requestID: String) {
        guard let index = requests.firstIndex(where: { $0.id == requestID && $0.resolution == nil }) else { return }
        requests[index].answers[questionID] = value
        persist()
    }

    func resolve(_ id: String, as resolution: String) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].resolution = resolution
        persist()
    }

    func removeThread(_ threadID: String) {
        requests.removeAll { $0.threadID == threadID }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(requests) else { return }
        defaults.set(data, forKey: key)
    }
}
