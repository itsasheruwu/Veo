// Purpose: Avoids reparsing sidebar JSON preferences during repeated SwiftUI body evaluation.

import Foundation

@MainActor
final class DesktopSidebarPreferenceCache {
    struct ManualThreadOrder {
        let ids: [String]
        let ranks: [String: Int]
    }

    static let shared = DesktopSidebarPreferenceCache()

    private var displayNamesEntry: (rawJSON: String, value: [String: String])?
    private var collapsedPathsEntry: (rawJSON: String, value: Set<String>)?
    private var manualOrderEntry: (rawJSON: String, value: ManualThreadOrder)?

    private init() {}

    func projectDisplayNames(rawJSON: String) -> [String: String] {
        if let displayNamesEntry, displayNamesEntry.rawJSON == rawJSON {
            return displayNamesEntry.value
        }
        let value = rawJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            ?? [:]
        displayNamesEntry = (rawJSON, value)
        return value
    }

    func collapsedProjectPaths(rawJSON: String) -> Set<String> {
        if let collapsedPathsEntry, collapsedPathsEntry.rawJSON == rawJSON {
            return collapsedPathsEntry.value
        }
        let value = Set(
            rawJSON.data(using: .utf8)
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
                ?? []
        )
        collapsedPathsEntry = (rawJSON, value)
        return value
    }

    func manualThreadOrder(rawJSON: String) -> ManualThreadOrder {
        if let manualOrderEntry, manualOrderEntry.rawJSON == rawJSON {
            return manualOrderEntry.value
        }
        let ids = rawJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
            ?? []
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() where ranks[id] == nil {
            ranks[id] = index
        }
        let value = ManualThreadOrder(ids: ids, ranks: ranks)
        manualOrderEntry = (rawJSON, value)
        return value
    }
}
