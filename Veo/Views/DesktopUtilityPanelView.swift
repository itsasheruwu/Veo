// FILE: DesktopUtilityPanelView.swift
// Purpose: Hosts Safari-style Review, browser, and Files tabs in Veo's right utility panel.
// Layer: Desktop app view

import SwiftUI

struct DesktopUtilityPanelView: View {
    @ObservedObject var store: DesktopCodexStore
    @ObservedObject var model: DesktopUtilityPanelModel
    @AppStorage(DesktopAppearancePreferences.rightSidebarMaterialKey) private var rightSidebarMaterialRaw =
        DesktopSidebarMaterial.mica.rawValue

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()

            switch model.selectedTab?.content {
            case .some(.plan(let reference)):
                DesktopPlanPanelView(store: store, reference: reference)
            case .some(.review):
                DesktopReviewPanelView(
                    store: store,
                    presentsAIReview: $model.presentsAIReview
                )
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
        // The inspector owns horizontal sizing. Declaring a second min/ideal
        // width here makes AppKit and SwiftUI continuously renegotiate the
        // split child's constraints on recent macOS releases.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .desktopRightSidebarChrome(
            DesktopSidebarMaterial(rawValue: rightSidebarMaterialRaw) ?? .mica
        )
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 1) {
                    ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, item in
                        tabButton(for: item, index: index)
                    }

                    newTabMenu
                }
                .padding(.leading, 6)
                .padding(.trailing, 5)
                .padding(.vertical, 5)
            }
            .scrollIndicators(.hidden)

            Spacer(minLength: 0)
        }
        .frame(height: 40)
        .background(Color.primary.opacity(0.025))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Utility tab bar")
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
        HStack(spacing: 5) {
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected || isHovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close tab")
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .frame(minWidth: 96, idealWidth: 126, maxWidth: 164, minHeight: 29, maxHeight: 29)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.105 : isHovering ? 0.055 : 0))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
