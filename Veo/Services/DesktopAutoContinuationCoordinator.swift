import AppKit
import Foundation
import ServiceManagement

@MainActor
final class DesktopAutoContinuationCoordinator: ObservableObject {
    static let launchAgentPlistName = "com.ash.Veo.AutoContinue.plist"

    @Published private(set) var jobs: [DesktopAutoContinuationJob] = []
    @Published private(set) var helperStatus: SMAppService.Status = .notRegistered
    @Published private(set) var helperMessage: String?

    private let defaults: UserDefaults
    private let fileURL: URL
    private var timer: Timer?
    var dueHandler: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ash.Veo", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("auto-continuations.json")
        load()
        refreshHelperRegistration()
        scheduleTimer()
    }

    var wakePolicy: DesktopAutoContinuationWakePolicy {
        DesktopAutoContinuationWakePolicy(
            rawValue: defaults.string(forKey: DesktopAutoContinuationPreferences.wakePolicyKey) ?? ""
        ) ?? .nextLaunch
    }

    var hasPendingJobs: Bool {
        jobs.contains { $0.isEnabled && $0.status == .waiting }
    }

    func job(for threadID: String) -> DesktopAutoContinuationJob? {
        jobs.last { $0.uiThreadID == threadID && $0.status != .completed }
    }

    func upsert(_ job: DesktopAutoContinuationJob) {
        jobs.removeAll { $0.uiThreadID == job.uiThreadID && $0.status != .completed }
        jobs.append(job)
        saveAndReschedule()
    }

    func update(_ id: String, _ mutate: (inout DesktopAutoContinuationJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
        saveAndReschedule()
    }

    func cancel(threadID: String, detail: String? = nil) {
        guard let index = jobs.lastIndex(where: { $0.uiThreadID == threadID && $0.status != .completed }) else { return }
        jobs[index].isEnabled = false
        jobs[index].status = .completed
        jobs[index].detail = detail
        saveAndReschedule()
    }

    func remove(threadID: String) {
        jobs.removeAll { $0.uiThreadID == threadID }
        saveAndReschedule()
    }

    func dueJobs(at date: Date = Date()) -> [DesktopAutoContinuationJob] {
        jobs.filter {
            $0.isEnabled && $0.status == .waiting && ($0.dispatchAt.map { $0 <= date } ?? false)
        }
    }

    func preferenceDidChange() {
        refreshHelperRegistration()
        scheduleTimer()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([DesktopAutoContinuationJob].self, from: data) else { return }
        jobs = decoded.map { job in
            guard job.status == .dispatching, job.continuationTurnID == nil else { return job }
            var recovered = job
            recovered.status = .waiting
            recovered.detail = "Recovered after Veo restarted."
            return recovered
        }
    }

    private func saveAndReschedule() {
        if let data = try? JSONEncoder().encode(jobs) {
            try? data.write(to: fileURL, options: .atomic)
        }
        refreshHelperRegistration()
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard let next = jobs.compactMap({ job -> Date? in
            guard job.isEnabled, job.status == .waiting else { return nil }
            return job.dispatchAt
        }).min() else { return }
        if next <= Date() {
            Task { @MainActor [weak self] in self?.dueHandler?() }
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow), repeats: false) {
            [weak self] _ in
            Task { @MainActor in self?.dueHandler?() }
        }
    }

    private func refreshHelperRegistration() {
        let service = SMAppService.agent(plistName: Self.launchAgentPlistName)
        let shouldRegister = wakePolicy == .wakeQuietly && hasPendingJobs
        do {
            if shouldRegister, service.status == .notRegistered {
                try service.register()
            } else if !shouldRegister, service.status != .notRegistered {
                try service.unregister()
            }
            helperMessage = nil
        } catch {
            helperMessage = "Quiet wake needs approval in System Settings. Pending work will resume next time Veo opens."
        }
        helperStatus = service.status
        if shouldRegister, helperStatus == .requiresApproval {
            helperMessage = "Quiet wake needs approval in System Settings. Pending work will resume next time Veo opens."
        }
    }
}
