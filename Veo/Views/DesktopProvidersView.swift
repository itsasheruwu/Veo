import SwiftUI

struct DesktopProviderMark: View {
  let id: String?
  var symbol = "network"
  var size: CGFloat = 30

  var body: some View {
    Group {
      if let id, let url = Bundle.main.url(forResource: "AgentMark-" + id, withExtension: "png"),
                let image = NSImage(contentsOf: url) {
        Image(nsImage: image).resizable().scaledToFit().padding(size * 0.18)
          .background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: size * 0.24))
      } else {
        ZStack {
          RoundedRectangle(cornerRadius: size * 0.24).fill(.primary.opacity(0.07))
          if id == "fx" { Text("ƒx").font(.system(size: size * 0.49, weight: .semibold, design: .serif)) }
          else { Image(systemName: symbol).font(.system(size: size * 0.46)) }
        }
      }
    }.frame(width: size, height: size).accessibilityHidden(true)
  }
}

struct ProviderSearchField: View {
  let prompt: String
  @Binding var text: String
  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
      TextField(prompt, text: $text).textFieldStyle(.plain).accessibilityLabel(prompt)
      if !text.isEmpty {
        Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
          .buttonStyle(.plain).accessibilityLabel("Clear search")
      }
    }.padding(.horizontal, 10).frame(height: 33)
      .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
      .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.14)).allowsHitTesting(false) }
  }
}

struct DesktopProvidersView: View {
  @Bindable var store: DesktopCodexStore
  var onboarding = false
  @State private var search = ""
  @State private var registry = false
  @State private var showAPI = false
  @State private var selected: VeoAgent?
  @State private var addAPI = false
  @State private var editAPI: DesktopConnectedProvider?
  @State private var updateMessage: String?

