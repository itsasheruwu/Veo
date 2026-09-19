import Foundation

struct DesktopPullRequest: Decodable, Identifiable, Sendable {
    struct Author: Decodable, Sendable { var login: String }
    struct Comment: Decodable, Sendable { var body: String; var author: Author?; var url: String? }
    struct Check: Decodable, Sendable {
        var name: String?
        var context: String?
        var status: String?
        var conclusion: String?
        var state: String?
    }
    var number: Int
    var title: String
    var url: String
    var state: String
    var isDraft: Bool
    var headRefName: String
    var baseRefName: String
    var body: String
    var comments: [Comment]
    var statusCheckRollup: [Check]?
    var reviewDecision: String?
    var id: String { url }
}

/// Uses the user's local GitHub CLI login. Arguments are never evaluated by a shell.
actor DesktopGitHubService {
    private static let fields = "number,title,url,state,isDraft,headRefName,baseRefName,body,comments,statusCheckRollup,reviewDecision"
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func set(_ data: Data) { lock.lock(); bytes = data; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    func read(_ reference: String?, in directory: URL) throws -> DesktopPullRequest {
        var arguments = ["pr", "view"]
        if let reference {
            guard Self.validReference(reference) else { throw Failure(message: "Enter a GitHub pull-request URL or number.") }
            arguments.append(reference)
        }
        arguments += ["--json", Self.fields]
        return try JSONDecoder().decode(DesktopPullRequest.self, from: run("gh", arguments, in: directory))
    }

    func create(title: String, body: String, base: String, branch: String, head: String, in directory: URL) throws -> DesktopPullRequest {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !base.isEmpty, !base.hasPrefix("-"), !branch.isEmpty, branch != base else { throw Failure(message: "Enter a title and a base branch different from the current branch.") }
        let currentBranch = try text(run("git", ["symbolic-ref", "--short", "HEAD"], in: directory))
        let currentHead = try text(run("git", ["rev-parse", "HEAD"], in: directory))
        guard currentBranch == branch, currentHead == head else { throw Failure(message: "The branch changed. Close this sheet, refresh Review, and try again.") }
        _ = try run("git", ["push", "--set-upstream", "origin", "HEAD:refs/heads/" + branch], in: directory)
        guard try text(run("git", ["rev-parse", "HEAD"], in: directory)) == head,
              try text(run("git", ["symbolic-ref", "--short", "HEAD"], in: directory)) == branch else {
            throw Failure(message: "The branch changed after the push. The push completed; refresh before creating a PR.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("veo-pr-" + UUID().uuidString + ".txt")
        try body.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let output = try text(run("gh", ["pr", "create", "--draft", "--title", title, "--body-file", file.path, "--base", base, "--head", branch], in: directory))
        guard let url = output.split(whereSeparator: \.isWhitespace).map(String.init).last(where: { Self.validReference($0) && $0.hasPrefix("https://") }) else {
            throw Failure(message: "The create command returned without a PR URL. Check GitHub before retrying.")
        }
        return try read(url, in: directory)
    }

    static func validReference(_ value: String) -> Bool {
        if !value.isEmpty, value.allSatisfy(\.isNumber) { return true }
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        let parts = url.pathComponents
        return parts.count == 5 && parts[3] == "pull" && parts[4].allSatisfy(\.isNumber)
    }

    private func text(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { throw Failure(message: "The CLI returned unreadable output.") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(_ executable: String, _ arguments: [String], in directory: URL) throws -> Data {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        let out = Output(), err = Output(), group = DispatchGroup()
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        guard let path = paths.map({ URL(fileURLWithPath: $0).appendingPathComponent(executable).path }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure(message: "Install \(executable) and sign in with gh auth login before using GitHub in Veo.")
        }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
        environment["PATH"] = paths.joined(separator: ":")
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        group.enter(); DispatchQueue.global(qos: .utility).async { out.set(stdout.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter(); DispatchQueue.global(qos: .utility).async { err.set(stderr.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        process.waitUntilExit(); group.wait()
        guard process.terminationStatus == 0 else {
            throw Failure(message: String(decoding: err.get().prefix(8_192), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out.get()
    }
}
