// FILE: DesktopUtilityPanelView.swift
// Purpose: Hosts Safari-style Review, browser, and Files tabs in Veo's right utility panel.
// Layer: Desktop app view

import SwiftUI

struct DesktopUtilityPanelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectedTabShape
    @State private var tabsWidth: CGFloat?
    @State private var tabFrames: [UUID: CGRect] = [:]
    private let panelSurface = Color(nsColor: .controlBackgroundColor).opacity(0.55)

    @Bindable var store: DesktopCodexStore
    @ObservedObject var model: DesktopUtilityPanelModel
    @AppStorage(DesktopAppearancePreferences.rightSidebarMaterialKey) private var rightSidebarMaterialRaw =
        DesktopSidebarMaterial.mica.rawValue

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            panelContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(panelSurface)
        }
        .background(Color.black.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.primary.opacity(0.09), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        // The inspector owns horizontal sizing. Declaring a second min/ideal
        // width here makes AppKit and SwiftUI continuously renegotiate the
        // split child's constraints on recent macOS releases.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .desktopRightSidebarChrome(
            DesktopSidebarMaterial(rawValue: rightSidebarMaterialRaw) ?? .mica
        )
    }

    @ViewBuilder
    private var panelContent: some View {
        switch model.selectedTab?.content {
        case .some(.plan(let reference)):
            DesktopPlanPanelView(store: store, reference: reference)
        case .some(.review):
            if let diff = model.turnDiff {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Changes from this turn").font(.headline)
                        Spacer()
                        Button("Workspace changes") { model.turnDiff = nil }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 38)
                    Divider()
                    DesktopTurnChangesPopover(summary: .init(diff: diff), material: .solid, isInInspector: true)
                        .id(diff.turnID)
                    Spacer(minLength: 0)
                }
            } else {
                DesktopReviewPanelView(store: store, presentsAIReview: $model.presentsAIReview)
            }
        case .some(.sideChat):
            DesktopSideChatView(store: store)
        case .some(.browser):
            DesktopBrowserPanelView(
                model: model.browser,
                accountLoginSession: store.accountLoginSession,
                onCancelAccountLogin: { store.cancelAccountLogin() }
            )
        case .some(.files):
            DesktopFilesPanelView(files: model.files, repository: store.gitRepository) { fileURL, workspaceURL in
                model.openWorkspaceFile(fileURL, workspaceURL: workspaceURL)
            }
        case .some(.subagents):
            DesktopSubagentsPanelView(store: store, model: model)
        case .none:
            ContentUnavailableView("No utility tab", systemImage: "rectangle.stack")
        }
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 1) {
                            ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, item in
                                tabButton(for: item, index: index)
                                    .background {
                                        if model.selectedTabID == item.id {
                                            DesktopJoinedTabShape()
                                                .fill(panelSurface)
                                                .matchedGeometryEffect(id: "selected", in: selectedTabShape)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .background {
                                        GeometryReader { tab in
                                            Color.clear.preference(key: DesktopTabFrames.self, value: [
                                                item.id: tab.frame(in: .named("utility-tab-viewport"))
                                            ])
                                        }
                                    }
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 6)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabsWidth = $0 }
                        .padding(.top, 4)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.19), value: model.selectedTabID)
                    }
                    .scrollIndicators(.hidden)
                    .coordinateSpace(name: "utility-tab-viewport")
                    .onPreferenceChange(DesktopTabFrames.self) { tabFrames = $0 }
                    .overlay(alignment: .leading) {
                        if let target = model.tabs.last(where: { (tabFrames[$0.id]?.minX ?? 0) < -0.5 }) {
                            scrollButton(leading: true) { scroll(proxy, to: target.id, anchor: .leading) }
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if let target = model.tabs.first(where: { (tabFrames[$0.id]?.maxX ?? 0) > viewport.size.width + 0.5 }) {
                            scrollButton(leading: false) { scroll(proxy, to: target.id, anchor: .trailing) }
                        }
                    }
                    .onChange(of: model.selectedTabID, initial: true) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            .frame(maxWidth: tabsWidth)
            .layoutPriority(1)
            newTabMenu.padding(.horizontal, 2)
            Spacer(minLength: 0)
                .layoutPriority(-1)
        }
        .frame(height: 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Utility tab bar")
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: UUID, anchor: UnitPoint) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: anchor) }
    }

    private func scrollButton(leading: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: leading ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 29)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(leading ? "Scroll tabs left" : "Scroll tabs right")
        .accessibilityLabel(leading ? "Scroll tabs left" : "Scroll tabs right")
    }

    private var newTabMenu: some View {
        Menu {
            Button {
                model.addTab(.review)
            } label: {
                Label("Review", systemImage: DesktopUtilityPanelTab.review.systemImage)
            }
            Button {
                model.addTab(.browser)
            } label: {
                Label("Browser Tab", systemImage: DesktopUtilityPanelTab.browser.systemImage)
            }
            Button {
                model.addTab(.files)
            } label: {
                Label("Files", systemImage: DesktopUtilityPanelTab.files.systemImage)
            }
            Button {
                model.show(.sideChat)
            } label: {
                Label("Side chat", systemImage: DesktopUtilityPanelTab.sideChat.systemImage)
            }
            .disabled(store.selectedThreadID == nil)
            if model.subagentsAvailable {
                Button {
                    model.addTab(.subagents)
                } label: {
                    Label("Subagents", systemImage: DesktopUtilityPanelTab.subagents.systemImage)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("New utility tab")
        .accessibilityLabel("New Tab")
    }

    @ViewBuilder
    private func tabButton(for item: DesktopUtilityPanelItem, index: Int) -> some View {
        switch item.content {
        case .plan(let reference):
            DesktopUtilityTabButton(
                title: "Plan",
                systemImage: DesktopUtilityPanelTab.plan.systemImage,
                isLoading: store.planArtifact(for: reference)?.lifecycle == .implementing,
                isSelected: model.selectedTabID == item.id,
                select: { model.selectTab(item.id) },
                close: { model.closeTab(item.id) }
            )
            .contextMenu { tabContextMenu(item: item, index: index) }
        case .review:
            DesktopUtilityTabButton(
                title: "Review",
                systemImage: DesktopUtilityPanelTab.review.systemImage,
                isLoading: false,
                isSelected: model.selectedTabID == item.id,
                select: { model.selectTab(item.id) },
                close: { model.closeTab(item.id) }
            )
            .contextMenu { tabContextMenu(item: item, index: index) }
        case .files:
            DesktopUtilityTabButton(
                title: "Files",
                systemImage: DesktopUtilityPanelTab.files.systemImage,
                isLoading: false,
                isSelected: model.selectedTabID == item.id,
                select: { model.selectTab(item.id) },
                close: { model.closeTab(item.id) }
            )
            .contextMenu { tabContextMenu(item: item, index: index) }
        case .sideChat:
            DesktopUtilityTabButton(
                title: "Side chat",
                systemImage: DesktopUtilityPanelTab.sideChat.systemImage,
                isLoading: store.selectedSideChat?.isRunning == true,
                isSelected: model.selectedTabID == item.id,
                select: { model.selectTab(item.id) },
                close: { model.closeTab(item.id) }
            )
            .contextMenu { tabContextMenu(item: item, index: index) }
        case .subagents:
            DesktopUtilityTabButton(
                title: "Subagents",
                systemImage: DesktopUtilityPanelTab.subagents.systemImage,
                isLoading: store.selectedSubagents.contains(where: \.isActive),
                isSelected: model.selectedTabID == item.id,
                select: { model.selectTab(item.id) },
                close: { model.closeTab(item.id) }
            )
            .contextMenu { tabContextMenu(item: item, index: index) }
        case .browser(let browserTabID):
            if let browserTab = model.browser.tabs.first(where: { $0.id == browserTabID }) {
                DesktopUtilityBrowserTabButton(
                    tab: browserTab,
                    isSelected: model.selectedTabID == item.id,
                    select: { model.selectTab(item.id) },
                    close: { model.closeTab(item.id) }
                )
                .contextMenu { tabContextMenu(item: item, index: index) }
            }
        }
    }

    @ViewBuilder
    private func tabContextMenu(item: DesktopUtilityPanelItem, index: Int) -> some View {
        Button("Move Left") { model.moveTab(item.id, to: index - 1) }
            .disabled(index == 0)
        Button("Move Right") { model.moveTab(item.id, to: index + 1) }
            .disabled(index >= model.tabs.count - 1)
        Divider()
        Button("Close Tab") { model.closeTab(item.id) }
    }
}

private struct DesktopUtilityBrowserTabButton: View {
    @ObservedObject var tab: DesktopBrowserTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        DesktopUtilityTabButton(
            title: tab.title,
            systemImage: "globe",
            isLoading: tab.isLoading,
            isSelected: isSelected,
            select: select,
            close: close
        )
    }
}

private struct DesktopUtilityTabButton: View {
    let title: String
    let systemImage: String
    let isLoading: Bool
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 13, height: 13)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 13)
                    }
                    Text(title)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 26, maxWidth: 106, alignment: .leading)
                }
                .padding(.leading, 9)
                .padding(.trailing, 5)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 24)
                    .padding(.trailing, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close " + title)
            .accessibilityLabel("Close " + title + " tab")
            .opacity(isSelected || isHovering ? 1 : 0.5)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 32)
        .background {
            if isHovering && !isSelected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.primary.opacity(0.045))
                    .padding(.vertical, 3)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
    }
}

private struct DesktopTabFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// The lower corners turn outward so the selected tab joins the inspector surface.
private struct DesktopJoinedTabShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let top: CGFloat = 9, foot: CGFloat = 5
        var path = Path()
        path.move(to: CGPoint(x: -foot, y: h))
        path.addQuadCurve(to: CGPoint(x: 0, y: h - foot), control: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: 0, y: top))
        path.addQuadCurve(to: CGPoint(x: top, y: 0), control: .zero)
        path.addLine(to: CGPoint(x: w - top, y: 0))
        path.addQuadCurve(to: CGPoint(x: w, y: top), control: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: h - foot))
        path.addQuadCurve(to: CGPoint(x: w + foot, y: h), control: CGPoint(x: w, y: h))
        path.closeSubpath()
        return path
    }
}
