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

    /// Only bundles the user actually installed can be replaced in place; a build
    /// running from DerivedData or a read-only mount falls back to the release page.
    var canInstallInPlace: Bool {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else { return false }
        return FileManager.default.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
    }

    init(
        defaults: UserDefaults = .standard,
        feedURL: URL = URL(string: "https://api.github.com/repos/itsasheruwu/Veo/releases/latest")!,
        session: URLSession = .shared
    ) {
        DesktopUpdatePreferences.registerDefaults(defaults)
        self.defaults = defaults
        self.feedURL = feedURL
        self.session = session
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
        default: return nil
        }
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading: return true
        default: return false
        }
    }

    func checkForUpdates(userInitiated: Bool) {
        guard activeTask == nil else { return }
        if case .downloading = phase { return }
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
                if self.automaticInstall, self.canInstallInPlace, release.downloadURL != nil {
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

    func openReleasePage() {
        let url = availableRelease?.pageURL
            ?? URL(string: "https://github.com/itsasheruwu/Veo/releases/latest")!
        NSWorkspace.shared.open(url)
    }

    func installUpdate(_ release: DesktopUpdateRelease) {
        guard activeTask == nil, let downloadURL = release.downloadURL else {
            openReleasePage()
            return
        }
        guard canInstallInPlace else {
            openReleasePage()
            return
        }
        phase = .downloading(0)
        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.activeTask = nil }
            do {
                let archiveURL = try await self.download(from: downloadURL)
                defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
                try await self.replaceRunningBundle(withDiskImageAt: archiveURL)
                self.phase = .readyToRelaunch(release)
            } catch is CancellationError {
                self.phase = .available(release)
            } catch {
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
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

    private func download(from url: URL) async throws -> URL {
        let (temporaryURL, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "VeoUpdates",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "The update download failed (HTTP \(http.statusCode))."]
            )
        }
        let stagingURL = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: Bundle.main.bundleURL,
            create: true
        )
        let destination = stagingURL.appendingPathComponent("Veo-update.dmg")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        phase = .downloading(1)
        return destination
    }

    // MARK: - Install

    private func replaceRunningBundle(withDiskImageAt imageURL: URL) async throws {
        let bundleURL = Bundle.main.bundleURL
        let mountPoint = try Self.run(
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
        defer { _ = try? Self.run("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"]) }

        let contents = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
        guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
            throw NSError(
                domain: "VeoUpdates",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "The update image does not contain a Veo app."]
            )
        }
        let sourceURL = URL(fileURLWithPath: mountPoint).appendingPathComponent(appName)

        // Verify the new bundle is signed before it replaces the running one.
        _ = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", sourceURL.path])

        let stagedURL = bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(".Veo-update-\(UUID().uuidString.prefix(8)).app")
        _ = try Self.run("/usr/bin/ditto", [sourceURL.path, stagedURL.path])
        do {
            try Self.swapInPlace(stagedURL: stagedURL, bundleURL: bundleURL)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }
    }

    /// Installs the staged bundle by renaming rather than `replaceItemAt`.
    ///
    /// A bundle installed from the PKG is owned by `root:wheel`, and
    /// `replaceItemAt` fails against it with POSIX 13 even though `/Applications`
    /// itself is group-writable by admins. Directory-level renames only need write
    /// permission on the enclosing folder, so they succeed where replacing the item
    /// in place does not. The previous bundle is moved aside first so a failure can
    /// still restore it, and is only deleted once the new bundle is in position.
    private static func swapInPlace(stagedURL: URL, bundleURL: URL) throws {
        let manager = FileManager.default
        // A fixed name keeps an undeletable leftover from accumulating one copy
        // per update; each install reuses the same slot.
        var parkedURL = bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(".Veo-previous.app")
        try? manager.removeItem(at: parkedURL)
        if manager.fileExists(atPath: parkedURL.path) {
            // The slot is held by an undeletable root-owned leftover, so this
            // install needs its own.
            parkedURL = bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(".Veo-previous-\(UUID().uuidString.prefix(8)).app")
        }

        try manager.moveItem(at: bundleURL, to: parkedURL)
        do {
            try manager.moveItem(at: stagedURL, to: bundleURL)
        } catch {
            // Put the working install back before surfacing the failure.
            try? manager.moveItem(at: parkedURL, to: bundleURL)
            throw error
        }

        // A root-owned previous bundle (installed from the PKG) cannot be deleted,
        // chmod'd, or moved by an unprivileged process. The update itself already
        // succeeded, so the leftover is hidden and left in place rather than
        // failing an otherwise complete install; the next PKG install or a manual
        // delete clears it.
        try? manager.removeItem(at: parkedURL)
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
