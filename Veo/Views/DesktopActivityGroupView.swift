// FILE: DesktopActivityGroupView.swift
// Purpose: Compresses contiguous reasoning and tool events into one readable work phase.
// Layer: Desktop app view

import Foundation
import SwiftUI

enum DesktopTimelineEntry: Identifiable, Equatable {
    case turnDivider(beforeItemID: String)
    case message(DesktopTimelineItem)
    case plan(DesktopTimelineItem)
    case activity(DesktopActivityGroup)
    case viewedImages(DesktopViewedImagesGroup)
    case imageGeneration(DesktopTimelineItem)

    var id: String {
        switch self {
        case .turnDivider(let itemID): return "turn-divider-\(itemID)"
        case .message(let item): return item.id
        case .plan(let item): return item.id
        case .activity(let group): return group.id
        case .viewedImages(let group): return group.id
        case .imageGeneration(let item): return item.id
        }
    }

    static func make(from items: [DesktopTimelineItem]) -> [DesktopTimelineEntry] {
        var entries: [DesktopTimelineEntry] = []
        var activityItems: [DesktopTimelineItem] = []
        var imageItems: [DesktopTimelineItem] = []

        func flushActivity() {
            guard !activityItems.isEmpty else { return }
            entries.append(.activity(DesktopActivityGroup(items: activityItems)))
            activityItems.removeAll(keepingCapacity: true)
        }

        func flushImages() {
            guard !imageItems.isEmpty else { return }
            entries.append(.viewedImages(DesktopViewedImagesGroup(items: imageItems)))
            imageItems.removeAll(keepingCapacity: true)
        }

        let replies = Dictionary(grouping: items.enumerated().filter { $0.element.kind == .assistant }, by: { $0.element.turnID })
        var delivered: [String: [DesktopToolArtifact]] = [:]
        var linkedImages = Set<String>()
        var emittedSources = Set<String>()
        for (index, item) in items.enumerated() where item.isGeneratedImage && !item.isResearch && !item.isImageGenerationInProgress {
            guard let turnID = item.turnID,
                  let artifact = item.artifacts.first else { continue }
            let recipients = replies[turnID] ?? []
            let named = artifact.kind == .localFile ? recipients.first(where: { $0.element.body.contains(artifact.source) }) : nil
            guard let reply = named ?? recipients.first(where: { $0.offset > index }) ?? recipients.last else { continue }
            linkedImages.insert(item.id)
            if emittedSources.insert(turnID + "|" + artifact.source).inserted {
                delivered[reply.element.id, default: []].append(artifact)
            }
        }

        for var item in items {
            if item.isGeneratedImage && !item.isResearch {
                flushActivity()
                flushImages()
                if !linkedImages.contains(item.id) { entries.append(.imageGeneration(item)) }
                continue
            }
            if let concepts = delivered[item.id] { item.generatedConcepts = concepts }
            switch item.kind {
            case .imageView:
                flushActivity()
                imageItems.append(item)
            case .reasoning, .command, .fileChange, .activity, .planUpdate:
                flushImages()
                if let previous = activityItems.last, previous.turnID != item.turnID
                    || previous.isRobloxTool != item.isRobloxTool
                    || previous.isResearch != item.isResearch
                    || (item.isResearch && previous.isGeneratedImage != item.isGeneratedImage) { flushActivity() }
                activityItems.append(item)
            case .plan:
                flushActivity()
                flushImages()
                entries.append(.plan(item))
            case .user, .assistant, .error:
                flushActivity()
                flushImages()
                // Separate visible exchanges, not internal runtime turns or streamed
                // response items. This also works before a pending prompt has a turn ID.
                if item.kind == .user, !entries.isEmpty {
                    entries.append(.turnDivider(beforeItemID: item.id))
                }
                entries.append(.message(item))
            }
        }
        flushActivity()
        flushImages()
        return entries
    }
}

struct DesktopActivityGroup: Identifiable, Equatable {
    let items: [DesktopTimelineItem]

    var id: String { "activity-group-\(items.first?.id ?? "empty")" }
    var itemIDs: [String] { items.map(\.id) }
    var isRoblox: Bool { items.first?.isRobloxTool == true }
    var isResearch: Bool { items.first?.isResearch == true }
    var hasFailure: Bool {
        items.contains { item in
            let status = (item.status ?? "").lowercased()
            return status.contains("fail") || status.contains("error") || status.contains("cancel")
                || item.toolMetadata?.errorMessage?.isEmpty == false
                || item.toolMetadata?.exitCode.map { $0 != 0 } == true
        }
    }

