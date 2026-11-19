import SwiftUI

struct DesktopQueuedDraftsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: DesktopCodexStore
    @State private var showsAll = false
    @State private var editedID: String?
    @State private var editedText = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        let queue = store.selectedQueuedDrafts
        VStack(alignment: .leading, spacing: 0) {
            header(count: queue.count)
                .padding(.bottom, 5)
            if showsAll && queue.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(queue) { payload in row(payload, queue: queue) }
                    }
                }
                .frame(height: min(168, CGFloat(queue.count) * 29 + 10))
                .transition(.opacity)
            } else if let payload = queue.first {
                row(payload, queue: queue)
                    .id(payload.id)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16)
                .fill(.primary.opacity(0.035))
        }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued follow-ups")
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: queue.map(\.id))
        .onChange(of: store.selectedThreadID) { _, _ in reset() }
        .onChange(of: queue.map(\.id)) { _, ids in
            if ids.count <= 1 { showsAll = false }
            if let editedID, !ids.contains(editedID) { self.editedID = nil }
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            Label("Queued", systemImage: "text.line.last.and.arrowtriangle.forward")
                .foregroundStyle(.secondary)
            Spacer()
            if count > 1 {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.23)) { showsAll.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Text(showsAll ? "Show next" : "Show all \(count)")
                        Image(systemName: showsAll ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(showsAll ? "Show only the next queued message" : "Show all \(count) queued messages")
            }
        }
        .font(.system(size: 11, weight: .semibold))
    }

    private func row(_ payload: DesktopComposerPayload, queue: [DesktopComposerPayload]) -> some View {
        let uncertain = store.queuedDraftIsUncertain(payload.id)
        return VStack(alignment: .leading, spacing: 5) {
            if editedID == payload.id {
                TextField("Queued message", text: $editedText, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($editorFocused)
                HStack {
                    Spacer()
                    Button("Cancel") { editedID = nil }
                        .buttonStyle(.borderless)
                    Button("Save") {
                        store.updateQueuedDraft(payload.id, text: editedText)
                        editedID = nil
                    }
                    .buttonStyle(.bordered)
                    .disabled(uncertain || editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && payload.attachments.isEmpty)
                }
            } else {
                HStack(spacing: 7) {
                    Text(payload.text.isEmpty ? "Attachments" : DesktopInlineContext.displayText(payload.text))
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(0)
                    if uncertain {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                            .help("Check the queue before retrying")
                            .accessibilityLabel("Queue delivery needs to be checked")
                    } else if store.isRunningTurn && store.capabilities.supports(.turnSteering) {
                        Button("Steer now") { store.steerQueuedDraft(payload.id) }
                            .buttonStyle(.bordered)
                    } else if !store.isBusyTurn && queue.first?.id == payload.id {
                        Button("Send now") { store.sendNextQueuedDraft() }
                            .buttonStyle(.bordered)
                    }
                    Button("Edit", systemImage: "pencil") {
                        editedText = payload.text
                        editedID = payload.id
                        editorFocused = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Edit queued message")
                    .disabled(uncertain)
                    Button("Remove", systemImage: "xmark") { store.removeQueuedDraft(payload.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove queued message")
                    if showsAll {
                        Menu {
                            Button("Move earlier", systemImage: "arrow.up") { store.moveQueuedDraft(payload.id, offset: -1) }
                                .disabled(uncertain || queue.first?.id == payload.id)
                            Button("Move later", systemImage: "arrow.down") { store.moveQueuedDraft(payload.id, offset: 1) }
                                .disabled(uncertain || queue.last?.id == payload.id)
                        } label: {
                            Label("Reorder queued message", systemImage: "ellipsis")
                                .labelStyle(.iconOnly)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
            if !payload.attachments.isEmpty {
                DesktopAttachmentStrip(attachments: payload.attachments)
            }
        }
        .controlSize(.small)
        .font(.system(size: 11.5, weight: .medium))
    }

    private func reset() {
        editedID = nil
        showsAll = false
    }
}