  private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
  private func matches(_ name: String) -> Bool { query.isEmpty || name.localizedCaseInsensitiveContains(query) }
  private var agents: [VeoAgent] {
    let visible = VeoAgent.catalog.filter {
      matches($0.name) && (registry || $0.featured || !query.isEmpty || store.agents.connections[$0.id] != nil)
    }
    return visible.filter { store.agents.connections[$0.id] != nil } + visible.filter { store.agents.connections[$0.id] == nil }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ProviderSearchField(prompt: "Find a provider", text: $search)
      if let updateMessage { Text(updateMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
      let listed = agents
      let api = store.connectedExternalProviders.filter { matches($0.name) }
      if matches("Codex") || !listed.isEmpty {
        SettingsPanel {
          if matches("Codex") {
            row("Codex", detail: "Local Codex CLI", id: "codex") {
              updateButton("codex")
              if onboarding {
                providerAction("Use Codex") {
                  store.agents.choose(nil, thread: nil)
                  store.chooseProvider(nil)
                }
              } else {
                Label(store.runtimeState.isReady ? "Connected" : "Built in",
                      systemImage: store.runtimeState.isReady ? "checkmark.circle" : "internaldrive")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          ForEach(listed) { agent in
            if matches("Codex") || agent.id != listed.first?.id { separator }
            let connection = store.agents.connections[agent.id]
            row(agent.name, detail: connection.map {
              $0.models.isEmpty ? "Agent default model" : "\($0.models.count) available models"
            } ?? (agent.id == "custom-acp" ? "Installed agent" : "Local coding agent"), id: agent.id) {
              if onboarding && connection != nil {
                Button("Use") { store.agents.choose(agent.id, thread: nil); store.chooseProvider(agent.id) }
              }
              updateButton(agent.id)
              providerAction(connection == nil ? "Connect" : "Manage") { selected = agent }
            }
          }
        }
      }
      if query.isEmpty {
        HStack {
          Text("Show all ACP Registry agents").font(.callout)
          Spacer()
          Toggle("Show all ACP Registry agents", isOn: $registry).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.padding(.horizontal, 4)
      }
      if query.isEmpty || !api.isEmpty {
        SettingsPanel {
          HStack {
            if query.isEmpty {
              Button {
                showAPI.toggle()
              } label: {
                HStack(spacing: 8) {
                  Image(systemName: showAPI ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold)).frame(width: 12)
                  Text("API connections").font(.headline)
                }.contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityValue(showAPI ? "Expanded" : "Collapsed")
            } else { Text("API connections").font(.headline) }
            Spacer()
            Button("Add provider…") { addAPI = true }.controlSize(.small)
          }.padding(.horizontal, 12).frame(height: 44)
          if showAPI || !query.isEmpty {
            if api.isEmpty { Divider(); Text("No API providers connected").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
            ForEach(api) { provider in
              separator
              row(provider.name, detail: "\(provider.enabledModels.count) enabled models", id: nil, symbol: provider.preset?.systemImage ?? "network") {
                Menu("Manage") {
                  Button("Edit connection") { editAPI = provider }
                  Button("Disconnect", role: .destructive) { store.removeExternalProvider(provider.id) }
                }.fixedSize()
              }
            }
          }
        }
      } else if !matches("Codex") && listed.isEmpty {
        Text("No matching providers").foregroundStyle(.secondary).padding(.vertical, 12)
      }
    }
    .task(id: store.agents.connections.mapValues(\.executable)) { await store.agents.checkUpdates() }
    .sheet(item: $selected) { AgentSetup(store: store, agent: $0, onboarding: onboarding).tourSheet(onboarding) }
    .sheet(isPresented: $addAPI) { DesktopExternalProviderSheet(store: store).tourSheet(onboarding) }
    .sheet(item: $editAPI) { DesktopExternalProviderSheet(store: store, existing: $0).tourSheet(onboarding) }
  }

  private func providerAction(_ title: String, perform: @escaping () -> Void) -> some View {
    Button(action: perform) { Text(title).lineLimit(1).frame(width: 68) }.buttonStyle(.bordered)
  }

  private func updateButton(_ id: String) -> some View {
    let info = store.agents.updates[id] ?? ProviderUpdateInfo(state: "checking", detail: "Checking the installed version.")
    return providerAction(info.label) {
      updateMessage = nil
      Task {
        if info.state == "retry" { await store.agents.checkUpdates(); return }
        do {
          try await store.agents.update(id)
          updateMessage = store.agents.updates[id]?.detail
          if id == "codex" { updateMessage = (updateMessage ?? "") + " Restart Veo to reload the Codex runtime." }
        } catch { updateMessage = error.localizedDescription }
      }
    }.disabled(!info.actionable || id == "custom-acp").help(info.detail)
    .accessibilityHint(info.detail)
  }
  private var separator: some View { Divider().opacity(0.6).padding(.leading, 55) }

  private func row<Actions: View>(_ name: String, detail: String, id: String?, symbol: String = "command",
                                  @ViewBuilder actions: () -> Actions) -> some View {
    HStack(spacing: 11) {
      DesktopProviderMark(id: id, symbol: symbol)
      VStack(alignment: .leading, spacing: 2) {
        Text(name).font(.system(size: 13, weight: .semibold))
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      actions().controlSize(.small)
    }.padding(.horizontal, 13).frame(minHeight: 49)
  }
}

private struct AgentSetup: View {
  @Bindable var store: DesktopCodexStore
  let agent: VeoAgent
  let onboarding: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var executable = ""
  @State private var arguments = ""
  @State private var status = ""
  @State private var busy = false
  @State private var advanced = false
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) { DesktopProviderMark(id: agent.id, size: 34); Text(agent.name).font(.title2.bold()) }
      Text("Install the agent and sign in, then connect its local ACP executable.").foregroundStyle(
        .secondary)
      if let url = URL(string: agent.site) {
        Link("Installation and sign-in guide ↗", destination: url)
      }
      DisclosureGroup("Executable and arguments", isExpanded: $advanced) {
        VStack(alignment: .leading, spacing: 8) {
          TextField("Executable name or absolute path", text: $executable)
          Text("Arguments · one per line").font(.caption).foregroundStyle(.secondary)
          TextEditor(text: $arguments).font(.body.monospaced()).frame(height: 52)
        }.padding(.top, 6)
      }
      if !status.isEmpty { Text(status).font(.callout).textSelection(.enabled) }
      HStack {
        if store.agents.connections[agent.id] != nil {
          Button("Disconnect", role: .destructive) {
            store.agents.disconnect(agent.id)
            dismiss()
          }
        }
        Spacer()
        Button("Close") { dismiss() }
        let connect = Button(busy ? "Connecting…" : "Connect") {
          busy = true
          status = ""
          Task {
            defer { busy = false }
            do {
              try await store.agents.connect(
                agent, executable: executable,
                args: arguments.split(separator: "\n").map(String.init))
              dismiss()
            } catch { status = error.localizedDescription }
          }
        }.disabled(busy || executable.isEmpty)
        if onboarding { connect.tourButtons(primary: true) } else { connect.buttonStyle(.borderedProminent) }
      }
    }.padding(24).frame(width: 430).interactiveDismissDisabled(busy)
      .onAppear {
        let saved = store.agents.connections[agent.id]
        advanced = saved != nil || agent.command.isEmpty
        executable = saved?.executable ?? agent.command
        arguments = (saved?.args ?? agent.args).joined(separator: "\n")
      }
  }
}

struct DesktopComposerProviderPicker: View {
  @Bindable var store: DesktopCodexStore
  @EnvironmentObject var navigation: DesktopNavigationState
  @State private var open = false
  private struct Selection: Equatable {
    let name: String
    let mark: String?
  }

  var body: some View {
    let selection = Selection(name: store.providerTitle,
                              mark: store.activeAgent ?? (store.selectedModel?.isExternal == true ? nil : "codex"))
    DesktopComposerPickerPill(kind: .provider, value: selection, isOpen: $open,
                              spokenValue: { $0.name }) { displayed in
      DesktopProviderMark(id: displayed.mark, size: 17)
      Text(displayed.name).lineLimit(1)
    }
    .accessibilityLabel("Change provider")
    .popover(isPresented: $open) {
      VStack(alignment: .leading, spacing: 5) {
        Text("Provider").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(
          .horizontal, 6)
        choice("Codex", id: nil)
        ForEach(VeoAgent.catalog.filter { store.agents.connections[$0.id] != nil }) {
          choice($0.name, id: $0.id)
        }
        ForEach(
          store.connectedExternalProviders.filter {
            !$0.enabledModels.isEmpty && store.includeExternalModels
          }
        ) { p in choice(p.name, id: p.id) }
        Divider()
        Button {
          open = false
          navigation.showSettings(.providers)
        } label: {
          Label("Connect a provider…", systemImage: "plus").frame(
            maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain).padding(6)
      }.padding(10).frame(width: 218)
    }
  }
  private func choice(_ name: String, id: String?) -> some View {
    Button {
      store.chooseProvider(id)
      open = false
    } label: {
      HStack(spacing: 8) {
        DesktopProviderMark(id: id ?? "codex", size: 20)
        Text(name)
        Spacer()
        if store.providerTitle == name {
          Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
        }
      }
      .padding(6).contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(store.isBusyTurn)
  }
}

struct DesktopAgentModelPicker: View {
    let agents: DesktopAgentConnections
    let id: String
    let connection: VeoAgentConnection
    @State private var open = false
    @State private var search = ""
    @State private var error: String?
    private struct AgentLabel: Equatable {
        let name: String
        let fast: Bool
    }

    private var efforts: [VeoAgentEffort] { connection.selectedModel?.efforts ?? [] }

    var body: some View {
        let name = connection.selectedModel?.name ?? "Provider default"
        DesktopComposerPickerPill(kind: .model, value: AgentLabel(name: name, fast: connection.usesFastSpeed),
                                 isOpen: $open, spokenValue: { $0.name + ($0.fast ? ", Fast Mode on" : "") }) { displayed in
            Image(systemName: "cube").foregroundStyle(.secondary)
            if displayed.fast {
                Image(systemName: "bolt.fill").foregroundStyle(.yellow).accessibilityHidden(true)
            }
            Text(displayed.name).lineLimit(1)
        }
        .accessibilityLabel("Model settings")
        .onChange(of: open) { _, visible in
            if visible { search = ""; error = nil }
        }
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 8) {
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                if !efforts.isEmpty {
                    Picker("Reasoning effort", selection: Binding(
                        get: { connection.selectedEffort ?? efforts[0].id },
                        set: { agents.setEffort($0, agent: id) }
                    )) {
                        ForEach(efforts) { Text($0.name).tag($0.id) }
                    }
                }
                if connection.supportsFastSpeed {
                    Picker("Speed", selection: Binding(
                        get: { connection.usesFastSpeed },
                        set: { agents.setFastSpeed($0, agent: id) }
                    )) {
                        Text("Standard").tag(false)
                        Text("Fast Mode").tag(true)
                    }
                }
                if !efforts.isEmpty || connection.supportsFastSpeed { Divider() }
                TextField("Find a model", text: $search).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        let options = [VeoAgentModel(id:"",name:"Provider default")] + connection.pickerModels
                        ForEach(options.filter { !connection.hidden.contains($0.id) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { model in
                            Button {
                                agents.setModel(model.id, agent:id)
                                if model.efforts?.isEmpty != false { open = false }
                            } label: {
                                HStack {
                                    Text(model.name).lineLimit(2)
                                    Spacer()
                                    if model.id == connection.pickerModelID { Image(systemName:"checkmark").foregroundStyle(Color.accentColor) }
                                }.padding(6).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(12).frame(width: 300, height: 285)
                .task {
                    guard id == "grok-build", connection.models.allSatisfy({ $0.efforts == nil }) else { return }
                    do { try await agents.refreshModelCatalog(id) }
                    catch { self.error = error.localizedDescription }
                }
        }
    }
}
