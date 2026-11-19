import SwiftUI

struct DesktopConversationTurnStatus: View {
    let presentation: DesktopTurnPresentation
    let isRunning: Bool
    var waitingLabel: String?
    var isContinuation = false
    var summary: String?
    let hasDetails: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        if isRunning, let start = presentation.startedAt, waitingLabel == nil {
            TimelineView(.periodic(from: start, by: 1)) { context in
                row("Working for " + (presentation.elapsed(until: context.date) ?? "0s"), interactive: false)
            }
        } else if isRunning {
            row(waitingLabel ?? "Working…", interactive: false)
        } else {
            row(completedLabel, interactive: hasDetails)
        }
    }

    private var completedLabel: String {
        let elapsed = presentation.completedAt.flatMap(presentation.elapsed(until:))
        if isContinuation { return elapsed.map { "Continued for " + $0 } ?? "Continued" }
        let status = presentation.status?.lowercased() ?? ""
        if status.contains("interrupt") || status.contains("cancel") {
            return elapsed.map { "Stopped after " + $0 } ?? "Stopped"
        }
        if status.contains("fail") || status.contains("error") {
            return elapsed.map { "Failed after " + $0 } ?? "Turn failed"
        }
        return elapsed.map { "Worked for " + $0 } ?? "Worked"
    }

    private func row(_ label: String, interactive: Bool) -> some View {
        HStack(spacing: 10) {
            if interactive {
                Button(action: toggle) {
                    Label(label, systemImage: isExpanded ? "chevron.down" : "chevron.right")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "Hide turn activity" : "Show turn activity")
            } else {
                Text(label)
            }
            if let summary, !summary.isEmpty {
                Text(summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.tertiary)
            }
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .font(.system(size: 12, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

struct DesktopConversationTurnAnchors {
    var promptByTurn: [String: String] = [:]
    var replyByTurn: [String: String] = [:]
    var workBySegment: [String: [DesktopTimelineItem]] = [:]
    var segmentByItem: [String: String] = [:]
    var followsByTurn: [String: [DesktopTimelineItem]] = [:]

    init(_ items: [DesktopTimelineItem]) {
        var segmentByTurn: [String: String] = [:]
        for item in items {
            guard let turnID = item.turnID else { continue }
            switch item.kind {
            case .user:
                if promptByTurn[turnID] == nil {
                    promptByTurn[turnID] = item.id
                    segmentByTurn[turnID] = turnID
                } else {
                    segmentByTurn[turnID] = item.id
                    followsByTurn[turnID, default: []].append(item)
                }
            case .assistant:
                replyByTurn[turnID] = item.id
            case .reasoning, .command, .fileChange, .activity, .planUpdate:
                let segment = segmentByTurn[turnID] ?? turnID
                segmentByItem[item.id] = segment
                workBySegment[segment, default: []].append(item)
            default:
                break
            }
        }
    }

    func continuation(after item: DesktopTimelineItem, turn: DesktopTurnPresentation) -> DesktopTurnPresentation {
        let following = followsByTurn[turn.id] ?? []
        let next = following.firstIndex(where: { $0.id == item.id }).flatMap {
            following.indices.contains($0 + 1) ? following[$0 + 1] : nil
        }
        let began = item.clientID.flatMap { turn.steers?[$0] }
        let ended = next?.clientID.flatMap { turn.steers?[$0] } ?? turn.completedAt
        return .init(id: item.id, startedAt: began, completedAt: ended)
    }

    func summary(for id: String) -> String? {
        guard let work = workBySegment[id], !work.isEmpty else { return nil }
        let group = DesktopActivityGroup(items: work)
        return group.completedSummary
    }
}
