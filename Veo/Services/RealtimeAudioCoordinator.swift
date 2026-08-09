// FILE: RealtimeAudioCoordinator.swift
// Purpose: Owns opt-in microphone capture and bounded PCM playback for Codex realtime sessions.
// Layer: Desktop app service
// Depends on: AVFoundation, Combine, Foundation

@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class RealtimeAudioCoordinator: ObservableObject {
    nonisolated static let captureSampleRate = 24_000
    nonisolated static let captureChannelCount = 1

    enum MicrophonePermissionState: Equatable {
        case notDetermined
        case requesting
        case granted
        case denied
    }

    enum CaptureState: Equatable {
        case stopped
        case starting
        case capturing
        case interrupted
    }

    enum PlaybackState: Equatable {
        case stopped
        case starting
        case playing
        case interrupted
    }

    struct PCMChunk: Equatable, Sendable {
        let data: String
        let sampleRate: Int
        let numChannels: Int
        let samplesPerChannel: Int
    }

    typealias CaptureHandler = @MainActor (PCMChunk) -> Void
    typealias ErrorHandler = @MainActor (String) -> Void

    @Published private(set) var microphonePermission: MicrophonePermissionState
    @Published private(set) var captureState: CaptureState = .stopped
    @Published private(set) var playbackState: PlaybackState = .stopped
    @Published private(set) var bufferedPlaybackDuration: TimeInterval = 0
    @Published private(set) var lastError: String?

    var captureHandler: CaptureHandler?
    var errorHandler: ErrorHandler?

    var isCapturing: Bool { captureState == .capturing }
    var isPlaying: Bool { playbackState == .playing }

    private struct PlaybackItem {
        let buffer: AVAudioPCMBuffer
        let duration: TimeInterval
    }

    private let captureEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let playbackNode = AVAudioPlayerNode()
    private let captureConverter = CaptureConverter()
    private let captureDeliveryBuffer = CaptureDeliveryBuffer(maximumChunkCount: 8)
    private let playbackFormat: AVAudioFormat
    private let maximumBufferedPlaybackDuration: TimeInterval
    private let maximumPlaybackQueueCount = 64
    private let maximumEncodedPlaybackByteCount = 4 * 1_024 * 1_024

    private var captureConfigurationObserver: NSObjectProtocol?
    private var playbackConfigurationObserver: NSObjectProtocol?
    private var captureTapIsInstalled = false
    private var captureWasRequested = false
    private var captureGeneration = UUID()
    private var playbackGeneration = UUID()
    private var playbackQueue: [PlaybackItem] = []
    private var currentPlaybackItem: PlaybackItem?

    init(
        maximumBufferedPlaybackDuration: TimeInterval = 5,
        captureHandler: CaptureHandler? = nil,
        errorHandler: ErrorHandler? = nil
    ) {
        guard let playbackFormat = AVAudioFormat(
            standardFormatWithSampleRate: Double(Self.captureSampleRate),
            channels: AVAudioChannelCount(Self.captureChannelCount)
        ) else {
            preconditionFailure("Veo could not create its realtime playback format.")
        }

        self.playbackFormat = playbackFormat
        self.maximumBufferedPlaybackDuration = max(0.25, maximumBufferedPlaybackDuration)
        self.captureHandler = captureHandler
        self.errorHandler = errorHandler
        microphonePermission = Self.currentMicrophonePermission()

        playbackEngine.attach(playbackNode)
        playbackEngine.connect(playbackNode, to: playbackEngine.mainMixerNode, format: playbackFormat)

        let center = NotificationCenter.default
        captureConfigurationObserver = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: captureEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleCaptureConfigurationChange()
            }
        }
        playbackConfigurationObserver = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: playbackEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackConfigurationChange()
            }
        }
    }

    deinit {
        if let captureConfigurationObserver {
            NotificationCenter.default.removeObserver(captureConfigurationObserver)
        }
        if let playbackConfigurationObserver {
            NotificationCenter.default.removeObserver(playbackConfigurationObserver)
        }

        if captureTapIsInstalled {
            captureEngine.inputNode.removeTap(onBus: 0)
        }
        captureEngine.stop()
        playbackNode.stop()
        playbackEngine.stop()
    }

    func refreshMicrophonePermission() {
        guard microphonePermission != .requesting else { return }
        microphonePermission = Self.currentMicrophonePermission()
    }

    @discardableResult
    func requestMicrophonePermission() async -> Bool {
        refreshMicrophonePermission()

        switch microphonePermission {
        case .granted:
            return true
        case .denied:
            return false
        case .requesting:
            return false
        case .notDetermined:
            break
        }

        microphonePermission = .requesting
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        microphonePermission = granted ? .granted : .denied
        return granted
    }

    @discardableResult
    func startCapture() async -> Bool {
        clearError()

        guard captureState != .capturing else { return true }
        guard await requestMicrophonePermission() else {
            captureWasRequested = false
            reportError("Microphone access is required to start realtime audio capture.")
            return false
        }

        captureWasRequested = true
        captureState = .starting

        do {
            try configureAndStartCapture()
            captureState = .capturing
            return true
        } catch {
            captureWasRequested = false
            tearDownCapture()
            reportError("Microphone capture could not start: \(error.localizedDescription)")
            return false
        }
    }

    func stopCapture() {
        captureWasRequested = false
        captureGeneration = UUID()
        tearDownCapture()
        captureState = .stopped
    }

    @discardableResult
    func enqueuePlayback(
        base64PCM: String,
        sampleRate: Int,
        numChannels: Int
    ) -> Bool {
        clearError()

        do {
            let item = try makePlaybackItem(
                base64PCM: base64PCM,
                sampleRate: sampleRate,
                numChannels: numChannels
            )
            guard item.duration <= maximumBufferedPlaybackDuration else {
                throw RealtimeAudioError.playbackChunkTooLong(maximumBufferedPlaybackDuration)
            }

            trimPlaybackQueueToFit(additionalDuration: item.duration)
            let occupiedDuration = (currentPlaybackItem?.duration ?? 0) + queuedPlaybackDuration
            guard occupiedDuration + item.duration <= maximumBufferedPlaybackDuration else {
                throw RealtimeAudioError.playbackBufferFull
            }

            while playbackQueue.count >= maximumPlaybackQueueCount {
                playbackQueue.removeFirst()
            }
            playbackQueue.append(item)
            updateBufferedPlaybackDuration()
            try scheduleNextPlaybackItemIfNeeded()
            return true
        } catch {
            reportError("Realtime audio playback rejected a chunk: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func enqueuePlayback(_ chunk: PCMChunk) -> Bool {
        enqueuePlayback(
            base64PCM: chunk.data,
            sampleRate: chunk.sampleRate,
            numChannels: chunk.numChannels
        )
    }

    func stopPlayback() {
        playbackGeneration = UUID()
        playbackNode.stop()
        playbackEngine.stop()
        playbackQueue.removeAll(keepingCapacity: false)
        currentPlaybackItem = nil
        bufferedPlaybackDuration = 0
        playbackState = .stopped
    }

    func stop() {
        stopCapture()
        stopPlayback()
    }

    func clearError() {
        lastError = nil
    }

    private func configureAndStartCapture() throws {
        captureGeneration = UUID()
        captureDeliveryBuffer.removeAll()
        captureConverter.reset()

        captureEngine.stop()
        if captureTapIsInstalled {
            captureEngine.inputNode.removeTap(onBus: 0)
            captureTapIsInstalled = false
        }

        let inputNode = captureEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RealtimeAudioError.microphoneUnavailable
        }

        let generation = captureGeneration
        let converter = captureConverter
        let deliveryBuffer = captureDeliveryBuffer
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let result = converter.convert(buffer) else { return }

            switch result {
            case .success(let chunk):
                if deliveryBuffer.enqueue(chunk, generation: generation) {
                    Task { @MainActor [weak self] in
                        self?.drainCapturedAudio()
                    }
                }
            case .failure(let error):
                Task { @MainActor [weak self] in
                    self?.handleCapturePipelineFailure(error, generation: generation)
                }
            }
        }
        captureTapIsInstalled = true

        captureEngine.prepare()
        try captureEngine.start()
    }

    private func tearDownCapture() {
        if captureTapIsInstalled {
            captureEngine.inputNode.removeTap(onBus: 0)
            captureTapIsInstalled = false
        }
        captureEngine.stop()
        captureDeliveryBuffer.removeAll()
        captureConverter.reset()
    }

    private func drainCapturedAudio() {
        while let pending = captureDeliveryBuffer.popFirst() {
            guard pending.generation == captureGeneration, captureState == .capturing else { continue }
            captureHandler?(pending.chunk)
        }
    }

    private func handleCapturePipelineFailure(_ error: Error, generation: UUID) {
        guard generation == captureGeneration else { return }
        captureWasRequested = false
        captureGeneration = UUID()
        tearDownCapture()
        captureState = .stopped
        reportError("Microphone audio conversion failed: \(error.localizedDescription)")
    }

    private func handleCaptureConfigurationChange() {
        guard captureWasRequested else { return }

        captureState = .interrupted
        captureGeneration = UUID()

        do {
            try configureAndStartCapture()
            captureState = .capturing
        } catch {
            captureWasRequested = false
            tearDownCapture()
            captureState = .stopped
            reportError("Microphone capture stopped after an audio-device change: \(error.localizedDescription)")
        }
    }

    private func makePlaybackItem(
        base64PCM: String,
        sampleRate: Int,
        numChannels: Int
    ) throws -> PlaybackItem {
        guard (8_000...192_000).contains(sampleRate) else {
            throw RealtimeAudioError.invalidSampleRate
        }
        guard (1...8).contains(numChannels) else {
            throw RealtimeAudioError.invalidChannelCount
        }

        let maximumBase64Length = ((maximumEncodedPlaybackByteCount + 2) / 3) * 4
        guard base64PCM.utf8.count <= maximumBase64Length else {
            throw RealtimeAudioError.playbackChunkTooLarge
        }
        guard let pcmData = Data(base64Encoded: base64PCM), !pcmData.isEmpty else {
            throw RealtimeAudioError.invalidBase64
        }
        guard pcmData.count <= maximumEncodedPlaybackByteCount else {
            throw RealtimeAudioError.playbackChunkTooLarge
        }

        let bytesPerFrame = MemoryLayout<Int16>.size * numChannels
        guard pcmData.count.isMultiple(of: bytesPerFrame) else {
            throw RealtimeAudioError.misalignedPCM
        }
        let frameCount = pcmData.count / bytesPerFrame
        guard frameCount > 0, frameCount <= Int(UInt32.max) else {
            throw RealtimeAudioError.playbackChunkTooLarge
        }

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(numChannels),
            interleaved: true
        ), let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw RealtimeAudioError.invalidAudioFormat
        }

        sourceBuffer.frameLength = sourceBuffer.frameCapacity
        guard let destination = sourceBuffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            throw RealtimeAudioError.invalidAudioFormat
        }
        pcmData.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: pcmData.count)

        guard let converter = AVAudioConverter(from: sourceFormat, to: playbackFormat) else {
            throw RealtimeAudioError.conversionUnavailable
        }
        converter.primeMethod = .none

        let estimatedFrames = ceil(Double(frameCount) * playbackFormat.sampleRate / Double(sampleRate))
        let outputCapacity = AVAudioFrameCount(min(estimatedFrames + 256, Double(UInt32.max)))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: outputCapacity
        ) else {
            throw RealtimeAudioError.invalidAudioFormat
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }

        if status == .error {
            throw conversionError ?? RealtimeAudioError.conversionFailed
        }
        guard outputBuffer.frameLength > 0 else {
            throw RealtimeAudioError.conversionFailed
        }

        let duration = Double(outputBuffer.frameLength) / playbackFormat.sampleRate
        return PlaybackItem(buffer: outputBuffer, duration: duration)
    }

    private var queuedPlaybackDuration: TimeInterval {
        playbackQueue.reduce(0) { $0 + $1.duration }
    }

    private func trimPlaybackQueueToFit(additionalDuration: TimeInterval) {
        while !playbackQueue.isEmpty,
              (currentPlaybackItem?.duration ?? 0) + queuedPlaybackDuration + additionalDuration
                > maximumBufferedPlaybackDuration {
            playbackQueue.removeFirst()
        }
        updateBufferedPlaybackDuration()
    }

    private func updateBufferedPlaybackDuration() {
        bufferedPlaybackDuration = (currentPlaybackItem?.duration ?? 0) + queuedPlaybackDuration
    }

    private func scheduleNextPlaybackItemIfNeeded() throws {
        guard currentPlaybackItem == nil, let next = playbackQueue.first else { return }

        playbackState = .starting
        if !playbackEngine.isRunning {
            do {
                playbackEngine.prepare()
                try playbackEngine.start()
            } catch {
                playbackState = .stopped
                throw error
            }
        }

        playbackQueue.removeFirst()
        currentPlaybackItem = next
        playbackGeneration = UUID()
        let generation = playbackGeneration
        updateBufferedPlaybackDuration()

        playbackNode.scheduleBuffer(next.buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playbackItemDidFinish(generation: generation)
            }
        }
        if !playbackNode.isPlaying {
            playbackNode.play()
        }
        playbackState = .playing
    }

    private func playbackItemDidFinish(generation: UUID) {
        guard generation == playbackGeneration else { return }

        currentPlaybackItem = nil
        updateBufferedPlaybackDuration()

        do {
            try scheduleNextPlaybackItemIfNeeded()
            if currentPlaybackItem == nil {
                playbackNode.stop()
                playbackEngine.stop()
                playbackState = .stopped
            }
        } catch {
            stopPlayback()
            reportError("Realtime audio playback stopped: \(error.localizedDescription)")
        }
    }

    private func handlePlaybackConfigurationChange() {
        guard currentPlaybackItem != nil || !playbackQueue.isEmpty else { return }

        playbackState = .interrupted
        playbackGeneration = UUID()
        playbackNode.stop()
        playbackEngine.stop()

        if let interruptedItem = currentPlaybackItem {
            playbackQueue.insert(interruptedItem, at: 0)
            currentPlaybackItem = nil
        }
        updateBufferedPlaybackDuration()

        do {
            try scheduleNextPlaybackItemIfNeeded()
        } catch {
            stopPlayback()
            reportError("Realtime audio playback stopped after an audio-device change: \(error.localizedDescription)")
        }
    }

    private func reportError(_ message: String) {
        lastError = message
        errorHandler?(message)
    }

    private static func currentMicrophonePermission() -> MicrophonePermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }
}

