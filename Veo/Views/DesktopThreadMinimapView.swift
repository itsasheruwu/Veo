// FILE: DesktopThreadMinimapView.swift
// Purpose: Provides lightweight, accessible topic navigation beside the conversation timeline.
// Layer: Desktop app view

import AppKit
import SwiftUI

struct DesktopThreadMinimapTurn: Identifiable, Hashable {
    let id: String
    let targetItemID: String
    let itemIDs: [String]
    let userPrompt: String
    let assistantPreview: String
    let contentLength: Int
    let ordinal: Int
    let topicKeywords: Set<String>
    let sourceTurnCount: Int

    var markerWidth: CGFloat {
        let scaled = log2(Double(max(contentLength, 1)) + 1) * 1.45
        return 12 + min(CGFloat(scaled), 15)
    }

    static func make(
        from items: [DesktopTimelineItem],
        modelTopicStartIDs: Set<String>? = nil
    ) -> [Self] {
        DesktopThreadMinimapSnapshot(items: items)
            .topicTurns(modelTopicStartIDs: modelTopicStartIDs)
    }

    static func analysisRequest(from items: [DesktopTimelineItem]) -> DesktopThreadMinimapAnalysisRequest? {
        DesktopThreadMinimapSnapshot(items: items).makeAnalysisRequest()
    }

    fileprivate static func topicTurns(
        from rawTurns: [DesktopThreadMinimapTurn],
        modelTopicStartIDs: Set<String>? = nil
    ) -> [Self] {

        var topics: [DesktopThreadMinimapTurn] = []
        for turn in rawTurns {
            let startsModelTopic = modelTopicStartIDs?.contains(turn.id) == true
            let startsHeuristicTopic = topics.last.map {
                startsNewTopic(after: $0, candidate: turn)
            } ?? true
            if topics.isEmpty
                || (modelTopicStartIDs != nil ? startsModelTopic : startsHeuristicTopic) {
                topics.append(turn)
            } else if let current = topics.last {
                topics[topics.count - 1] = merging(current, with: turn)
            }
        }

        return topics.enumerated().map { offset, topic in
            DesktopThreadMinimapTurn(
                id: topic.id,
                targetItemID: topic.targetItemID,
                itemIDs: topic.itemIDs,
                userPrompt: topic.userPrompt,
                assistantPreview: topic.assistantPreview,
                contentLength: topic.contentLength,
                ordinal: offset + 1,
                topicKeywords: topic.topicKeywords,
                sourceTurnCount: topic.sourceTurnCount
            )
        }
    }

