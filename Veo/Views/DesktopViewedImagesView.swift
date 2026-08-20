// FILE: DesktopViewedImagesView.swift
// Purpose: Shows agent imageView events as a Codex-style collapsible thumbnail row.
// Layer: Desktop app view

import SwiftUI

struct DesktopViewedImagesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let group: DesktopViewedImagesGroup
    let workspaceURL: URL?

    @State private var isExpanded: Bool

    init(group: DesktopViewedImagesGroup, workspaceURL: URL?) {
        self.group = group
        self.workspaceURL = workspaceURL
        _isExpanded = State(
            initialValue: DesktopAppearancePreferences.viewedImagesInitialExpansion.startsExpanded
        )
    }

    private enum Metrics {
        static let headerFontSize: CGFloat = 11.5
        static let iconSize: CGFloat = 11
        static let iconFrame: CGFloat = 12
        static let chevronSize: CGFloat = 8.5
        static let thumbnailHeight: CGFloat = 96
        static let thumbnailMaxWidth: CGFloat = 140
        static let thumbnailCornerRadius: CGFloat = 8
        static let thumbnailSpacing: CGFloat = 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggleExpanded) {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: Metrics.iconSize, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: Metrics.iconFrame)

                    Text(group.title)
                        .font(.system(size: Metrics.headerFontSize, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Image(systemName: "chevron.right")
                        .font(.system(size: Metrics.chevronSize, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isExpanded ? "Hide" : "Show") \(group.title.lowercased())")
            .accessibilityValue("\(group.items.count) \(group.items.count == 1 ? "image" : "images")")

            if isExpanded {
                thumbnailStrip
                    .transition(.opacity)
            }

            if !isExpanded {
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
    private var thumbnailStrip: some View {
        if group.items.count > 3 {
            ScrollView(.horizontal, showsIndicators: false) {
                thumbnails
            }
        } else {
            thumbnails
        }
    }

    private var thumbnails: some View {
        HStack(alignment: .center, spacing: Metrics.thumbnailSpacing) {
            ForEach(group.items) { item in
                SafeLocalImageThumbnail(
                    path: path(for: item),
                    workspaceURL: workspaceURL,
                    displayName: item.title,
                    maxWidth: Metrics.thumbnailMaxWidth,
                    height: Metrics.thumbnailHeight,
                    cornerRadius: Metrics.thumbnailCornerRadius
                )
                .id(item.id)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func path(for item: DesktopTimelineItem) -> String {
        if let source = item.artifacts.first(where: { $0.kind == .localFile })?.source,
           !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return source
        }
        return item.body
    }

    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            isExpanded.toggle()
        }
    }
}