private enum RealtimeAudioError: LocalizedError {
    case microphoneUnavailable
    case invalidSampleRate
    case invalidChannelCount
    case invalidBase64
    case misalignedPCM
    case playbackChunkTooLarge
    case playbackChunkTooLong(TimeInterval)
    case playbackBufferFull
    case invalidAudioFormat
    case conversionUnavailable
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "No usable microphone input is available."
        case .invalidSampleRate:
            return "The PCM sample rate must be between 8,000 and 192,000 Hz."
        case .invalidChannelCount:
            return "The PCM channel count must be between 1 and 8."
        case .invalidBase64:
            return "The PCM data is not valid base64."
        case .misalignedPCM:
            return "The PCM byte count is not aligned to signed 16-bit sample frames."
        case .playbackChunkTooLarge:
            return "The PCM chunk exceeds the in-memory size limit."
        case .playbackChunkTooLong(let maximumDuration):
            return "The PCM chunk is longer than the \(maximumDuration)-second playback buffer limit."
        case .playbackBufferFull:
            return "The bounded playback buffer is full."
        case .invalidAudioFormat:
            return "The PCM format could not be represented by AVFoundation."
        case .conversionUnavailable:
            return "AVFoundation could not create the required PCM converter."
        case .conversionFailed:
            return "AVFoundation did not produce playable PCM samples."
        }
    }
}

