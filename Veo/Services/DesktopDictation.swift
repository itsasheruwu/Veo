import AVFoundation
import Foundation
import Speech

enum DesktopDictationModel: String, CaseIterable, Identifiable {
    case system = "Apple Speech"
    case whisper = "Whisper (local)"
    case openAI = "OpenAI"

    var id: Self { self }
}

enum DesktopDictationPreferences {
    static let model = "Veo.dictation.model"
    static let language = "Veo.dictation.language"
    static let live = "Veo.dictation.live"
    static let executable = "Veo.dictation.whisperExecutable"
    static let whisperLanguage = "Veo.dictation.whisperLanguage"
    static let modelFile = "Veo.dictation.whisperModel"
    static let openAIStream = "Veo.dictation.openAIStream"
}

struct DesktopDictationDraft {
    let context: String
    let text: String
    let selection: NSRange

    func inserting(_ spoken: String, forDisplay: Bool = false) -> (text: String, start: Int, end: Int) {
        let source = text as NSString
        let before = source.substring(to: selection.location)
        let after = source.substring(from: NSMaxRange(selection))
        let leading = before.last.map { !$0.isWhitespace && !"([{".contains($0) } == true ? " " : ""
        let trailing = after.first.map { !$0.isWhitespace && !".,!?;:)]}".contains($0) } == true ? " " : ""
        let prefix = (forDisplay ? DesktopInlineContext.displayText(before) : before) + leading
        let suffix = trailing + (forDisplay ? DesktopInlineContext.displayText(after) : after)
        let start = prefix.utf16.count
        return (prefix + spoken + suffix, start, start + spoken.utf16.count)
    }
}

@MainActor
@Observable
final class DesktopDictation {
    enum Phase { case idle, preparing, listening, transcribing, revealing }

    private(set) var phase = Phase.idle
    private(set) var transcript = ""
    private(set) var error: String?
    private(set) var started = Date()
    private(set) var isBatch = false
    private(set) var revealStarted = Date()
    private(set) var level = DesktopDictationLevel()

    private var operation: UUID?
    private var engine: AVAudioEngine?
    private var recognition: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recording: DesktopDictationRecording?
    private var whisper: DesktopWhisperConfiguration?
    private var openAIKey: String?
    private var upload: Task<Void, Never>?
    private var worker: Process?
    private var deadline: Task<Void, Never>?
    private var deviceChanges: (any NSObjectProtocol)?
    private var onResult: ((String) -> Void)?
    private var latestSpeech = ""

    var isActive: Bool { phase != .idle }
    var canFinish: Bool { phase == .listening }

    func start(defaults: UserDefaults = .standard, onResult: @escaping (String) -> Void) async {
        guard !isActive else { return }
        let id = UUID()
        operation = id
        error = nil
        transcript = ""
        latestSpeech = ""
        level = DesktopDictationLevel()
        phase = .preparing
        self.onResult = onResult
        let model = DesktopDictationModel(rawValue: defaults.string(forKey: DesktopDictationPreferences.model) ?? "") ?? .system
        let language = defaults.string(forKey: DesktopDictationPreferences.language)?.trimmingCharacters(in: .whitespaces) ?? ""
        switch model {
        case .system: isBatch = defaults.object(forKey: DesktopDictationPreferences.live) as? Bool == false
        case .whisper: isBatch = true
        case .openAI: isBatch = defaults.object(forKey: DesktopDictationPreferences.openAIStream) as? Bool == false
        }

        do {
            if model == .whisper {
                let code = defaults.string(forKey: DesktopDictationPreferences.whisperLanguage)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                whisper = try DesktopWhisperConfiguration(defaults: defaults, language: code)
            } else if model == .openAI {
                guard let key = DesktopProviderCredentialStore.key(providerID: DesktopOpenAIDictation.credentialID) else {
                    throw Failure("Save an OpenAI API key in Voice settings to use OpenAI dictation.")
                }
                openAIKey = key
            } else {
                let authorization = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                }
                guard operation == id else { return }
                guard authorization == .authorized else {
                    throw Failure("Allow Speech Recognition for Veo in System Settings → Privacy & Security.")
                }
                let locale = language.isEmpty ? Locale.current : Locale(identifier: language)
                guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
                    throw Failure("Apple Speech has no on-device model for this language. Choose another language in Voice settings.")
                }
                guard recognizer.isAvailable else { throw Failure("Apple Speech is temporarily unavailable.") }
                self.recognizer = recognizer
            }

            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard operation == id else { return }
            guard allowed else { throw Failure("Allow Microphone access for Veo in System Settings → Privacy & Security.") }

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else { throw Failure("Connect an available microphone and try again.") }

