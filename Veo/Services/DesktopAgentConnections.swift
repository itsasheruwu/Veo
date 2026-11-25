import AppKit
import Foundation
import Observation

struct VeoAgent: Identifiable, Decodable {
  let id, name, command, site: String
  let args: [String]
  let featured: Bool
  static let catalog: [VeoAgent] = {
    let bundled =
      Bundle.main.url(forResource: "VeoAgents", withExtension: "json")
      .flatMap { try? Data(contentsOf: $0) }
      .flatMap { try? JSONDecoder().decode([VeoAgent].self, from: $0) } ?? []
    return bundled + [
      VeoAgent(
        id: "custom-acp", name: "Local ACP command", command: "",
        site: "https://agentclientprotocol.com", args: [], featured: false)
    ]
  }()
}

struct VeoAgentModel: Codable, Identifiable, Hashable {
  let id, name: String
  var efforts: [VeoAgentEffort]? = nil
  var defaultEffort: String? = nil
}
struct VeoAgentEffort: Codable, Identifiable, Hashable {
  let id, name: String
}
struct VeoAgentConnection: Codable {
  let executable: String
  let args: [String]
  var models: [VeoAgentModel]
  var model: String
  var hidden: Set<String> = []
  var effortChoices: [String: String]? = nil

  private static let grokStandardID = "grok-4.7"
  private static let grokFastID = "grok-4.7-build-fast"

  private var grokFastModel: VeoAgentModel? {
    guard models.contains(where: { $0.id == Self.grokStandardID }) else { return nil }
    return models.first { $0.id == Self.grokFastID }
  }
  var pickerModels: [VeoAgentModel] {
    let companionID = grokFastModel?.id
    return models.filter { $0.id != companionID }
  }
  var pickerModelID: String {
    model == grokFastModel?.id ? Self.grokStandardID : model
  }
  var selectedModel: VeoAgentModel? { models.first { $0.id == pickerModelID } }
  var supportsFastSpeed: Bool { pickerModelID == Self.grokStandardID && grokFastModel != nil }
  var usesFastSpeed: Bool { supportsFastSpeed && model == Self.grokFastID }
  var savedEffort: String? {
    effortChoices?[pickerModelID] ?? (supportsFastSpeed ? effortChoices?[Self.grokFastID] : nil)
  }
  var selectedEffort: String? { savedEffort ?? selectedModel?.defaultEffort }

  mutating func setFastSpeed(_ enabled: Bool) {
    guard supportsFastSpeed else { return }
    model = enabled ? Self.grokFastID : Self.grokStandardID
  }

  mutating func reconcileModel() {
    if model == Self.grokFastID, grokFastModel == nil,
       models.contains(where: { $0.id == Self.grokStandardID }) {
      model = Self.grokStandardID
    }
    if !model.isEmpty && (selectedModel == nil || hidden.contains(pickerModelID)) {
      model = ""
    }
  }

}
struct ProviderUpdateInfo: Codable {
  var state: String
  var detail: String
  var label: String {
    switch state {
    case "current": "Up to date"
    case "missing": "Not installed"
    case "install": "Install"
    case "installing": "Installing…"
    case "available": "Update"
    case "manual": "Unavailable"
    case "updating": "Updating…"
    case "retry": "Retry"
    default: "Checking…"
    }
  }
  var actionable: Bool { ["install", "available", "retry"].contains(state) }
}

@MainActor @Observable
final class DesktopAgentConnections {
  private(set) var connections: [String: VeoAgentConnection] = {
    guard let data = UserDefaults.standard.data(forKey: "Veo.agentConnections") else { return [:] }
    return (try? JSONDecoder().decode([String: VeoAgentConnection].self, from: data)) ?? [:]
  }()
  {
    didSet {
      if let data = try? JSONEncoder().encode(connections) {
        UserDefaults.standard.set(data, forKey: "Veo.agentConnections")
      }
    }
  }
  private var choices =
    UserDefaults.standard.dictionary(forKey: "Veo.agentChoices") as? [String: String] ?? [:]
  private var processes: [String: Process] = [:]
  var running: Set<String> = []
  private(set) var updates: [String: ProviderUpdateInfo] = [:]
  private var updating: Set<String> = []
  private var checkGeneration = 0