    var completedSummary: String? {
        if let failed = items.first(where: {
            let status = ($0.status ?? "").lowercased()
            return status.contains("fail") || status.contains("error")
                || $0.toolMetadata?.errorMessage?.isEmpty == false
                || $0.toolMetadata?.exitCode.map { $0 != 0 } == true
        }) {
            return "Failed: " + failed.title
        }
        let files = items.filter { $0.kind == .fileChange }
        let paths = Set(files.filter { $0.body != "Updated project files" }.flatMap { $0.body.split(separator: "\n") })
        let commands = items.count { $0.kind == .command }
        let searches = items.count { $0.title.localizedCaseInsensitiveContains("web search") }
        var summary: [String] = []
        if paths.count > 0 { summary.append(paths.count == 1 ? "Edited 1 file" : "Edited \(paths.count) files") }
        else if !files.isEmpty { summary.append("Updated files") }
        if commands > 0 { summary.append(commands == 1 ? "Ran 1 command" : "Ran \(commands) commands") }
        if searches > 0 { summary.append(searches == 1 ? "Searched the web" : "Ran \(searches) web searches") }
        return summary.isEmpty ? nil : summary.joined(separator: " · ")
    }
}

struct DesktopViewedImagesGroup: Identifiable, Equatable {
    let items: [DesktopTimelineItem]

    var id: String { "viewed-images-\(items.first?.id ?? "empty")" }
    var itemIDs: [String] { items.map(\.id) }

    var title: String {
        items.count == 1 ? "Viewed an image" : "Viewed images"
    }
}

