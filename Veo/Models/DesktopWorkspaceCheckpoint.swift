import Foundation
import Observation

struct DesktopWorkspaceCheckpoint: Codable, Identifiable, Sendable {
    var id: String
    var threadID: String
    var payloadID: String
    var turnID: String?
    var workspacePath: String
    var repositoryPath: String
    var head: String
    var branch: String?
    var filesRef: String
    var indexRef: String
    var createdAt: Date
}

@MainActor @Observable
final class DesktopCheckpointLibrary {
    static let shared = DesktopCheckpointLibrary()
    private(set) var checkpoints: [DesktopWorkspaceCheckpoint]
    private let defaults: UserDefaults
    private let key = "VeoDesktop.workspaceCheckpoints"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        checkpoints = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([DesktopWorkspaceCheckpoint].self, from: $0) } ?? []
    }
    func save(_ checkpoint: DesktopWorkspaceCheckpoint) {
        checkpoints.removeAll { $0.id == checkpoint.id }
        checkpoints.append(checkpoint)
        if let data = try? JSONEncoder().encode(checkpoints) { defaults.set(data, forKey: key) }
    }
    func checkpoint(threadID: String, item: DesktopTimelineItem) -> DesktopWorkspaceCheckpoint? {
        checkpoints.last { $0.threadID == threadID && ($0.payloadID == item.clientID || $0.turnID != nil && $0.turnID == item.turnID) }
    }
}
