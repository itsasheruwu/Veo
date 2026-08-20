// FILE: DesktopTerminalWorkspaceLayout.swift
// Purpose: tmux-style pane tree and grid templates for terminal workspace mode.
// Layer: Desktop app model

import Foundation

enum DesktopTerminalSplitAxis: Equatable {
    case horizontal
    case vertical
}

indirect enum DesktopTerminalPaneNode: Equatable {
    case leaf(UUID)
    case split(
        id: UUID,
        axis: DesktopTerminalSplitAxis,
        ratio: CGFloat,
        first: DesktopTerminalPaneNode,
        second: DesktopTerminalPaneNode
    )

    var sessionIDs: [UUID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, _, _, let first, let second):
            return first.sessionIDs + second.sessionIDs
        }
    }

    var leafCount: Int { sessionIDs.count }

    func contains(_ id: UUID) -> Bool {
        sessionIDs.contains(id)
    }

    func replacing(_ old: UUID, with new: UUID) -> DesktopTerminalPaneNode {
        switch self {
        case .leaf(let id):
            return .leaf(id == old ? new : id)
        case .split(let splitID, let axis, let ratio, let first, let second):
            return .split(
                id: splitID,
                axis: axis,
                ratio: ratio,
                first: first.replacing(old, with: new),
                second: second.replacing(old, with: new)
            )
        }
    }

    func splitting(focused: UUID, axis: DesktopTerminalSplitAxis, newID: UUID) -> DesktopTerminalPaneNode {
        switch self {
        case .leaf(let id):
            guard id == focused else { return self }
            return .split(
                id: UUID(),
                axis: axis,
                ratio: 0.5,
                first: .leaf(id),
                second: .leaf(newID)
            )
        case .split(let splitID, let splitAxis, let ratio, let first, let second):
            return .split(
                id: splitID,
                axis: splitAxis,
                ratio: ratio,
                first: first.splitting(focused: focused, axis: axis, newID: newID),
                second: second.splitting(focused: focused, axis: axis, newID: newID)
            )
        }
    }

    func removing(_ id: UUID) -> DesktopTerminalPaneNode? {
        switch self {
        case .leaf(let leafID):
            return leafID == id ? nil : self
        case .split(_, let axis, let ratio, let first, let second):
            let newFirst = first.removing(id)
            let newSecond = second.removing(id)
            switch (newFirst, newSecond) {
            case (nil, nil):
                return nil
            case (let remaining?, nil):
                return remaining
            case (nil, let remaining?):
                return remaining
            case (let left?, let right?):
                return .split(id: UUID(), axis: axis, ratio: ratio, first: left, second: right)
            }
        }
    }

    func swapping(_ a: UUID, _ b: UUID) -> DesktopTerminalPaneNode {
        guard a != b, contains(a), contains(b) else { return self }
        let placeholder = UUID()
        return replacing(a, with: placeholder)
            .replacing(b, with: a)
            .replacing(placeholder, with: b)
    }

    func settingRatio(splitID: UUID, ratio: CGFloat) -> DesktopTerminalPaneNode {
        switch self {
        case .leaf:
            return self
        case .split(let id, let axis, let current, let first, let second):
            if id == splitID {
                return .split(id: id, axis: axis, ratio: ratio, first: first, second: second)
            }
            return .split(
                id: id,
                axis: axis,
                ratio: current,
                first: first.settingRatio(splitID: splitID, ratio: ratio),
                second: second.settingRatio(splitID: splitID, ratio: ratio)
            )
        }
    }
}

enum DesktopTerminalGridTemplate: String, CaseIterable, Identifiable {
    case single
    case twoUp
    case twoStack
    case quad
    case six

    var id: String { rawValue }

    var title: String {
        switch self {
        case .single: return "Single"
        case .twoUp: return "2-up"
        case .twoStack: return "2-stack"
        case .quad: return "Quad"
        case .six: return "Six"
        }
    }

    var systemImage: String {
        switch self {
        case .single: return "rectangle"
        case .twoUp: return "rectangle.split.2x1"
        case .twoStack: return "rectangle.split.1x2"
        case .quad: return "square.grid.2x2"
        case .six: return "square.grid.3x2"
        }
    }

    var leafCount: Int {
        switch self {
        case .single: return 1
        case .twoUp, .twoStack: return 2
        case .quad: return 4
        case .six: return 6
        }
    }

    func makeTree(ids: [UUID]) -> DesktopTerminalPaneNode {
        let leaf = { (index: Int) -> DesktopTerminalPaneNode in
            .leaf(ids[index])
        }
        func split(
            _ axis: DesktopTerminalSplitAxis,
            _ first: DesktopTerminalPaneNode,
            _ second: DesktopTerminalPaneNode,
            ratio: CGFloat = 0.5
        ) -> DesktopTerminalPaneNode {
            .split(id: UUID(), axis: axis, ratio: ratio, first: first, second: second)
        }
        switch self {
        case .single:
            return leaf(0)
        case .twoUp:
            return split(.horizontal, leaf(0), leaf(1))
        case .twoStack:
            return split(.vertical, leaf(0), leaf(1))
        case .quad:
            return split(
                .vertical,
                split(.horizontal, leaf(0), leaf(1)),
                split(.horizontal, leaf(2), leaf(3))
            )
        case .six:
            return split(
                .horizontal,
                split(.vertical, leaf(0), leaf(3)),
                split(
                    .horizontal,
                    split(.vertical, leaf(1), leaf(4)),
                    split(.vertical, leaf(2), leaf(5))
                ),
                ratio: 1.0 / 3.0
            )
        }
    }
}