struct DesktopActivityGroupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.veoAccent) private var veoAccent

    let group: DesktopActivityGroup
    let workspaceURL: URL?
    let isTurnRunning: Bool
    var subagents: [DesktopSubagentSummary] = []
    var onOpenSubagent: (String) -> Void = { _ in }

    @State private var isExpanded = false
    @State private var isVisible = false
    @Environment(\.controlActiveState) private var windowState

    private var liveItem: DesktopTimelineItem? {
        guard isTurnRunning else { return nil }
        let active = group.items.filter { item in
            let status = (item.status ?? "").lowercased()
            return status.contains("progress") || status == "running" || status == "active" || status == "pending"
        }
        return active.last(where: { $0.kind != .reasoning }) ?? active.last
    }

    private var hasFailure: Bool { group.hasFailure }

    private func title(for liveItem: DesktopTimelineItem?) -> String {
        if group.isRoblox { return "Roblox ×\(group.items.count)" + (hasFailure ? " · Failed" : "") }
        if group.isResearch {
            let image = group.items.first?.isGeneratedImage == true
            if let liveItem { return liveItem.isGeneratedImage ? "Generating reference" : "Referencing" }
            if group.items.contains(where: { $0.status?.localizedCaseInsensitiveContains("cancel") == true }) { return "Reference canceled" }
            if hasFailure { return "Reference failed" }
            return image ? "Referenced generation" : "Referenced"
        }
        if let liveItem { return activeTitle(for: liveItem) }
        let tools = group.items.filter { $0.kind != .reasoning }
        let reasoningCount = group.items.count - tools.count

        if let summary = group.completedSummary { return summary }
        if tools.isEmpty { return reasoningCount == 1 ? "Thought through the approach" : "Reasoned through the task" }
        if tools.count == 1, let tool = tools.first { return completedTitle(for: tool) }
        return "Worked through the task"
    }

    private var stepLabel: String? {
        guard group.items.count > 1 else { return nil }
        if liveItem == nil, !group.hasFailure, group.items.allSatisfy({ $0.kind == .command }) { return nil }
        return "\(group.items.count) steps"
    }

    var body: some View {
        let sites = DesktopActivitySite.extract(from: group.items)
        let liveItem = liveItem
        let title = title(for: liveItem)
        let headerID = (liveItem?.id ?? "") + "\n" + title
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 7) {
                        ZStack(alignment: .leading) {
                            HStack(spacing: 8) {
                                if group.isRoblox || group.isResearch {
                                    DesktopModeGlyph(name: group.isRoblox ? "veo.roblox" : "veo.wild")
                                        .foregroundStyle(group.isRoblox ? Color.red : .pink)
                                        .accessibilityHidden(true)
                                } else if let liveItem {
                                    Image(systemName: liveItem.activityGlyph)
                                        .font(.system(size: 10, weight: .medium))
                                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                                        .frame(width: 12, height: 12)
                                        .accessibilityHidden(true)
                                } else {
                                    DesktopActivityCompletionMark(isLoading: false, hasFailure: hasFailure)
                                        .frame(width: 12, height: 12)
                                }

                                Text(title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                            }
                            .modifier(DesktopShimmerStyle(isActive: liveItem != nil && (!group.isResearch || (isVisible && windowState != .inactive))))
                            .id(headerID)
                            .transition(reduceMotion ? .identity : .asymmetric(
                                insertion: .modifier(
                                    active: DesktopActivityReveal(fraction: 0),
                                    identity: DesktopActivityReveal(fraction: 1)
                                ).combined(with: .opacity),
                                removal: .opacity
                            ))
                        }
                        .frame(height: 15)
                        .clipped()
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: headerID)
                        if let stepLabel, !group.isRoblox {
                            Text(stepLabel)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .padding(.horizontal, 8)
                    .frame(minHeight: 26)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide work details" : "Show work details")
                .focusable(interactions: .edit)
                .onKeyPress(keys: [.space, .return]) { _ in
                    toggleExpanded()
                    return .handled
                }
                .accessibilityLabel(title)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Toggle work details")

                if !sites.isEmpty {
                    DesktopActivitySiteStrip(sites: sites)
                }

                Spacer(minLength: 0)
            }

            if !subagents.isEmpty {
                DesktopSubagentPillStrip(
                    agents: subagents,
                    onSelect: onOpenSubagent
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(group.items) { item in
                        DesktopActivityStepView(item: item, workspaceURL: workspaceURL)
                    }
                }
                .padding(.leading, 5)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.09))
                        .frame(width: 1)
                        .padding(.vertical, 7)
                }
                .transition(.opacity)
            }

            if !isExpanded {
                // Preserve item-level ScrollViewReader destinations while the trace is collapsed.
                ZStack {
                    ForEach(group.itemIDs, id: \.self) { itemID in
                        Color.clear.frame(width: 0, height: 0).id(itemID)
                    }
                }
                .frame(height: 0)
                .accessibilityHidden(true)
            }
        }
        .trackingScrollVisibility { isVisible = $0 }
    }

    private func activeTitle(for item: DesktopTimelineItem) -> String {
        switch item.kind {
        case .command:
            return item.title.isEmpty ? "Running a command" :
                "Running " + item.title.split(whereSeparator: \.isNewline).joined(separator: " ")
        case .fileChange: return "Updating files"
        case .planUpdate: return "Updating the execution plan"
        case .imageView:
            return "Viewing an image"
        case .activity:
            return item.title.localizedCaseInsensitiveContains("web search") ? "Searching the web" : item.title
        default: return "Thinking"
        }
    }

    private func completedTitle(for item: DesktopTimelineItem) -> String {
        switch item.kind {
        case .command: return "Ran a command"
        case .fileChange: return "Updated files"
        case .planUpdate: return "Updated the execution plan"
        case .imageView:
            return "Viewed an image"
        case .activity:
            return item.title.localizedCaseInsensitiveContains("web search") ? "Searched the web" : item.title
        default: return "Worked through the task"
        }
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            isExpanded.toggle()
        }
    }
}

private struct DesktopActivityReveal: AnimatableModifier {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func body(content: Content) -> some View {
        content.mask(alignment: .leading) {
            GeometryReader { proxy in
                Rectangle().frame(width: proxy.size.width * fraction)
            }
        }
    }
}

private extension DesktopTimelineItem {
    var activityGlyph: String {
        switch kind {
        case .reasoning: return "ellipsis"
        case .command: return "terminal"
        case .fileChange: return "pencil"
        case .plan, .planUpdate: return "checklist"
        case .imageView: return "photo"
        case .activity where title.localizedCaseInsensitiveContains("web search"): return "magnifyingglass"
        default: return "gearshape"
        }
    }
}

/// Keeps activity completion quiet while making the live-to-finished state change legible.
struct DesktopActivityCompletionMark: View {
    let isLoading: Bool
    let hasFailure: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completionProgress: CGFloat

    init(isLoading: Bool, hasFailure: Bool) {
        self.isLoading = isLoading
        self.hasFailure = hasFailure
        _completionProgress = State(initialValue: isLoading ? 0 : 1)
    }

    var body: some View {
        ZStack {
            ProgressView()
                .controlSize(.mini)
                .opacity(isLoading ? 1 - completionProgress : 0)
                .scaleEffect(1 - (completionProgress * 0.22))

            if hasFailure {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .opacity(completionProgress)
                    .scaleEffect(0.72 + (completionProgress * 0.28))
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(completionProgress)
                    .scaleEffect(0.72 + (completionProgress * 0.28))
            }
        }
        .onChange(of: isLoading) { _, loading in
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72)) {
                completionProgress = loading ? 0 : 1
            }
        }
        .onChange(of: hasFailure) { _, failed in
            guard failed else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.72)) {
                completionProgress = 1
            }
        }
        .accessibilityHidden(true)
    }
}