            let recording = model == .system ? nil : try DesktopDictationRecording(source: format)
            self.recording = recording
            let request = recognizer.map { _ in SFSpeechAudioBufferRecognitionRequest() }
            request?.requiresOnDeviceRecognition = true
            request?.shouldReportPartialResults = !isBatch
            request?.taskHint = .dictation
            request?.addsPunctuation = true
            self.request = request
            let meter = level
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                meter.update(buffer)
                request?.append(buffer)
                recording?.append(buffer)
            }
            self.engine = engine
            deviceChanges = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard self?.operation == id, self?.phase == .listening else { return }
                    self?.fail("The microphone changed during dictation. Start a new recording.")
                }
            }
            try engine.start()
            started = Date()
            phase = .listening
            if let request, let recognizer {
                recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    let text = result?.bestTranscription.formattedString
                    let final = result?.isFinal == true
                    let failed = error != nil
                    Task { @MainActor in
                        guard let self, self.operation == id else { return }
                        if let text {
                            self.latestSpeech = text
                            if !self.isBatch { self.transcript = text }
                        }
                        if final {
                            self.complete(self.latestSpeech)
                        } else if failed {
                            if self.phase == .transcribing, !self.latestSpeech.isEmpty {
                                self.complete(self.latestSpeech)
                            } else {
                                self.fail("Apple Speech couldn’t finish dictation. Check the selected language and try again.")
                            }
                        }
                    }
                }
            }
            scheduleDeadline(60) { [weak self] in self?.finish() }
        } catch {
            guard operation == id else { return }
            fail(error.localizedDescription)
        }
    }

    func finish() {
        guard phase == .listening else { return }
        phase = .transcribing
        stopMicrophone()
        if let recording {
            guard let id = operation else { return }
            do {
                let audio = try recording.finishedAudio()
                if let key = openAIKey {
                    openAIKey = nil
                    let stream = !isBatch
                    upload = Task { [weak self] in
                        do {
                            let result = try await DesktopOpenAIDictation.transcribe(audio, key: key, stream: stream) { partial in
                                guard let self, self.operation == id else { return }
                                self.transcript = partial
                            }
                            guard let self, self.operation == id else { return }
                            self.upload = nil
                            recording.remove()
                            self.recording = nil
                            self.complete(result)
                        } catch {
                            guard let self, self.operation == id else { return }
                            self.fail(error.localizedDescription)
                        }
                    }
                    scheduleDeadline(120) { [weak self] in self?.fail("OpenAI transcription timed out.") }
                    return
                }
                guard let whisper else { throw Failure("Choose a transcription model in Voice settings.") }
                let process = recording.makeProcess(whisper, audio: audio)
                process.terminationHandler = { [weak self, recording] process in
                    let text = process.terminationStatus == 0 ? recording.readResult() : nil
                    recording.remove()
                    Task { @MainActor in
                        guard let self, self.operation == id else { return }
                        self.worker = nil
                        self.recording = nil
                        if let text { self.complete(text) }
                        else { self.fail("Whisper couldn’t transcribe the recording. Check the executable, model and language in Voice settings.") }
                    }
                }
                try process.run()
                worker = process
                scheduleDeadline(120) { [weak self] in self?.fail("Whisper timed out.") }
            } catch {
                fail(error.localizedDescription)
            }
        } else {
            request?.endAudio()
            recognition?.finish()
            scheduleDeadline(12) { [weak self] in
                guard let self else { return }
                if self.latestSpeech.isEmpty { self.fail("No speech was transcribed.") }
                else { self.complete(self.latestSpeech) }
            }
        }
    }

    func cancel() {
        operation = nil
        deadline?.cancel()
        deadline = nil
        upload?.cancel()
        upload = nil
        openAIKey = nil
        whisper = nil
        stopMicrophone()
        recognition?.cancel()
        recognition = nil
        recognizer = nil
        request = nil
        if let worker {
            if worker.isRunning { worker.terminate() }
        } else {
            recording?.remove()
        }
        worker = nil
        recording = nil
        onResult = nil
        phase = .idle
        transcript = ""
        error = nil
    }

    func commitResult() {
        guard phase == .revealing else { return }
        let result = transcript
        let callback = onResult
        cancel()
        callback?(result)
    }

    private func complete(_ text: String) {
        guard phase == .listening || phase == .transcribing else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { fail("No speech was transcribed."); return }
        stopMicrophone()
        transcript = text
        revealStarted = Date()
        phase = .revealing
        deadline?.cancel()
    }

    private func fail(_ message: String) {
        cancel()
        error = message
    }

    private func stopMicrophone() {
        if let deviceChanges {
            NotificationCenter.default.removeObserver(deviceChanges)
            self.deviceChanges = nil
        }
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    private func scheduleDeadline(_ seconds: Int, _ action: @escaping @MainActor () -> Void) {
        deadline?.cancel()
        deadline = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            action()
        }
    }

    fileprivate struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

