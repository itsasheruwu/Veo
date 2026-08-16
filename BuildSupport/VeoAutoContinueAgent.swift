import AppKit
import Foundation

private struct Job: Decodable {
    let resetAt: Date?
    let isEnabled: Bool
    let status: String
}

@main
private enum VeoAutoContinueAgent {
    static func main() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ash.Veo", isDirectory: true)
        let jobsURL = support.appendingPathComponent("auto-continuations.json")
        guard let data = try? Data(contentsOf: jobsURL),
              let jobs = try? JSONDecoder().decode([Job].self, from: data),
              jobs.contains(where: { job in
                  guard job.isEnabled, job.status == "waiting", let resetAt = job.resetAt else { return false }
                  return resetAt.addingTimeInterval(8) <= Date()
              }) else { return }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let appURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 15)
    }
}
