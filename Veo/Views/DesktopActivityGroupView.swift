// FILE: DesktopActivityGroupView.swift
// Purpose: Compresses contiguous reasoning and tool events into one readable work phase.
// Layer: Desktop app view

import Foundation
import SwiftUI

enum DesktopTimelineEntry: Identifiable, Equatable {
    case message(DesktopTimelineItem)
    case plan(DesktopTimelineItem)
    case activity(DesktopActivityGroup)
    case viewedImages(DesktopViewedImagesGroup)

    var id: String {
        switch self {
        case .message(let item): return item.id
        case .plan(let item): return item.id
        case .activity(let group): return group.id
        case .viewedImages(let group): return group.id
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

        for item in items {
            switch item.kind {
            case .imageView:
                flushActivity()
                imageItems.append(item)
            case .reasoning, .command, .fileChange, .activity, .planUpdate:
                flushImages()
                activityItems.append(item)
            case .plan:
                flushActivity()
                flushImages()
                entries.append(.plan(item))
            case .user, .assistant, .error:
                flushActivity()
                flushImages()
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

    private var isActive: Bool {
        guard isTurnRunning else { return false }
        return group.items.contains { item in
            let status = (item.status ?? "").lowercased()
            return status.contains("progress") || status == "running" || status == "active" || status == "pending"
        }
    }

    private var hasFailure: Bool {
        group.items.contains { item in
            let status = (item.status ?? "").lowercased()
            return status.contains("fail") || status.contains("error") || status.contains("cancel")
                || item.toolMetadata?.errorMessage?.isEmpty == false
        }
    }

    private var title: String {
        let tools = group.items.filter { $0.kind != .reasoning }
        let reasoningCount = group.items.count - tools.count
        let webCount = tools.filter { $0.title.localizedCaseInsensitiveContains("web search") }.count
        let commandCount = tools.filter { $0.kind == .command }.count
        let fileCount = tools.filter { $0.kind == .fileChange }.count

        if isActive {
            if let latestTool = tools.last { return activeTitle(for: latestTool) }
            return "Thinking"
        }
        if hasFailure { return "Work stopped with an issue" }
        if tools.isEmpty { return reasoningCount == 1 ? "Thought through the approach" : "Reasoned through the task" }
        if webCount == tools.count { return webCount == 1 ? "Searched the web" : "Researched on the web" }
        if commandCount == tools.count { return commandCount == 1 ? "Ran a command" : "Ran \(commandCount) commands" }
        if fileCount == tools.count { return fileCount == 1 ? "Updated files" : "Updated files" }
        if tools.count == 1, let tool = tools.first { return completedTitle(for: tool) }
        return "Worked through the task"
    }

    private var stepLabel: String? {
        guard group.items.count > 1 else { return nil }
        return "\(group.items.count) steps"
    }

    private var sites: [DesktopActivitySite] {
        DesktopActivitySite.extract(from: group.items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 8) {
                        statusMark

                        if isActive {
                            DesktopShimmerText(
                                text: title,
                                font: .system(size: 11.5, weight: .medium),
                                baseStyle: AnyShapeStyle(.secondary),
                                isActive: true
                            )
                        } else {
                            Text(title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "Hide" : "Show") work details: \(title)")

                if !sites.isEmpty {
                    DesktopActivitySiteStrip(sites: sites)
                }

                Button(action: toggleExpanded) {
                    HStack(spacing: 4) {
                        if let stepLabel {
                            Text(stepLabel)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(group.items.count)-step work trace")

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
    }

    @ViewBuilder
    private var statusMark: some View {
        DesktopActivityCompletionMark(isLoading: isActive, hasFailure: hasFailure)
            .frame(width: 12, height: 12)
    }

    private func activeTitle(for item: DesktopTimelineItem) -> String {
        switch item.kind {
        case .command: return "Running a command"
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

    static func extract(from items: [DesktopTimelineItem]) -> [DesktopActivitySite] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
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
                detector?.enumerateMatches(in: candidate, options: [], range: range) { match, _, _ in
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
                    .font(.system(size: 10.5, weight: .medium, design: item.kind == .command ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let duration = item.toolMetadata?.durationMilliseconds {
                    Text(formatDuration(duration))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if !item.body.isEmpty {
                Text(renderedBody)
                    .font(.system(size: item.kind == .command ? 10.5 : 11.5, design: item.kind == .command ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(showsFullOutput ? nil : bodyLineLimit)
                    .textSelection(.enabled)
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
        (try? AttributedString(
            markdown: item.body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(item.body)
    }

    private var shouldOfferFullOutput: Bool {
        item.body.split(whereSeparator: \Character.isNewline).count > bodyLineLimit
            || item.body.count > 500
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
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(.tertiary)

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
