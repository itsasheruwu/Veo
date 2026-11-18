import SwiftUI

struct DesktopProjectSettingsView: View {
    @Bindable var store: DesktopCodexStore
    @State private var preferences = DesktopProjectPreferences.shared
    @State private var selectedPath = ""
    @State private var editingAction: DesktopProjectAction?

    private var projects: [String] {
        var paths = Set(store.threads.filter { $0.workspaceKind == .project }.map { preferences.projectPath(for: $0.cwd) })
        paths.formUnion(preferences.configurations.keys)
        if store.currentWorkspaceKind == .project { paths.insert(preferences.projectPath(for: store.effectiveWorkspaceURL.path)) }
        return paths.sorted()
    }
    private var path: String { selectedPath.isEmpty ? projects.first ?? "" : selectedPath }
    private var configuration: DesktopProjectConfiguration { preferences.configuration(for: path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if projects.isEmpty {
                ContentUnavailableView("No projects yet", systemImage: "folder", description: Text("Open a project to configure its actions and defaults."))
            } else {
                Picker("Project", selection: Binding(get: { path }, set: { selectedPath = $0 })) {
                    ForEach(projects, id: \.self) { Text(URL(fileURLWithPath: $0).lastPathComponent).tag($0) }
                }
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                GroupBox("New chat defaults") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Model", selection: Binding(get: { configuration.modelID ?? "" }, set: { value in
                            update { $0.modelID = value.isEmpty ? nil : value; $0.reasoningEffort = nil }
                        })) {
                            Text("Use global default").tag("")
                            if let id = configuration.modelID,
                               store.models.contains(where: { $0.id == id && $0.isStandaloneDaybreakModel }) {
                                Text("Previously saved model").tag(id).disabled(true)
                            }
                            ForEach(store.selectableModels) { Text($0.userFacingDisplayName).tag($0.id) }
                        }
                        Picker("Reasoning", selection: Binding(get: { configuration.reasoningEffort ?? "" }, set: { value in
                            update { $0.reasoningEffort = value.isEmpty ? nil : value }
                        })) {
                            Text("Use model default").tag("")
                            ForEach((store.visibleModels.first(where: { $0.id == configuration.modelID }) ?? store.models.first(where: { $0.id == configuration.modelID }))?.supportedReasoningEfforts ?? []) {
                                Text($0.id.capitalized).tag($0.id)
                            }
                        }
                        .disabled(configuration.modelID == nil)
                        Toggle("Offer a new worktree when starting a project chat", isOn: Binding(get: { configuration.usesWorktree }, set: { value in update { $0.usesWorktree = value } }))
                        Toggle("Save workspace checkpoints before turns", isOn: Binding(get: { configuration.checkpointsEnabled ?? true }, set: { value in update { $0.checkpointsEnabled = value } }))
                        Text("Checkpoints include tracked and nonignored files. Available with paginated Codex history; ignored files are left alone.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Reset defaults") { preferences.resetDefaults(for: path) }
                            .controlSize(.small)
                        Text("Applies to new chats. Existing chats keep their selections and access permissions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                        .accessibilityElement(children: .contain)
                }
                GroupBox("Actions") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(configuration.actions) { action in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(action.name).fontWeight(.medium)
                                    Text(action.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                                    if action.runOnWorktreeCreate { Text("Worktree setup").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Button("Edit") { editingAction = action }.controlSize(.small)
                                Button("Delete", role: .destructive) { update { $0.actions.removeAll { $0.id == action.id } } }.controlSize(.small)
                            }
                            Divider()
                        }
                        Button("Add action…", systemImage: "plus") {
                            editingAction = DesktopProjectAction(name: "", command: "")
                        }
                        Text("Actions run in a new terminal in this project's checkout. Setup actions are offered when a worktree is created.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                        .accessibilityElement(children: .contain)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear { if store.currentWorkspaceKind == .project { selectedPath = preferences.projectPath(for: store.effectiveWorkspaceURL.path) } }
        .sheet(item: $editingAction) { action in
            DesktopProjectActionEditor(action: action) { updated in
                update { config in
                    if let index = config.actions.firstIndex(where: { $0.id == updated.id }) { config.actions[index] = updated }
                    else { config.actions.append(updated) }
                }
            }
        }
    }

    private func update(_ edit: (inout DesktopProjectConfiguration) -> Void) {
        var value = configuration
        edit(&value)
        preferences.set(value, for: path)
    }
}

private struct DesktopProjectActionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var action: DesktopProjectAction
    let save: (DesktopProjectAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Project action").font(.headline)
            TextField("Name", text: $action.name)
            TextField("Shell command", text: $action.command, axis: .vertical)
                .font(.body.monospaced()).lineLimit(3...6)
            if action.command.utf8.count > 32_768 { Text("Keep actions under 32 KB. Put a longer script in the project and run its path here.").font(.caption).foregroundStyle(.red) }
            Toggle("Offer as setup for new worktrees", isOn: $action.runOnWorktreeCreate)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    action.name = action.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    action.command = action.command.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(action); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(action.command.utf8.count > 32_768 || action.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || action.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || action.command.unicodeScalars.contains { $0.value < 32 && $0 != "\n" && $0 != "\t" })
            }
        }.padding(24).frame(width: 450)
    }
}

struct DesktopProjectActionsMenu: View {
    let path: String
    let enabled: Bool
    let run: (DesktopProjectAction) -> Void
    let configure: () -> Void
    @State private var preferences = DesktopProjectPreferences.shared

    var body: some View {
        Menu {
            ForEach(preferences.configuration(for: path).actions) { action in
                Button(action.name) { run(action) }
                    .keyboardShortcut(DesktopKeyboardPreferences.shared.shortcut(for: "action." + action.id))
            }
            Divider()
            Button("Configure actions…", action: configure)
        } label: {
            Label("Project actions", systemImage: "play")
        }
        .disabled(!enabled)
        .help("Run a project action")
    }
}