  func checkUpdates() async {
    checkGeneration += 1
    let generation = checkGeneration
    do {
      let result = try await run(["action": "checkProviderUpdates", "executables": connections.mapValues(\.executable), "stateRoot": try agentStateRoot().path], key: UUID().uuidString)
      let data = try JSONSerialization.data(withJSONObject: result["updates"] ?? [:])
      let checked = try JSONDecoder().decode([String: ProviderUpdateInfo].self, from: data)
      guard generation == checkGeneration else { return }
      updates.merge(checked.filter { !updating.contains($0.key) }) { _, new in new }
    } catch {
      guard generation == checkGeneration else { return }
      for id in ["codex"] + VeoAgent.catalog.map(\.id) where !updating.contains(id) {
        updates[id] = ProviderUpdateInfo(state: "retry", detail: error.localizedDescription)
      }
    }
  }

  func update(_ id: String) async throws {
    guard updating.insert(id).inserted else { return }
    let installing = updates[id]?.state == "install"
    updates[id] = ProviderUpdateInfo(
      state: installing ? "installing" : "updating",
      detail: installing ? "Installing the provider in Veo." : "Updating the installed provider."
    )
    do {
      _ = try await run(["action": "updateProvider", "provider": id, "executables": connections.mapValues(\.executable), "stateRoot": try agentStateRoot().path], key: UUID().uuidString)
    } catch {
      updating.remove(id)
      await checkUpdates()
      throw error
    }
    updating.remove(id)
    await checkUpdates()
  }
  func choice(_ thread: String?) -> String? {
    choices[thread ?? "default"].flatMap { connections[$0] == nil ? nil : $0 }
  }
  func choose(_ agent: String?, thread: String?) {
    choices[thread ?? "default"] = agent
    UserDefaults.standard.set(choices, forKey: "Veo.agentChoices")
  }
  func setModel(_ model: String, agent: String) {
    guard var connection = connections[agent], connection.pickerModelID != model,
          model.isEmpty || connection.pickerModels.contains(where: { $0.id == model && !connection.hidden.contains($0.id) }) else { return }
    connection.model = model
    connections[agent] = connection
  }

  func setFastSpeed(_ enabled: Bool, agent: String) {
    connections[agent]?.setFastSpeed(enabled)
  }
  func setEffort(_ effort: String, agent: String) {
    guard var connection = connections[agent], connection.selectedModel?.efforts?.contains(where: { $0.id == effort }) == true else { return }
    var choices = connection.effortChoices ?? [:]
    choices[connection.pickerModelID] = effort
    connection.effortChoices = choices
    connections[agent] = connection
  }

