// FILE: DesktopUpdateService.swift
// Purpose: Checks GitHub releases for newer Veo builds and installs them in place.
// Layer: Desktop app service
// Depends on: AppKit, Foundation

import AppKit
import Foundation

struct DesktopUpdateRelease: Equatable {
    let version: String
    let tag: String
    let title: String
    let notes: String
    let pageURL: URL
    let downloadURL: URL?
    let publishedAt: Date?
}

enum DesktopUpdatePhase: Equatable {
    case idle
    case checking
    case upToDate
    case available(DesktopUpdateRelease)
    case downloading(Double)
    case installing
    case readyToRelaunch(DesktopUpdateRelease)
    case failed(String)
}

@MainActor
final class DesktopUpdateService: ObservableObject {
    @Published private(set) var phase: DesktopUpdatePhase = .idle
    @Published private(set) var lastCheck: Date?
    @Published var automaticChecks: Bool {
        didSet {
            defaults.set(automaticChecks, forKey: DesktopUpdatePreferences.automaticChecksKey)
            if automaticChecks { scheduleAutomaticChecks() } else { timer?.invalidate(); timer = nil }
        }
    }
    @Published var automaticInstall: Bool {
        didSet { defaults.set(automaticInstall, forKey: DesktopUpdatePreferences.automaticInstallKey) }
    }

    let currentVersion: String
    private let defaults: UserDefaults
    private let feedURL: URL
    private let session: URLSession
    private var timer: Timer?
    private var activeTask: Task<Void, Never>?
    private var relaunchURL = Bundle.main.bundleURL
    private var installingRelease: DesktopUpdateRelease?

    /// True when Veo can write the running bundle or `/Applications`.
    var canInstallUpdates: Bool {
        Self.isWritableInstallLocation(Self.preferredInstallURL())
    }

