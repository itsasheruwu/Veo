import Foundation

@MainActor
enum DesktopModelPickerUpgrade {
    private static let appliedKey = "VeoDesktop.sliderPickerDefaultApplied"
    private static let pendingKey = "VeoDesktop.sliderPickerNoticePending"
    private static var claimedNotice = false

    static func applyIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: appliedKey) else { return }
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        let hasSavedPreferences = domain.keys.contains { $0.hasPrefix("VeoDesktop.") }
        let database = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.ash.Veo/Threads/veo-threads.sqlite")
        let hasHistory = database.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        applyIfNeeded(to: defaults, hasExistingProfile: hasSavedPreferences || hasHistory)
    }

    static func applyIfNeeded(to defaults: UserDefaults, hasExistingProfile: Bool) {
        guard !defaults.bool(forKey: appliedKey) else { return }
        let key = DesktopAppearancePreferences.modelPickerAppearanceKey
        let previous = defaults.string(forKey: key)
        let updated = DesktopModelPickerAppearance.defaultAppearance.rawValue
        let switched = (hasExistingProfile || previous != nil) && previous != updated
        if switched { defaults.set(true, forKey: pendingKey) }
        defaults.set(updated, forKey: key)
        defaults.set(true, forKey: appliedKey)
    }

    static func claimNotice() -> Bool {
        let defaults = UserDefaults.standard
        guard !claimedNotice, defaults.bool(forKey: pendingKey) else { return false }
        guard DesktopAppearancePreferences.modelPickerAppearance == .sliderAdvanced else {
            finishNotice()
            return false
        }
        claimedNotice = true
        return true
    }

    static func finishNotice(restoreNative: Bool = false, defaults: UserDefaults = .standard) {
        if restoreNative {
            defaults.set(DesktopModelPickerAppearance.native.rawValue, forKey: DesktopAppearancePreferences.modelPickerAppearanceKey)
        }
        defaults.removeObject(forKey: pendingKey)
    }
}