final class DesktopDictationLevel: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0

    func read() -> Double { lock.withLock { value } }

    func update(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?.pointee, buffer.frameLength > 0 else { return }
        var square: Float = 0
        for index in 0..<Int(buffer.frameLength) { square += samples[index] * samples[index] }
        let rms = sqrt(Double(square) / Double(buffer.frameLength))
        let level = max(0, min(1, (20 * log10(max(0.00001, rms)) + 52) / 36))
        lock.withLock { value = value * 0.62 + level * 0.38 }
    }
}

private struct DesktopWhisperConfiguration {
    let executable: URL
    let model: URL
    let language: String

    init(defaults: UserDefaults, language: String) throws {
        let files = FileManager.default
        let path = defaults.string(forKey: DesktopDictationPreferences.executable) ?? ""
        let candidates = path.isEmpty ? ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"] : [path]
        guard let executable = candidates.first(where: files.isExecutableFile(atPath:)) else {
            throw DesktopDictation.Failure("Choose a whisper-cli executable in Voice settings.")
        }
        let model = defaults.string(forKey: DesktopDictationPreferences.modelFile) ?? ""
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: model, isDirectory: &isDirectory), !isDirectory.boolValue, files.isReadableFile(atPath: model) else {
            throw DesktopDictation.Failure("Choose a readable Whisper model file in Voice settings.")
        }
        self.executable = URL(fileURLWithPath: executable)
        self.model = URL(fileURLWithPath: model)
        self.language = language.isEmpty ? "auto" : Locale(identifier: language).language.languageCode?.identifier ?? language
    }
}

private final class DesktopDictationRecording: @unchecked Sendable {
    private let folder: URL
    private let converter: AVAudioConverter
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var failed = false

    init(source: AVAudioFormat) throws {
        guard let destination = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let converter = AVAudioConverter(from: source, to: destination),
              let buffer = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: 8192) else {
            throw DesktopDictation.Failure("The microphone format couldn’t be converted for dictation.")
        }
        self.converter = converter
        self.buffer = buffer
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("veo-dictation-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            file = try AVAudioFile(
                forWriting: folder.appendingPathComponent("speech.wav"),
                settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func append(_ input: AVAudioPCMBuffer) {
        lock.withLock {
            guard let file, !failed else { return }
            var used = false
            var error: NSError?
            buffer.frameLength = 0
            let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
                inputStatus.pointee = used ? .noDataNow : .haveData
                if used { return nil }
                used = true
                return input
            }
            if status == .error { failed = true; return }
            do { if buffer.frameLength > 0 { try file.write(from: buffer) } }
            catch { failed = true }
        }
    }

    func finishedAudio() throws -> URL {
        try lock.withLock {
            guard let frames = file?.length, frames >= 1600, !failed else {
                throw DesktopDictation.Failure("No usable microphone audio was recorded.")
            }
            file = nil
        }
        return folder.appendingPathComponent("speech.wav")
    }

    func makeProcess(_ configuration: DesktopWhisperConfiguration, audio: URL) -> Process {
        let process = Process()
        process.executableURL = configuration.executable
        process.arguments = ["-m", configuration.model.path, "-l", configuration.language,
                             "-f", audio.path,
                             "-otxt", "-of", folder.appendingPathComponent("transcript").path, "-np"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    func readResult() -> String? {
        try? String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8)
    }

    func remove() {
        lock.withLock { file = nil }
        try? FileManager.default.removeItem(at: folder)
    }
}
