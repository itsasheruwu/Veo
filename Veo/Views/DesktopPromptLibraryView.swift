import SwiftUI

/// The saved-prompts page inside the composer options popover.
struct DesktopPromptLibraryView: View {
    @Bindable var store: DesktopCodexStore
    let back: () -> Void
    @State private var library = DesktopPromptLibrary.shared
    @State private var error: String?
    @State private var promptToDelete: DesktopSavedPrompt?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: back) {
                HStack(spacing: 9) {
                    Image(systemName: "chevron.left").frame(width: 16)
                    Text("Saved prompts").fontWeight(.semibold)
                    Spacer()
                }
                .font(.system(size: 12.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to composer options")
            .disabled(store.isRestoringPrompt)
            Divider()
            if library.prompts.isEmpty {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "tray").frame(width: 16, height: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No saved prompts").font(.system(size: 12.5, weight: .semibold))
                        Text("Save a draft for later from the previous menu.")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(library.prompts) { prompt in
                            HStack(alignment: .top, spacing: 8) {
                                Button {
                                    Task {
                                        do { try await store.restorePrompt(prompt); back() }
                                        catch { self.error = error.localizedDescription }
                                    }
                                } label: {
                                    HStack(alignment: .top, spacing: 9) {
                                        Image(systemName: "tray.and.arrow.up")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.secondary).frame(width: 16, height: 18)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(prompt.title).font(.system(size: 12.5, weight: .semibold))
                                                .foregroundStyle(.primary).lineLimit(2)
                                            Text(URL(fileURLWithPath: prompt.workspacePath).lastPathComponent
                                                 + (prompt.attachments.isEmpty ? "" : " · \(prompt.attachments.count) attachments"))
                                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Add to draft")
                                .accessibilityLabel("Add to draft: " + prompt.title)
                                Button(role: .destructive) {
                                    promptToDelete = prompt
                                } label: {
                                    Image(systemName: "trash").font(.system(size: 11))
                                        .foregroundStyle(.secondary).padding(4).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).help("Delete saved prompt")
                                .accessibilityLabel("Delete saved prompt: " + prompt.title)
                            }
                            .disabled(store.isRestoringPrompt)
                        }
                    }.padding(.vertical, 2)
                }
                .frame(height: min(CGFloat(library.prompts.count) * 62, 280))
                Divider()
                Text("Choose a prompt to add it to your draft.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if store.isRestoringPrompt { ProgressView().controlSize(.small) }
            if let error { Text(error).foregroundStyle(.red).font(.system(size: 10.5)).textSelection(.enabled) }
        }
        .alert("Delete saved prompt?", isPresented: Binding(
            get: { promptToDelete != nil },
            set: { if !$0 { promptToDelete = nil } }
        ), presenting: promptToDelete) { prompt in
            Button("Delete", role: .destructive) {
                do { try library.remove(prompt) }
                catch { self.error = error.localizedDescription }
                promptToDelete = nil
            }
            Button("Cancel", role: .cancel) { promptToDelete = nil }
        } message: { prompt in
            Text("“\(prompt.title)” and its saved attachments will be deleted. Copies already added to a draft are kept.")
        }
    }
}

struct DesktopQuoteEditor: View {
    @State var excerpt: String
    let cancel: () -> Void
    let add: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quote excerpt").font(.caption.weight(.semibold))
            TextField("Passage to quote", text: $excerpt, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .onExitCommand(perform: cancel)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Insert quote") { add(excerpt) }
                    .disabled(excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
    }
}
