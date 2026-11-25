import Foundation

actor DesktopRobloxDevSkill {
    static let shared = DesktopRobloxDevSkill()
    private static let repository = "https://github.com/MSayib/roblox-dev-skill.git"
    private var nextRefresh = Date.distantPast

    func resolve() throws -> URL {
        let files = FileManager.default
        let directory = try files.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("com.ash.Veo/RobloxDevSkill", isDirectory: true)
        let current = directory.appendingPathComponent("current")
        let previous = cachedSkill(at: current, in: directory)
        if nextRefresh > Date() {
            if let previous { return previous }
            throw unavailable
        }
        nextRefresh = Date().addingTimeInterval(15 * 60)
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let staging = directory.appendingPathComponent("staging-" + UUID().uuidString, isDirectory: true)
            defer { try? files.removeItem(at: staging) }
            _ = try git(["clone", "--quiet", "--depth=1", "--no-tags", Self.repository, staging.path], in: directory)
            let revision = try git(["rev-parse", "HEAD"], in: staging)
            guard validRevision(revision), usable(staging.appendingPathComponent("SKILL.md")) else { throw unavailable }
            let checkout = directory.appendingPathComponent(revision, isDirectory: true)
            let skill = checkout.appendingPathComponent("SKILL.md")
            if !files.fileExists(atPath: checkout.path) {
                try files.moveItem(at: staging, to: checkout)
            }
            guard usable(skill) else { throw unavailable }
            try revision.write(to: current, atomically: true, encoding: .utf8)
            return skill
        } catch {
            if let previous { return previous }
            // A first-use failure can be retried after the connection is restored.
            nextRefresh = .distantPast
            throw unavailable
        }
    }

    private func validRevision(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func cachedSkill(at file: URL, in directory: URL) -> URL? {
        guard let revision = try? String(contentsOf: file, encoding: .utf8), validRevision(revision) else { return nil }
        let skill = directory.appendingPathComponent(revision).appendingPathComponent("SKILL.md")
        return usable(skill) ? skill : nil
    }

    private func usable(_ skill: URL) -> Bool {
        guard let text = try? String(contentsOf: skill, encoding: .utf8) else { return false }
        return text.hasPrefix("---\n") && text.contains("\nname: roblox-dev-skill\n")
            && FileManager.default.fileExists(atPath: skill.deletingLastPathComponent().appendingPathComponent("references").path)
    }

    private var unavailable: CodexAppServerClientError {
        .invalidInput("The Roblox Dev Skill is unavailable. Check your GitHub connection and try Roblox mode again.")
    }

    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        let completed = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "core.symlinks=false",
                             "-c", "credential.helper=", "-c", "http.lowSpeedLimit=1000",
                             "-c", "http.lowSpeedTime=10"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        guard completed.wait(timeout: .now() + 20) == .success else {
            if process.isRunning { process.terminate() }
            throw unavailable
        }
        guard process.terminationStatus == 0 else { throw unavailable }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