    fileprivate static func analysisRequest(
        fromRawTurns turns: [DesktopThreadMinimapTurn]
    ) -> DesktopThreadMinimapAnalysisRequest? {
        guard turns.count > 1, turns.count <= 300 else { return nil }
        let summaries: [[String: String]] = turns.map { turn in
            [
                "id": turn.id,
                "user": String(turn.userPrompt.prefix(320)),
                "assistant": String(turn.assistantPreview.prefix(220)),
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: summaries),
              let summariesJSON = String(data: data, encoding: .utf8) else { return nil }
        let ids = turns.map(\.id)
        return DesktopThreadMinimapAnalysisRequest(
            fingerprint: ids.enumerated().map { index, id in
                "\(id):\(turns[index].contentLength)"
            }.joined(separator: "|"),
            candidateTurnIDs: ids,
            prompt: """
            Identify the important work-topic phases in this conversation. Return the id of the first turn in each phase.

            Group corrections, refinements, verification, debugging, and follow-ups with the feature or task they belong to. Start a new phase only when the user changes to a meaningfully different feature, objective, or body of work. Do not create a point for every turn. Always include the first id. Prefer a restrained number of useful navigation points.

            Turns:
            \(summariesJSON)
            """
        )
    }

    fileprivate static func rawTurns(from items: [DesktopTimelineItem]) -> [DesktopThreadMinimapTurn] {
        struct Builder {
            var id: String
            var targetItemID: String
            var itemIDs: [String] = []
            var userPrompt = ""
            var assistantParts: [String] = []
            var contentLength = 0
            var hasConversationMessage = false
            var topicContextParts: [String] = []
        }

        var builders: [Builder] = []
        var indexByTurnID: [String: Int] = [:]
        var currentIndex: Int?

        for item in items {
            let index: Int
            if let turnID = item.turnID {
                if let existing = indexByTurnID[turnID] {
                    index = existing
                } else {
                    index = builders.count
                    builders.append(Builder(id: "turn:\(turnID)", targetItemID: item.id))
                    indexByTurnID[turnID] = index
                }
                currentIndex = index
            } else if item.kind == .user {
                index = builders.count
                builders.append(Builder(id: "item:\(item.id)", targetItemID: item.id))
                currentIndex = index
            } else if let currentIndex {
                index = currentIndex
            } else if item.kind == .assistant {
                index = builders.count
                builders.append(Builder(id: "item:\(item.id)", targetItemID: item.id))
                currentIndex = index
            } else {
                continue
            }

            builders[index].itemIDs.append(item.id)

            switch item.kind {
            case .user:
                builders[index].hasConversationMessage = true
                if builders[index].userPrompt.isEmpty {
                    builders[index].userPrompt = item.body
                    builders[index].targetItemID = item.id
                }
                builders[index].contentLength += item.body.count
                builders[index].topicContextParts.append(item.body)
            case .assistant:
                builders[index].hasConversationMessage = true
                if !item.body.isEmpty {
                    builders[index].assistantParts.append(item.body)
                    builders[index].contentLength += item.body.count
                }
            case .fileChange, .plan:
                if !item.body.isEmpty {
                    builders[index].topicContextParts.append(item.body)
                }
            default:
                break
            }
        }

        return builders
            .filter(\.hasConversationMessage)
            .enumerated()
            .map { offset, builder in
                DesktopThreadMinimapTurn(
                    id: builder.id,
                    targetItemID: builder.targetItemID,
                    itemIDs: builder.itemIDs,
                    userPrompt: normalizedPreview(builder.userPrompt, fallback: "User prompt unavailable"),
                    assistantPreview: normalizedPreview(
                        builder.assistantParts.joined(separator: " "),
                        fallback: "No assistant response yet"
                    ),
                    contentLength: builder.contentLength,
                    ordinal: offset + 1,
                    topicKeywords: topicKeywords(in: builder.topicContextParts.joined(separator: " ")),
                    sourceTurnCount: 1
                )
            }
    }

    private static func startsNewTopic(
        after current: DesktopThreadMinimapTurn,
        candidate: DesktopThreadMinimapTurn
    ) -> Bool {
        let candidateKeywords = candidate.topicKeywords
        guard !candidateKeywords.isEmpty else { return false }

        let overlap = current.topicKeywords.intersection(candidateKeywords).count
        let smallerKeywordCount = max(1, min(current.topicKeywords.count, candidateKeywords.count))
        let similarity = Double(overlap) / Double(smallerKeywordCount)
        if overlap >= 2 || similarity >= 0.28 {
            return false
        }

        let prompt = candidate.userPrompt.lowercased()
        let explicitShiftPhrases = [
            "new feature", "another feature", "different feature", "next feature",
            "switch to", "move on to", "instead work on", "start working on",
            "separate task", "different task", "new task", "now let's", "now lets"
        ]
        if explicitShiftPhrases.contains(where: prompt.contains), overlap == 0 {
            return true
        }

        let continuationPhrases = [
            "that", "this", "it", "same", "continue", "keep", "still", "also",
            "first thing", "actually", "instead", "make it", "change it", "fix it"
        ]
        if continuationPhrases.contains(where: prompt.hasPrefix) {
            return false
        }

        // A substantial, lexically distinct request is treated as a new workstream.
        // Requiring several meaningful terms prevents terse corrections from creating noise.
        return overlap == 0
            && candidateKeywords.count >= 3
            && candidate.userPrompt.count >= 72
    }

    private static func merging(
        _ current: DesktopThreadMinimapTurn,
        with candidate: DesktopThreadMinimapTurn
    ) -> DesktopThreadMinimapTurn {
        DesktopThreadMinimapTurn(
            id: current.id,
            targetItemID: current.targetItemID,
            itemIDs: current.itemIDs + candidate.itemIDs,
            userPrompt: current.userPrompt,
            assistantPreview: candidate.assistantPreview == "No assistant response yet"
                ? current.assistantPreview
                : candidate.assistantPreview,
            contentLength: current.contentLength + candidate.contentLength,
            ordinal: current.ordinal,
            topicKeywords: current.topicKeywords.union(candidate.topicKeywords),
            sourceTurnCount: current.sourceTurnCount + candidate.sourceTurnCount
        )
    }

    private static func topicKeywords(in text: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "an", "and", "are", "as", "at", "be", "been", "but", "by", "can",
            "could", "do", "does", "for", "from", "get", "has", "have", "how", "i",
            "if", "in", "into", "is", "it", "just", "make", "me", "more", "my", "new",
            "not", "now", "of", "on", "or", "please", "should", "so", "some", "than",
            "that", "the", "then", "there", "these", "this", "to", "up", "use", "want",
            "was", "we", "were", "what", "when", "where", "which", "will", "with", "you",
            "your", "add", "change", "fix", "implement", "update", "work", "working", "feature"
        ]

        let normalized = text.lowercased().map { character -> Character in
            character.isLetter || character.isNumber || character == "/" || character == "."
                ? character
                : " "
        }
        return Set(String(normalized)
            .split(whereSeparator: \Character.isWhitespace)
            .map(String.init)
            .filter { token in
                token.count >= 3
                    && !stopWords.contains(token)
                    && !token.allSatisfy(\.isNumber)
            })
    }