private final class CaptureDeliveryBuffer: @unchecked Sendable {
    struct PendingChunk {
        let chunk: RealtimeAudioCoordinator.PCMChunk
        let generation: UUID
    }

    private let lock = NSLock()
    private let maximumChunkCount: Int
    private var chunks: [PendingChunk] = []
    private var drainIsScheduled = false

    init(maximumChunkCount: Int) {
        self.maximumChunkCount = max(1, maximumChunkCount)
    }

    func enqueue(_ chunk: RealtimeAudioCoordinator.PCMChunk, generation: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if chunks.count >= maximumChunkCount {
            chunks.removeFirst()
        }
        chunks.append(PendingChunk(chunk: chunk, generation: generation))

        guard !drainIsScheduled else { return false }
        drainIsScheduled = true
        return true
    }

    func popFirst() -> PendingChunk? {
        lock.lock()
        defer { lock.unlock() }

        guard !chunks.isEmpty else {
            drainIsScheduled = false
            return nil
        }
        return chunks.removeFirst()
    }

    func removeAll() {
        lock.lock()
        chunks.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

private final class CaptureConverter: @unchecked Sendable {
    private let lock = NSLock()
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var didReportFailure = false

    init() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(RealtimeAudioCoordinator.captureSampleRate),
            channels: AVAudioChannelCount(RealtimeAudioCoordinator.captureChannelCount),
            interleaved: true
        ) else {
            preconditionFailure("Veo could not create its realtime capture format.")
        }
        outputFormat = format
    }

