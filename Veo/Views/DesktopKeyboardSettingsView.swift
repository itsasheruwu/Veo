import SwiftUI

struct DesktopKeyboardSettingsView: View {
    @State private var preferences = DesktopKeyboardPreferences.shared
    @State private var projects = DesktopProjectPreferences.shared
    @State private var search = ""
    @State private var error: String?

    private var commands: [(id: String, title: String)] {
        var commands = DesktopKeyboardPreferences.commands.map { (id: $0.id, title: $0.title) }
        for (path, configuration) in projects.configurations.sorted(by: { $0.key < $1.key }) {
            commands += configuration.actions.map { (id: "action." + $0.id, title: URL(fileURLWithPath: path).lastPathComponent + " · " + $0.name) }
        }
        return commands.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Search commands", text: $search).textFieldStyle(.roundedBorder)
            Text("Changes apply immediately. Clear the key to remove a shortcut. Project action shortcuts apply in that project's checkout.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(commands, id: \.id) { command in
                HStack {
                    Text(command.title).lineLimit(2)
                    Spacer()
                    Picker("Modifiers", selection: Binding(get: { preferences.binding(for: command.id).modifiers }, set: { modifiers in
                        var binding = preferences.binding(for: command.id); binding.modifiers = modifiers
                        error = preferences.set(binding, for: command.id)
                    })) {
                        Text("⌘").tag("command")
                        Text("⌘⇧").tag("command shift")
                        Text("⌘⌥").tag("command option")
                        Text("⌘⌥⇧").tag("command option shift")
                        if command.id == "terminal" { Text("⌃").tag("control") }
                    }.labelsHidden().frame(width: 100)
                    TextField("Key", text: Binding(get: { preferences.binding(for: command.id).key }, set: { key in
                        var binding = preferences.binding(for: command.id); binding.key = key
                        error = preferences.set(binding, for: command.id)
                    }))
                    .frame(width: 42).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Shortcut key for " + command.title)
                }
                Divider()
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Button("Reset all shortcuts") { preferences.reset(); error = nil }
        }
    }
}