    private static func normalizedPreview(_ text: String, fallback: String) -> String {
        let normalized = text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? fallback : normalized
    }
}

/// The minimap has two consumers: deterministic rendering and optional model analysis.
/// Build their shared turn representation once for each timeline revision so a streamed
/// response does not normalize the full history twice from `body`.
struct DesktopThreadMinimapSnapshot: Hashable {
    let rawTurns: [DesktopThreadMinimapTurn]

    init(items: [DesktopTimelineItem]) {
        self.rawTurns = DesktopThreadMinimapTurn.rawTurns(from: items)
    }

    static let empty = DesktopThreadMinimapSnapshot(items: [])

    func topicTurns(modelTopicStartIDs: Set<String>?) -> [DesktopThreadMinimapTurn] {
        DesktopThreadMinimapTurn.topicTurns(
            from: rawTurns,
            modelTopicStartIDs: modelTopicStartIDs
        )
    }

    func makeAnalysisRequest() -> DesktopThreadMinimapAnalysisRequest? {
        DesktopThreadMinimapTurn.analysisRequest(fromRawTurns: rawTurns)
    }
}

struct DesktopThreadMinimapAnalysisRequest: Hashable {
    let fingerprint: String
    let candidateTurnIDs: [String]
    let prompt: String

    var outputSchema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "topicStartIDs": [
                    "type": "array",
                    "items": ["type": "string", "enum": candidateTurnIDs],
                    "minItems": 1,
                    "uniqueItems": true,
                ],
            ],
            "required": ["topicStartIDs"],
        ]
    }
}

struct DesktopThreadMinimapHover: Equatable {
    let turn: DesktopThreadMinimapTurn
    let globalCenterY: CGFloat
}

private struct DesktopMinimapMarkerCenterKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct DesktopThreadMinimapView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.veoAccent) private var veoAccent

    let turns: [DesktopThreadMinimapTurn]
    let activeTurnID: String?
    let material: DesktopMinimapMaterial
    let onSelect: (DesktopThreadMinimapTurn) -> Void
    let onHover: (DesktopThreadMinimapHover?) -> Void

    @State private var hoveredTurnID: String?
    @State private var markerCenters: [String: CGFloat] = [:]
    @FocusState private var focusedTurnID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 1) {
                    ForEach(turns) { turn in
                        markerButton(for: turn)
                            .id(turn.id)
                    }
                }
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .modifier(DesktopFloatingMaterialSurface(material: material))
            .onChange(of: activeTurnID) { _, turnID in
                guard let turnID else { return }
                scrollMarker(turnID, proxy: proxy)
            }
            .onChange(of: turns.count) { _, _ in
                if let activeTurnID {
                    scrollMarker(activeTurnID, proxy: proxy)
                }
            }
            .onPreferenceChange(DesktopMinimapMarkerCenterKey.self) { centers in
                markerCenters = centers
                publishHoverIfPossible()
            }
            .onMoveCommand(perform: moveFocus)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Thread minimap")
            .accessibilityHint("Navigate between important thread topics")
        }
    }

    private func markerButton(for turn: DesktopThreadMinimapTurn) -> some View {
        let isActive = turn.id == activeTurnID
        let isHovered = turn.id == hoveredTurnID

        return Button {
            focusedTurnID = turn.id
            onSelect(turn)
        } label: {
            HStack {
                Spacer(minLength: 0)
                Capsule(style: .continuous)
                    .fill(markerColor(isActive: isActive, isHovered: isHovered))
                    .frame(width: turn.markerWidth, height: isActive ? 3.5 : 2.5)
                    .animation(markerAnimation, value: isActive)
                    .animation(markerAnimation, value: isHovered)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .contentShape(Rectangle())
            .background {
                ZStack {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: DesktopMinimapMarkerCenterKey.self,
                            value: [turn.id: geometry.frame(in: .global).midY]
                        )
                    }
                    DesktopMinimapHoverSensor { hovering in
                        updateHover(hovering, turn: turn)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .focused($focusedTurnID, equals: turn.id)
        .help("Topic \(turn.ordinal): \(turn.userPrompt)")
        .accessibilityLabel("Topic \(turn.ordinal)")
        .accessibilityValue(isActive ? "Current topic" : "")
        .accessibilityHint("\(turn.userPrompt). Press Return to scroll to this topic.")
    }

    private func markerColor(isActive: Bool, isHovered: Bool) -> Color {
        if isActive { return veoAccent }
        if isHovered { return Color.primary.opacity(0.72) }
        return Color.primary.opacity(0.3)
    }

    private func updateHover(_ hovering: Bool, turn: DesktopThreadMinimapTurn) {
        if hovering {
            guard hoveredTurnID != turn.id else { return }
            withAnimation(markerAnimation) {
                hoveredTurnID = turn.id
            }
            onHover(DesktopThreadMinimapHover(
                turn: turn,
                globalCenterY: markerCenters[turn.id] ?? 0
            ))
        } else {
            guard hoveredTurnID == turn.id else { return }
            withAnimation(markerAnimation) {
                hoveredTurnID = nil
            }
            onHover(nil)
        }
    }

    private var markerAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.14)
    }

    private func scrollMarker(_ id: String, proxy: ScrollViewProxy) {
        let action = { proxy.scrollTo(id, anchor: .center) }
        if reduceMotion {
            action()
        } else {
            withAnimation(.easeOut(duration: 0.18), action)
        }
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        guard !turns.isEmpty else { return }
        let currentID = focusedTurnID ?? activeTurnID
        let currentIndex = currentID.flatMap { id in turns.firstIndex(where: { $0.id == id }) }
            ?? 0
        let nextIndex: Int

        switch direction {
        case .up, .left:
            nextIndex = max(0, currentIndex - 1)
        case .down, .right:
            nextIndex = min(turns.count - 1, currentIndex + 1)
        @unknown default:
            return
        }

        let turn = turns[nextIndex]
        focusedTurnID = turn.id
        onSelect(turn)
    }

    private func publishHoverIfPossible() {
        guard let hoveredTurnID,
              let turn = turns.first(where: { $0.id == hoveredTurnID }),
              let center = markerCenters[hoveredTurnID] else { return }
        onHover(DesktopThreadMinimapHover(turn: turn, globalCenterY: center))
    }
}

/// SwiftUI hover phases can be dropped for tiny buttons nested inside a scrolling rail.
/// This non-hit-testing tracking view owns only pointer enter/exit; the SwiftUI Button
/// remains responsible for clicks, focus, keyboard activation, and accessibility.
private struct DesktopMinimapHoverSensor: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            onChange?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onChange?(false)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

struct DesktopThreadMinimapPreview: View {
    let turn: DesktopThreadMinimapTurn
    let material: DesktopMinimapMaterial

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.userPrompt)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)

            Text(turn.assistantPreview)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .modifier(DesktopFloatingMaterialSurface(material: material))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Topic \(turn.ordinal) preview")
    }
}
