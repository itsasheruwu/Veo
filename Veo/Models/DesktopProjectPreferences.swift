// Project-scoped defaults and actions, shared by Settings, worktrees, and the toolbar.
import Foundation
import Observation

struct DesktopProjectAction: Identifiable, Codable, Equatable {
    var id = UUID().uuidString
    var name: String
    var command: String
    var runOnWorktreeCreate = false
}

struct DesktopProjectConfiguration: Codable, Equatable {
    var modelID: String?
    var reasoningEffort: String?
    var usesWorktree = false
    var checkpointsEnabled: Bool?
    var actions: [DesktopProjectAction] = []
}

@MainActor @Observable
final class DesktopProjectPreferences {
    static let shared = DesktopProjectPreferences()
    private(set) var configurations: [String: DesktopProjectConfiguration]
    private(set) var worktreeProjects: [String: String]
    private var worktreeIdentities: [String: String]
    private let defaults: UserDefaults
    private let configurationKey = "VeoDesktop.projectConfigurations"
    private let worktreeKey = "VeoDesktop.worktreeProjects"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configurations = defaults.data(forKey: configurationKey)
            .flatMap { try? JSONDecoder().decode([String: DesktopProjectConfiguration].self, from: $0) } ?? [:]
        worktreeProjects = defaults.dictionary(forKey: worktreeKey) as? [String: String] ?? [:]
        worktreeIdentities = defaults.dictionary(forKey: "VeoDesktop.worktreeIdentities") as? [String: String] ?? [:]
    }

    func projectPath(for path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard let project = worktreeProjects[normalized], let identity = worktreeIdentities[normalized],
              repositoryIdentity(at: normalized) == identity,
              repositoryIdentity(at: project) == identity else { return normalized }
        return project
    }

    func configuration(for path: String) -> DesktopProjectConfiguration {
        configurations[projectPath(for: path)] ?? DesktopProjectConfiguration()
    }

    func set(_ configuration: DesktopProjectConfiguration, for path: String) {
        configurations[projectPath(for: path)] = configuration
        persist()
    }

    func resetDefaults(for path: String) {
        var configuration = configuration(for: path)
        configuration.modelID = nil
        configuration.reasoningEffort = nil
        configuration.usesWorktree = false
        configuration.checkpointsEnabled = nil
        set(configuration, for: path)
    }

    func registerWorktree(_ path: String, project: String) {
        let key = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let project = projectPath(for: project)
        guard let identity = repositoryIdentity(at: key), repositoryIdentity(at: project) == identity else { return }
        worktreeProjects[key] = project
        worktreeIdentities[key] = identity
        defaults.set(worktreeProjects, forKey: worktreeKey)
        defaults.set(worktreeIdentities, forKey: "VeoDesktop.worktreeIdentities")
    }

    /// Worktree paths can be reused. Compare their current common Git directory identity before inheriting settings.
    private func repositoryIdentity(at path: String) -> String? {
        var directory = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        while directory.path != "/" {
            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                var gitDirectory = dotGit
                if !isDirectory.boolValue {
                    guard let data = try? Data(contentsOf: dotGit), data.count < 16_384,
                          let text = String(data: data, encoding: .utf8), text.hasPrefix("gitdir: ") else { return nil }
                    let location = String(text.dropFirst(8)).trimmingCharacters(in: .newlines)
                    gitDirectory = location.hasPrefix("/") ? URL(fileURLWithPath: location) : directory.appendingPathComponent(location)
                }
                if let data = try? Data(contentsOf: gitDirectory.appendingPathComponent("commondir")), data.count < 16_384,
                   let text = String(data: data, encoding: .utf8) {
                    let location = text.trimmingCharacters(in: .newlines)
                    gitDirectory = location.hasPrefix("/") ? URL(fileURLWithPath: location) : gitDirectory.appendingPathComponent(location)
                }
                gitDirectory = gitDirectory.standardizedFileURL.resolvingSymlinksInPath()
                guard let attributes = try? fm.attributesOfItem(atPath: gitDirectory.path),
                      let inode = attributes[.systemFileNumber] as? NSNumber,
                      let device = attributes[.systemNumber] as? NSNumber else { return nil }
                return gitDirectory.path + ":" + device.stringValue + ":" + inode.stringValue
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configurations) else { return }
        defaults.set(data, forKey: configurationKey)
    }
}