extension DesktopLocalTerminalHub {
    var visibleSessionIDs: Set<UUID> {
        Set(paneTree?.sessionIDs ?? [])
    }

    var canSplitFocusedPane: Bool {
        (paneTree?.leafCount ?? 1) < Self.maxVisibleLeaves
    }

    func ensureWorkspaceLayout() {
        guard !tabs.isEmpty else {
            paneTree = nil
            focusedSessionID = nil
            return
        }
        if paneTree == nil {
            let id = selectedTabID ?? tabs[0].id
            paneTree = .leaf(id)
            focusedSessionID = id
            selectedTabID = id
            return
        }
        pruneMissingSessionsFromTree()
        if let focused = focusedSessionID, paneTree?.contains(focused) != true {
            focusedSessionID = paneTree?.sessionIDs.first
        }
        if let focused = focusedSessionID {
            selectedTabID = focused
        }
    }

    func focusWorkspaceSession(_ id: UUID) {
        guard visibleSessionIDs.contains(id) else { return }
        if focusedSessionID != id {
            focusedSessionID = id
        }
        if selectedTabID != id {
            selectedTabID = id
        }
    }

    func activateSessionInWorkspace(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if paneTree?.contains(id) == true {
            focusWorkspaceSession(id)
            return
        }
        if let focused = focusedSessionID, paneTree != nil {
            paneTree = paneTree?.replacing(focused, with: id)
            focusedSessionID = id
            selectedTabID = id
            return
        }
        paneTree = .leaf(id)
        focusedSessionID = id
        selectedTabID = id
    }

    func swapWorkspacePanes(_ a: UUID, _ b: UUID) {
        guard a != b, let tree = paneTree, tree.contains(a), tree.contains(b) else { return }
        paneTree = tree.swapping(a, b)
        focusWorkspaceSession(a)
    }

    func setSplitRatio(_ splitID: UUID, ratio: CGFloat) {
        guard let tree = paneTree else { return }
        let clamped = min(0.8, max(0.2, ratio))
        let next = tree.settingRatio(splitID: splitID, ratio: clamped)
        if next != tree {
            paneTree = next
        }
    }

    @discardableResult
    func addWorkspaceSession(in directory: URL, columns: Int, rows: Int) -> DesktopLocalTerminalSession {
        if canSplitFocusedPane,
           focusedSessionID != nil || selectedTabID != nil || !tabs.isEmpty {
            splitFocusedPane(
                axis: .horizontal,
                in: directory,
                columns: columns,
                rows: rows
            )
            if let selectedSession { return selectedSession }
        }

        let session = addTab(in: directory, columns: columns, rows: rows)
        if paneTree == nil {
            paneTree = .leaf(session.id)
            focusedSessionID = session.id
        } else {
            activateSessionInWorkspace(session.id)
        }
        return session
    }

    func splitFocusedPane(
        axis: DesktopTerminalSplitAxis,
        in directory: URL,
        columns: Int,
        rows: Int
    ) {
        guard canSplitFocusedPane else { return }
        let focused = focusedSessionID ?? selectedTabID ?? tabs.first?.id
        guard let focused else { return }
        let created = addTab(in: directory, columns: columns, rows: rows)
        let base = paneTree ?? .leaf(focused)
        paneTree = base.splitting(focused: focused, axis: axis, newID: created.id)
        focusedSessionID = created.id
        selectedTabID = created.id
    }

    func applyGridTemplate(
        _ template: DesktopTerminalGridTemplate,
        in directory: URL,
        columns: Int,
        rows: Int
    ) {
        let ids = sessionIDs(forLeafCount: template.leafCount, in: directory, columns: columns, rows: rows)
        guard ids.count >= template.leafCount else { return }
        paneTree = template.makeTree(ids: Array(ids.prefix(template.leafCount)))
        focusedSessionID = ids[0]
        selectedTabID = ids[0]
    }

    func pruneWorkspaceLayout(removed id: UUID) {
        guard let tree = paneTree else {
            focusedSessionID = selectedTabID
            return
        }
        if let next = tree.removing(id) {
            paneTree = next
            if focusedSessionID == id {
                focusedSessionID = next.sessionIDs.first
            }
        } else if let remaining = selectedTabID ?? tabs.first?.id {
            paneTree = .leaf(remaining)
            focusedSessionID = remaining
        } else {
            paneTree = nil
            focusedSessionID = nil
        }
        if let focused = focusedSessionID {
            selectedTabID = focused
        }
        pruneMissingSessionsFromTree()
    }

    private func pruneMissingSessionsFromTree() {
        guard var tree = paneTree else { return }
        let live = Set(tabs.map(\.id))
        for id in tree.sessionIDs where !live.contains(id) {
            if let next = tree.removing(id) {
                tree = next
            } else if let remaining = tabs.first?.id {
                paneTree = .leaf(remaining)
                focusedSessionID = remaining
                return
            } else {
                paneTree = nil
                focusedSessionID = nil
                return
            }
        }
        paneTree = tree
    }

    private func sessionIDs(
        forLeafCount count: Int,
        in directory: URL,
        columns: Int,
        rows: Int
    ) -> [UUID] {
        var ids: [UUID] = []
        if let tree = paneTree {
            ids.append(contentsOf: tree.sessionIDs)
        }
        for tab in tabs where !ids.contains(tab.id) {
            ids.append(tab.id)
            if ids.count >= count { break }
        }
        while ids.count < count {
            ids.append(addTab(in: directory, columns: columns, rows: rows).id)
        }
        return ids
    }
}