  func refreshModelCatalog(_ id: String) async throws {
    guard let saved = connections[id] else { return }
    let result = try await modelCatalog(id: id, executable: saved.executable, args: saved.args, action: "models", model: saved.model)
    guard var current = connections[id], current.executable == saved.executable, current.args == saved.args else { return }
    let known = Dictionary(current.models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    current.models = result.models.map { model in
      model.efforts == nil && known[model.id]?.efforts != nil ? (known[model.id] ?? model) : model
    }
    current.reconcileModel()
    connections[id] = current
  }

  func toggle(_ model: String, agent: String, enabled: Bool) {
    guard var c = connections[agent] else { return }
    if enabled {
      c.hidden.remove(model)
    } else {
      guard c.pickerModels.filter({ !c.hidden.contains($0.id) }).count > 1 else { return }
      c.hidden.insert(model)
      if c.pickerModelID == model {
        c.model = c.pickerModels.first(where: { !c.hidden.contains($0.id) })?.id ?? ""
      }
    }
    connections[agent] = c
  }
  func disconnect(_ id: String) { connections[id] = nil }
  func stop(_ thread: String) { processes[thread]?.terminate() }

  func connect(_ agent: VeoAgent, executable: String, args: [String]) async throws {
    let result = try await modelCatalog(id: agent.id, executable: executable, args: args, action: "connect")
    let previous = connections[agent.id]
    let hidden = previous?.hidden.intersection(result.models.map(\.id)) ?? []
    let choice = previous?.model ?? result.current
    var connection = VeoAgentConnection(
      executable: executable, args: args, models: result.models, model: choice,
      hidden: hidden, effortChoices: previous?.effortChoices)
    connection.reconcileModel()
    connections[agent.id] = connection
  }

  private func modelCatalog(id: String, executable: String, args: [String], action: String, model: String = "") async throws
    -> (models: [VeoAgentModel], current: String)
  {
    let state = try stateDirectory(id)
    let result = try await run([
      "action": action, "provider": id, "executable": executable, "args": args,
      "cwd": state.path, "state": state.path, "access": "readOnly", "model": model,
    ], key: UUID().uuidString)
    let data = try JSONSerialization.data(withJSONObject: result["models"] ?? [])
    return (try JSONDecoder().decode([VeoAgentModel].self, from: data), result["current"] as? String ?? "")
  }
  func turn(
    agent: String, thread: String, cwd: String, text: String, history: [[String: String]],
    access: DesktopAccessMode,
    delta: @escaping (String) -> Void
  ) async throws -> String {
    guard let c = connections[agent], !running.contains(thread) else {
      throw failure("Provider unavailable or busy.")
    }
    running.insert(thread)
    defer { running.remove(thread) }
    let result = try await run(
      [
        "action": "turn", "thread": thread, "provider": agent, "executable": c.executable,
        "args": c.args,
        "cwd": cwd, "state": try stateDirectory(agent).path, "model": c.model, "text": text,
        "history": history, "access": access.rawValue, "effort": c.savedEffort ?? "",
      ], key: thread, delta: delta)
    return result["text"] as? String ?? ""
  }
  private func agentStateRoot() throws -> URL {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return root.appendingPathComponent("com.ash.Veo/AgentState")
  }
  private func stateDirectory(_ id: String) throws -> URL {
    let url = try agentStateRoot().appendingPathComponent(id)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private func failure(_ message: String) -> NSError {
    NSError(domain: "Veo.Providers", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  private func run(_ request: [String: Any], key: String, delta: (String) -> Void = { _ in })
    async throws -> [String: Any]
  {
    let env = ProcessInfo.processInfo.environment
    let dirs =
      (env["PATH"] ?? "").split(separator: ":").map(String.init) + [
        "/opt/homebrew/bin", "/opt/homebrew/opt/node@24/bin", "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
      ]
    guard
      let node = dirs.map({ URL(fileURLWithPath: $0).appendingPathComponent("node") }).first(
        where: { FileManager.default.isExecutableFile(atPath: $0.path) }),
      let script = Bundle.main.url(forResource: "veo-agent", withExtension: "cjs")
    else { throw failure("Install Node.js to manage local providers.") }
    let codex = CodexAppServerClient.resolveCodexExecutable()
    let action = request["action"] as? String
    if codex == nil && (action == "turn" || action == "connect" || action == "models") {
      throw failure("Install Codex CLI for workspace sandboxing.")
    }
    let task = Process()
    let input = Pipe()
    let output = Pipe()
    task.executableURL = node
    task.arguments = [script.path]
    var environment = env
    environment["PATH"] = dirs.joined(separator: ":")
    environment["CODEX_EXECUTABLE"] = codex?.path
    task.environment = environment
    task.standardInput = input
    task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    try task.run()
    processes[key] = task
    defer {
      processes[key] = nil
      try? input.fileHandleForWriting.close()
      if task.isRunning { task.terminate() }
    }
    func write(_ object: [String: Any]) throws {
      try input.fileHandleForWriting.write(
        contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
    }
    try write(request)
    for try await line in output.fileHandleForReading.bytes.lines {
      guard let message = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      else { continue }
      if let error = message["error"] as? String { throw failure(error) }
      if let text = message["delta"] as? String { delta(text) }
      if let permission = message["permission"] as? String {
        let alert = NSAlert()
        alert.messageText = "Allow this provider action?"
        alert.informativeText = message["title"] as? String ?? ""
        alert.addButton(withTitle: "Decline")
        alert.addButton(withTitle: "Allow once")
        try write(["permission": permission, "allow": alert.runModal() == .alertSecondButtonReturn])
      }
      if message["done"] as? Bool == true || message["connected"] as? Bool == true {
        return message
      }
    }
    throw failure("The provider stopped before completing the request.")
  }
}
