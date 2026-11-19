// FILE: DesktopModelCatalogPreferences.swift
// Purpose: Persists which models Veo shows in the picker and which external providers are connected.
// Layer: Desktop app model

import Foundation
import Observation

@MainActor @Observable
final class DesktopModelCatalogPreferences {
    static let shared = DesktopModelCatalogPreferences()

    static let includeExternalModelsKey = "VeoDesktop.includeExternalModels"
    static let includeGPT56ModelsKey = "VeoDesktop.includeGPT56Models"
    static let disabledModelIDsKey = "VeoDesktop.disabledModelIDs"
    static let providersKey = "VeoDesktop.externalProviders"

    private(set) var includeExternalModels: Bool
    private(set) var includeGPT56Models: Bool
    private(set) var disabledModelIDs: Set<String>
    private(set) var providers: [DesktopConnectedProvider]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        includeExternalModels = defaults.bool(forKey: Self.includeExternalModelsKey)
        includeGPT56Models = defaults.bool(forKey: Self.includeGPT56ModelsKey)
        if let stored = defaults.array(forKey: Self.disabledModelIDsKey) as? [String] {
            disabledModelIDs = Set(stored)
        } else {
            disabledModelIDs = []
        }
        providers = defaults.data(forKey: Self.providersKey)
            .flatMap { try? JSONDecoder().decode([DesktopConnectedProvider].self, from: $0) }
            ?? []
    }

    var hasEnabledExternalModels: Bool {
        includeExternalModels && providers.contains { $0.models.contains(where: \.enabled) }
    }

    var publishedExternalModels: [DesktopExternalModelRecord] {
        guard includeExternalModels else { return [] }
        return providers.flatMap(\.enabledModels)
    }

    func isNativeModelEnabled(_ model: DesktopModelOption) -> Bool {
        (includeGPT56Models || !model.isGPT56Family) && !disabledModelIDs.contains(model.id)
    }

    func isExternalModelEnabled(_ id: String) -> Bool {
        guard includeExternalModels else { return false }
        return providers.contains { provider in
            provider.models.contains { $0.id == id && $0.enabled }
        }
    }

    @discardableResult
    func setNativeModelEnabled(_ id: String, enabled: Bool, remainingEnabledIDs: [String]) -> Bool {
        if !enabled {
            let stillEnabled = remainingEnabledIDs.filter { $0 != id }
            guard !stillEnabled.isEmpty else { return false }
            disabledModelIDs.insert(id)
        } else {
            disabledModelIDs.remove(id)
        }
        persistDisabled()
        return true
    }

    func setIncludeExternalModels(_ enabled: Bool) {
        includeExternalModels = enabled
        defaults.set(enabled, forKey: Self.includeExternalModelsKey)
    }

    func setIncludeGPT56Models(_ enabled: Bool) {
        includeGPT56Models = enabled
        defaults.set(enabled, forKey: Self.includeGPT56ModelsKey)
    }

    func upsertProvider(_ provider: DesktopConnectedProvider) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
        persistProviders()
    }

    func setExternalModelEnabled(providerID: String, modelID: String, enabled: Bool) {
        guard let providerIndex = providers.firstIndex(where: { $0.id == providerID }),
              let modelIndex = providers[providerIndex].models.firstIndex(where: { $0.id == modelID }) else {
            return
        }
        providers[providerIndex].models[modelIndex].enabled = enabled
        persistProviders()
    }

    func removeProvider(_ id: String) {
        providers.removeAll { $0.id == id }
        persistProviders()
    }

    func provider(forModelID id: String) -> DesktopConnectedProvider? {
        providers.first { provider in
            provider.models.contains { $0.id == id }
        }
    }

    private func persistDisabled() {
        defaults.set(Array(disabledModelIDs).sorted(), forKey: Self.disabledModelIDsKey)
    }

    private func persistProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: Self.providersKey)
        }
    }
}