    func convert(
        _ inputBuffer: AVAudioPCMBuffer
    ) -> Result<RealtimeAudioCoordinator.PCMChunk, Error>? {
        lock.lock()
        defer { lock.unlock() }

        do {
            let inputFormat = inputBuffer.format
            if converter?.inputFormat != inputFormat {
                guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                    throw RealtimeAudioError.conversionUnavailable
                }
                newConverter.primeMethod = .none
                converter = newConverter
            }
            guard let converter else {
                throw RealtimeAudioError.conversionUnavailable
            }

            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let estimatedFrames = ceil(Double(inputBuffer.frameLength) * ratio)
            let outputCapacity = AVAudioFrameCount(min(estimatedFrames + 256, Double(UInt32.max)))
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw RealtimeAudioError.invalidAudioFormat
            }

            var suppliedInput = false
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if status == .error {
                throw conversionError ?? RealtimeAudioError.conversionFailed
            }
            guard outputBuffer.frameLength > 0,
                  let bytes = outputBuffer.audioBufferList.pointee.mBuffers.mData else {
                return nil
            }

            let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
            let pcm = Data(bytes: bytes, count: byteCount)
            let chunk = RealtimeAudioCoordinator.PCMChunk(
                data: pcm.base64EncodedString(),
                sampleRate: RealtimeAudioCoordinator.captureSampleRate,
                numChannels: RealtimeAudioCoordinator.captureChannelCount,
                samplesPerChannel: Int(outputBuffer.frameLength)
            )
            return .success(chunk)
        } catch {
            guard !didReportFailure else { return nil }
            didReportFailure = true
            return .failure(error)
        }
    }

    func reset() {
        lock.lock()
        converter = nil
        didReportFailure = false
        lock.unlock()
    }
}