private struct DesktopActivitySite: Identifiable, Hashable {
    @MainActor private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    let url: URL
    let host: String

    var id: String { host }

    var displayHost: String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var pageName: String {
        let decodedPath = url.path.removingPercentEncoding ?? url.path
        guard let component = decodedPath.split(separator: "/").last, !component.isEmpty else {
            return displayHost
        }
        let cleaned = component
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".html", with: "", options: .caseInsensitive)
        return cleaned.isEmpty ? displayHost : cleaned.capitalized
    }

    @MainActor
    static func extract(from items: [DesktopTimelineItem]) -> [DesktopActivitySite] {
        var sites: [DesktopActivitySite] = []
        var seenHosts = Set<String>()

        for item in items {
            let candidates = [
                item.body,
                item.detail ?? "",
                item.toolMetadata?.argumentsJSON ?? "",
                item.toolMetadata?.progressMessage ?? ""
            ] + item.artifacts.map(\.source)

            for candidate in candidates where !candidate.isEmpty {
                let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
                linkDetector?.enumerateMatches(in: candidate, options: [], range: range) { match, _, _ in
                    guard let candidateURL = match?.url,
                          let url = SafeExternalURLPolicy.validatedHTTPSURL(candidateURL),
                          let host = url.host?.lowercased(),
                          seenHosts.insert(host).inserted else { return }
                    sites.append(DesktopActivitySite(url: url, host: host))
                }
            }
        }

        return sites
    }
}

private struct DesktopActivitySiteStrip: View {
    let sites: [DesktopActivitySite]

    private let visibleLimit = 4
    private let summaryIconSize: CGFloat = 16

    var body: some View {
        HStack(spacing: -4) {
            ForEach(Array(sites.prefix(visibleLimit).enumerated()), id: \.element.id) { index, site in
                DesktopActivitySiteBubble(site: site, appearanceDelay: Double(index) * 0.045)
                    .zIndex(Double(visibleLimit - index))
            }

            if sites.count > visibleLimit {
                Text("+\(sites.count - visibleLimit)")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: summaryIconSize, height: summaryIconSize)
                    .background(.thinMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .accessibilityLabel("\(sites.count - visibleLimit) more websites")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Websites viewed")
    }
}

private struct DesktopActivitySiteBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.veoAccent) private var veoAccent

    let site: DesktopActivitySite
    let appearanceDelay: Double

    @State private var appeared = false
    @State private var showsPreview = false
    @State private var previewIsHovered = false
    @State private var dismissGeneration = 0
    @StateObject private var iconLoader: DesktopSiteIconLoader

    private let summaryIconSize: CGFloat = 16

    init(site: DesktopActivitySite, appearanceDelay: Double) {
        self.site = site
        self.appearanceDelay = appearanceDelay
        _iconLoader = StateObject(wrappedValue: DesktopSiteIconLoader(pageURL: site.url))
    }

    var body: some View {
        Button {
            _ = SafeExternalURLPolicy.openFromUserAction(site.url)
        } label: {
            favicon(size: summaryIconSize)
                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
        }
        .buttonStyle(.plain)
        .scaleEffect(appeared ? 1 : 0.68)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.76).delay(appearanceDelay)) {
                    appeared = true
                }
            }
        }
        .onHover(perform: handleBubbleHover)
        .popover(isPresented: $showsPreview, arrowEdge: .bottom) {
            previewCard
        }
        .help("Open \(site.displayHost)")
        .accessibilityLabel("Open page on \(site.displayHost): \(site.pageName)")
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                favicon(size: 28)
                    .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 1) {
                    Text(site.displayHost)
                        .font(.system(size: 12, weight: .semibold))
                    Text(site.pageName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text(site.url.absoluteString)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .textSelection(.enabled)

            Button {
                _ = SafeExternalURLPolicy.openFromUserAction(site.url)
                showsPreview = false
            } label: {
                Label("Open page", systemImage: "arrow.up.right")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .onHover(perform: handlePreviewHover)
    }

    @ViewBuilder
    private func favicon(size: CGFloat) -> some View {
        Group {
            if let image = iconLoader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity.combined(with: .scale(scale: 0.88)))
            } else {
                faviconFallback(size: size)
            }
        }
        .frame(width: size, height: size)
        .background(Color.primary.opacity(0.04), in: Circle())
        .clipShape(Circle())
        .task {
            await iconLoader.load()
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: iconLoader.image != nil)
    }

    private func faviconFallback(size: CGFloat) -> some View {
        ZStack {
            Circle().fill(veoAccent.opacity(0.16))
            Text(String(site.displayHost.prefix(1)).uppercased())
                .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                .foregroundStyle(veoAccent)
        }
    }

    private func handleBubbleHover(_ hovering: Bool) {
        dismissGeneration += 1
        if hovering {
            showsPreview = true
        } else {
            scheduleDismiss()
        }
    }

    private func handlePreviewHover(_ hovering: Bool) {
        previewIsHovered = hovering
        dismissGeneration += 1
        if !hovering {
            scheduleDismiss()
        }
    }

    private func scheduleDismiss() {
        let generation = dismissGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard generation == dismissGeneration, !previewIsHovered else { return }
            showsPreview = false
        }
    }
}

