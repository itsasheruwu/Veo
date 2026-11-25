import SwiftUI

struct DesktopChatMoveSheet: View {
    @Bindable var store: DesktopCodexStore
    let thread: DesktopThread
    @Environment(\.dismiss) private var dismiss
    @State private var choice: String?

    private var moving: Bool { store.movingThreadIDs.contains(thread.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move to project").font(.headline)
            Text("Future turns will run in the selected folder. Your conversation and draft will move with the chat.")
                .font(.subheadline).foregroundStyle(.secondary)
            let paths = store.moveDestinationPaths.filter { $0 != thread.cwd }
            if paths.isEmpty {
                ContentUnavailableView("No other projects", systemImage: "folder", description: Text("Open a project in Veo to add a destination."))
            } else {
                List(paths, id: \.self, selection: $choice) { path in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.body.weight(.medium))
                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .tag(path)
                }
                .frame(minHeight: 152)
                .accessibilityLabel("Destination project")
            }
            if let error = store.moveThreadError {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(moving)
                Button(moving ? "Moving…" : "Move chat") {
                    guard let choice else { return }
                    Task { await store.moveChat(thread, to: choice) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(choice == nil || moving)
            }
        }
        .padding(20)
        .frame(width: 444)
        .interactiveDismissDisabled(moving)
    }
}
