import AppKit
import Speech
import SwiftUI

struct DesktopDictationSettingsView: View {
    @AppStorage(DesktopDictationPreferences.model) private var model = DesktopDictationModel.system
    @AppStorage(DesktopDictationPreferences.language) private var language = ""
    @AppStorage(DesktopDictationPreferences.live) private var live = true
    @AppStorage(DesktopDictationPreferences.executable) private var executable = ""
    @AppStorage(DesktopDictationPreferences.whisperLanguage) private var whisperLanguage = ""
    @AppStorage(DesktopDictationPreferences.modelFile) private var modelFile = ""
    @AppStorage(DesktopDictationPreferences.openAIStream) private var openAIStream = true
    @State private var openAIKey = ""
    @State private var keySaved = false
    @State private var keyError: String?

    private let languages = SFSpeechRecognizer.supportedLocales()
        .map(\.identifier)
        .sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }

    var body: some View {
        GroupBox("Composer dictation") {
            VStack(alignment: .leading, spacing: 13) {
                Picker("Transcription model", selection: $model) {
                    ForEach(DesktopDictationModel.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                if model == .system {
                    Picker("Dictation language", selection: $language) {
                        Text("System language").tag("")
                        if !language.isEmpty, !languages.contains(language) {
                            Text(Self.name(language)).tag(language)
                        }
                        ForEach(languages, id: \.self) { Text(Self.name($0)).tag($0) }
                    }
                    Toggle("Show transcription while speaking", isOn: $live)
                } else if model == .whisper {
                    TextField("Whisper language code", text: $whisperLanguage, prompt: Text("Auto-detect"))
                    fileRow("Whisper executable", path: $executable, placeholder: "Use Homebrew installation")
                    fileRow("Whisper model file", path: $modelFile, placeholder: "Choose a ggml model file")
                    Text("Whisper runs after you finish recording. Use a local whisper-cli executable and model.")
                        .foregroundStyle(.secondary)
                } else if model == .openAI {
                    openAISettings
                }
                Divider()
                Text("Click the mic or press ⌘⇧D to start or finish. Press Escape to cancel. Veo inserts the transcript at the cursor.")
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    private var openAISettings: some View {
        VStack(alignment: .leading, spacing: 9) {
            LabeledContent("Connection", value: "API key")
            HStack {
                SecureField(keySaved ? "Replace saved API key" : "OpenAI API key", text: $openAIKey)
                Button("Save key") {
                    if DesktopProviderCredentialStore.setKey(openAIKey, providerID: DesktopOpenAIDictation.credentialID) {
                        keySaved = true
                        openAIKey = ""
                        keyError = nil
                    } else {
                        keyError = "Couldn’t save the API key to Keychain."
                    }
                }
                .disabled(openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if keySaved {
                    Button("Remove key") {
                        if DesktopProviderCredentialStore.deleteKey(providerID: DesktopOpenAIDictation.credentialID) {
                            keySaved = false
                            keyError = nil
                        } else {
                            keyError = "Couldn’t remove the API key from Keychain."
                        }
                    }
                }
            }
            if keySaved { Text("API key saved in Keychain.").foregroundStyle(.secondary) }
            if let keyError { Text(keyError).foregroundStyle(.red) }
            Toggle("Show text as OpenAI transcribes", isOn: $openAIStream)
            Text("After you finish recording, Veo sends the audio to OpenAI for transcription with GPT Transcribe. OpenAI API usage is billed separately.")
                .foregroundStyle(.secondary)
        }
        .onAppear { keySaved = DesktopProviderCredentialStore.hasKey(providerID: DesktopOpenAIDictation.credentialID) }
        .onDisappear { openAIKey = "" }
    }

    private static func name(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private func fileRow(_ label: String, path: Binding<String>, placeholder: String) -> some View {
        HStack {
            TextField(label, text: path, prompt: Text(placeholder))
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.message = label
                panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
            .accessibilityLabel("Choose " + label.lowercased())
        }
    }
}