private struct DesktopActivityStepView: View {
    let item: DesktopTimelineItem
    let workspaceURL: URL?

    @State private var showsFullOutput = false
    @State private var visibleBodyHeight: CGFloat = 0
    @State private var fullBodyHeight: CGFloat = 0
    @State private var blockedArtifactURLMessage: String?

    private var symbol: String {
        switch item.kind {
        case .reasoning: return "circle.fill"
        case .command: return "terminal"
        case .fileChange: return "doc.badge.gearshape"
        case .plan: return "list.bullet"
        case .planUpdate: return "checklist"
        case .imageView: return "photo"
        default: return "circle.fill"
        }
    }

    private var heading: String {
        item.kind == .reasoning ? "Reasoning" : item.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: item.kind == .reasoning || item.kind == .activity ? 4.5 : 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Text(heading)
                    .font(.system(size: 12, weight: .medium, design: item.kind == .command ? .monospaced : .default))
                    .foregroundStyle(.primary)
                    .lineLimit(showsFullOutput ? nil : 2)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if let duration = item.toolMetadata?.durationMilliseconds {
                    Text(formatDuration(duration))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if !item.body.isEmpty {
                let text = Text(renderedBody)
                    .font(.system(size: 12, design: item.kind == .command ? .monospaced : .default))
                text
                    .foregroundStyle(.primary.opacity(0.82))
                    .lineLimit(showsFullOutput ? nil : bodyLineLimit)
                    .textSelection(.enabled)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { visibleBodyHeight = $0 }
                    .background(alignment: .topLeading) {
                        text
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { fullBodyHeight = $0 }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 19)
            }

            if shouldOfferFullOutput {
                Button(showsFullOutput ? "Show less" : "Show full output") {
                    showsFullOutput.toggle()
                }
                .buttonStyle(.link)
                .font(.system(size: 10, weight: .medium))
                .padding(.leading, 19)
            }

            if let metadata = item.toolMetadata {
                metadataView(metadata)
                    .padding(.leading, 19)
            }

            SafeToolArtifactListView(
                artifacts: item.artifacts,
                workspaceURL: workspaceURL,
                blockedURL: { blockedArtifactURLMessage = $0 }
            )
            .padding(.leading, 19)

            SafeCitationListView(citations: item.citations, workspaceURL: workspaceURL)
                .padding(.leading, 19)

            if let blockedArtifactURLMessage {
                Label(blockedArtifactURLMessage, systemImage: "hand.raised.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .padding(.leading, 19)
            }
        }
        .padding(.leading, 10)
        .id(item.id)
    }

    private var bodyLineLimit: Int {
        item.kind == .command ? 6 : 4
    }

    private var renderedBody: AttributedString {
        DesktopMarkdownRenderCache.activityInlineAttributed(item.body)
    }

    private var shouldOfferFullOutput: Bool {
        showsFullOutput || fullBodyHeight > visibleBodyHeight + 0.5
    }

    @ViewBuilder
    private func metadataView(_ metadata: DesktopToolMetadata) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                if let progress = metadata.progressMessage, !progress.isEmpty {
                    Text(progress)
                }
                if let exitCode = metadata.exitCode {
                    Text("exit \(exitCode)")
                }
                if let processID = metadata.processID {
                    Text(processID)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)

            if let arguments = metadata.argumentsJSON, !arguments.isEmpty {
                DisclosureGroup("Inputs") {
                    Text(arguments)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }

            if let error = metadata.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }
        }
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return "\(milliseconds) ms" }
        return String(format: "%.1f s", Double(milliseconds) / 1_000)
    }
}