    init(
        defaults: UserDefaults = .standard,
        feedURL: URL = URL(string: "https://api.github.com/repos/itsasheruwu/Veo/releases/latest")!,
        session: URLSession? = nil
    ) {
        DesktopUpdatePreferences.registerDefaults(defaults)
        self.defaults = defaults
        self.feedURL = feedURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 30 * 60
            self.session = URLSession(configuration: configuration)
        }
        self.currentVersion = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        self.automaticChecks = defaults.bool(forKey: DesktopUpdatePreferences.automaticChecksKey)
        self.automaticInstall = defaults.bool(forKey: DesktopUpdatePreferences.automaticInstallKey)
        self.lastCheck = defaults.object(forKey: DesktopUpdatePreferences.lastCheckKey) as? Date
        if automaticChecks {
            scheduleAutomaticChecks()
            checkForUpdates(userInitiated: false)
        }
    }

    var availableRelease: DesktopUpdateRelease? {
        switch phase {
        case let .available(release), let .readyToRelaunch(release): return release
        default: return installingRelease
        }
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    func checkForUpdates(userInitiated: Bool) {
        guard activeTask == nil else { return }
        switch phase {
        case .downloading, .installing: return
        default: break
        }
        phase = .checking
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.activeTask = nil }
            do {
                let release = try await self.fetchLatestRelease()
                self.lastCheck = Date()
                self.defaults.set(self.lastCheck, forKey: DesktopUpdatePreferences.lastCheckKey)
                guard let release,
                      Self.isVersion(release.version, newerThan: self.currentVersion) else {
                    self.phase = .upToDate
                    return
                }
                let skipped = self.defaults.string(forKey: DesktopUpdatePreferences.skippedVersionKey)
                if !userInitiated, skipped == release.version {
                    self.phase = .upToDate
                    return
                }
                self.phase = .available(release)
                if self.automaticInstall, self.canInstallUpdates, release.downloadURL != nil {
                    self.installUpdate(release)
                }
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func skipAvailableVersion() {
        guard let release = availableRelease else { return }
        defaults.set(release.version, forKey: DesktopUpdatePreferences.skippedVersionKey)
        phase = .upToDate
    }

    func installUpdate(_ release: DesktopUpdateRelease) {
        guard activeTask == nil else { return }
        guard let downloadURL = release.downloadURL else {
            phase = .failed("This release does not include a downloadable Veo disk image.")
            return
        }
        let installURL = Self.preferredInstallURL()
        guard Self.isWritableInstallLocation(installURL) else {
            phase = .failed("Veo needs write access to Applications to install this update.")
            return
        }

        installingRelease = release
        phase = .downloading(0)
        let userAgent = "Veo/\(currentVersion)"
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.activeTask = nil }
            do {
                let archiveURL = try await self.download(from: downloadURL, userAgent: userAgent)
                defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
                self.phase = .installing
                let installedURL = try await Task.detached(priority: .userInitiated) {
                    try Self.replaceRunningBundle(withDiskImageAt: archiveURL, installingAt: installURL)
                }.value
                self.relaunchURL = installedURL
                self.installingRelease = nil
                self.phase = .readyToRelaunch(release)
            } catch is CancellationError {
                self.installingRelease = nil
                self.phase = .available(release)
            } catch {
                self.installingRelease = nil
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func relaunch() {
        let bundleURL = relaunchURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Networking

    private func fetchLatestRelease() async throws -> DesktopUpdateRelease? {
        var request = URLRequest(url: feedURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Veo/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "VeoUpdates",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "GitHub returned HTTP \(http.statusCode)."]
            )
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool != true,
              let tag = object["tag_name"] as? String,
              let pageString = object["html_url"] as? String,
              let pageURL = URL(string: pageString) else { return nil }

        let assets = object["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true })
        let downloadURL = (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:))
        let published = (object["published_at"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }

        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DesktopUpdateRelease(
            version: Self.normalizedVersion(tag),
            tag: tag,
            title: (name?.isEmpty == false) ? (name ?? tag) : tag,
            notes: (object["body"] as? String) ?? "",
            pageURL: pageURL,
            downloadURL: downloadURL,
            publishedAt: published
        )
    }

    private func download(from url: URL, userAgent: String) async throws -> URL {
        let stagingURL = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.homeDirectoryForCurrentUser,
            create: true
        )
        let destination = stagingURL.appendingPathComponent("Veo-update.dmg")
        let onProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(fraction)
            }
        }
        try await Task.detached(priority: .userInitiated) {
            try await Self.downloadDiskImage(
                from: url,
                userAgent: userAgent,
                destination: destination,
                onProgress: onProgress
            )
        }.value
        return destination
    }

    nonisolated private static func downloadDiskImage(
        from url: URL,
        userAgent: String,
        destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 300

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = UpdateDownloadDelegate(
                destination: destination,
                onProgress: onProgress,
                continuation: continuation
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 30 * 60
            let queue = OperationQueue()
            queue.name = "com.ash.Veo.update-download"
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
            delegate.session = session
            session.downloadTask(with: request).resume()
        }
    }

    // MARK: - Install

    nonisolated private static func preferredInstallURL() -> URL {
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        if current.pathExtension == "app", isWritableInstallLocation(current) {
            // A read-only disk image is not a lasting install location.
            let parentPath = parent.path
            if !parentPath.hasPrefix("/Volumes/") {
                return current
            }
        }
        return URL(fileURLWithPath: "/Applications/Veo.app")
    }

    nonisolated private static func isWritableInstallLocation(_ bundleURL: URL) -> Bool {
        let parent = bundleURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: bundleURL.path) {
            return FileManager.default.isWritableFile(atPath: parent.path)
        }
        return FileManager.default.isWritableFile(atPath: parent.path)
    }

    @discardableResult
    nonisolated private static func replaceRunningBundle(
        withDiskImageAt imageURL: URL,
        installingAt bundleURL: URL
    ) throws -> URL {
        let mountPoint = try run(
            "/usr/bin/hdiutil",
            ["attach", imageURL.path, "-nobrowse", "-readonly", "-mountrandom", "/tmp"]
        )
        .split(separator: "\n")
        .compactMap { line -> String? in
            let fields = line.components(separatedBy: "\t").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            return fields.last.flatMap { $0.hasPrefix("/") ? $0 : nil }
        }
        .last

        guard let mountPoint else {
            throw NSError(
                domain: "VeoUpdates",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "The downloaded disk image could not be mounted."]
            )
        }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"]) }

        let contents = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw NSError(
                domain: "VeoUpdates",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "The update image does not contain a Veo app."]
            )
        }
        let sourceURL = URL(fileURLWithPath: mountPoint).appendingPathComponent(appName)

        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", sourceURL.path])

        let stagedURL = bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(".Veo-update-\(UUID().uuidString.prefix(8)).app")
        _ = try run("/usr/bin/ditto", [sourceURL.path, stagedURL.path])
        do {
            try swapInPlace(stagedURL: stagedURL, bundleURL: bundleURL)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }
        return bundleURL
    }

    /// Installs the staged bundle by renaming rather than `replaceItemAt`.
    ///
    /// A bundle installed from the PKG is owned by `root:wheel`, and
    /// `replaceItemAt` fails against it with POSIX 13 even though `/Applications`
    /// itself is group-writable by admins. Directory-level renames only need write
    /// permission on the enclosing folder, so they succeed where replacing the item
    /// in place does not. The previous bundle is moved aside first so a failure can
    /// still restore it, and is only deleted once the new bundle is in position.
    nonisolated private static func swapInPlace(stagedURL: URL, bundleURL: URL) throws {
        let manager = FileManager.default
        var parkedURL = bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(".Veo-previous.app")
        try? manager.removeItem(at: parkedURL)
        if manager.fileExists(atPath: parkedURL.path) {
            parkedURL = bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(".Veo-previous-\(UUID().uuidString.prefix(8)).app")
        }

        if manager.fileExists(atPath: bundleURL.path) {
            try manager.moveItem(at: bundleURL, to: parkedURL)
        }
        do {
            try manager.moveItem(at: stagedURL, to: bundleURL)
        } catch {
            if manager.fileExists(atPath: parkedURL.path) {
                try? manager.moveItem(at: parkedURL, to: bundleURL)
            }
            throw error
        }

        try? manager.removeItem(at: parkedURL)
    }

    @discardableResult
    nonisolated private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "VeoUpdates",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(URL(fileURLWithPath: launchPath).lastPathComponent) failed with status \(process.terminationStatus)."
                ]
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Scheduling + versions

    private func scheduleAutomaticChecks() {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 6 * 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates(userInitiated: false) }
        }
        timer.tolerance = 600
        self.timer = timer
    }

    static func normalizedVersion(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") { value.removeFirst() }
        return value
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let left = components(of: candidate)
        let right = components(of: current)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func components(of version: String) -> [Int] {
        normalizedVersion(version)
            .split(whereSeparator: { $0 == "." || $0 == "-" })
            .compactMap { Int($0.prefix(while: \.isNumber)) }
    }
}

/// Writes the GitHub asset to disk on a background session so the UI thread stays free.
private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    var session: URLSession?
    private var lastReported = -1.0
    private var hasFinished = false

    init(
        destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void,
        continuation: CheckedContinuation<Void, Error>
    ) {
        self.destination = destination
        self.onProgress = onProgress
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        guard fraction - lastReported >= 0.01 || fraction >= 1 else { return }
        lastReported = fraction
        onProgress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(
                    domain: "VeoUpdates",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "The update download failed (HTTP \(http.statusCode))."]
                )
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !hasFinished else { return }
        hasFinished = true
        session?.finishTasksAndInvalidate()
        session = nil
        switch result {
        case .success:
            onProgress(1)
            continuation?.resume(returning: ())
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}
