import AVFoundation
import CoreMedia
import Observation
import OSLog
import Speech
import UIKit

private enum CaptureError: Error, Equatable { case audio, overflow, unavailable, permission, inactive }

// These factories deliberately live outside MainActor. Objective-C callbacks may
// run on arbitrary queues; an inner Task cannot repair an isolated outer callback.
enum SpeechCallbacks {
    nonisolated static func shouldInterruptRecording(for reason: AVAudioSession.RouteChangeReason?) -> Bool {
        // Our own setCategory(.record) notification can arrive after engine.start().
        reason != .categoryChange
    }

    // AnalyzerInput's PCM initializer requires signed Int16. Native microphone PCM
    // (usually Float32) must remain a plain buffer until conversion has completed.
    nonisolated static func analyzerInput(_ converter: AVAudioConverter, buffer: AVAudioPCMBuffer?) throws
        -> (input: AnalyzerInput?, status: AVAudioConverterOutputStatus) {
        let format = converter.outputFormat
        guard format.commonFormat == .pcmFormatInt16 else { throw CaptureError.audio }
        if let buffer, buffer.format != converter.inputFormat { throw CaptureError.audio }
        let capacity = buffer.map {
            AVAudioFrameCount(ceil(Double($0.frameLength) * format.sampleRate / converter.inputFormat.sampleRate)) + 32
        } ?? 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw CaptureError.audio }
        var error: NSError?
        let status = convert(converter, output: output, input: buffer, error: &error)
        if let error { throw error }
        guard status != .error else { throw CaptureError.audio }
        // A fresh output is handed off once and is never reused by the converter.
        return (output.frameLength > 0 ? AnalyzerInput(buffer: output) : nil, status)
    }

    // AVAudioConverter invokes its input block synchronously during convert().
    // The per-call supply flag and buffers never cross an actor or escape this call.
    nonisolated static func convert(_ converter: AVAudioConverter, output: AVAudioPCMBuffer,
                                    input: AVAudioPCMBuffer?, error: inout NSError?) -> AVAudioConverterOutputStatus {
        var supplied = false
        return converter.convert(to: output, error: &error) { _, state in
            guard let input else { state.pointee = .endOfStream; return nil }
            guard !supplied else { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
    }
}

@MainActor
protocol MicrophoneCapturing: AnyObject {
    func configure() throws -> AVAudioFormat
    func start(format: AVAudioFormat) throws -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
    func stop()
}

/// Audio ownership only: tap buffers are copied before crossing into an async stream.
@MainActor
final class MicrophoneCapture: MicrophoneCapturing {
    private var engine: AVAudioEngine?
    private var tapped = false
    private var ownsSession = false
    private var continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation?

    func configure() throws -> AVAudioFormat {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        ownsSession = true
        let engine = AVAudioEngine()
        self.engine = engine
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.audio }
        return format
    }

    func start(format: AVAudioFormat) throws -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        guard let engine else { throw CaptureError.audio }
        // Route changes can occur while analyzer preparation suspends. Input nodes
        // cannot convert a stale hardware format; reject it before installTap asserts.
        let current = engine.inputNode.outputFormat(forBus: 0)
        guard current.sampleRate > 0, current.channelCount > 0,
              current.sampleRate == format.sampleRate, current.channelCount == format.channelCount,
              current.commonFormat == format.commonFormat, current.isInterleaved == format.isInterleaved
        else { throw CaptureError.audio }
        let (stream, sink) = AsyncThrowingStream<AVAudioPCMBuffer, Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation = sink
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(sink))
        tapped = true
        engine.prepare()
        try engine.start()
        return stream
    }

    func stop() {
        engine?.stop()
        if tapped { engine?.inputNode.removeTap(onBus: 0); tapped = false }
        continuation?.finish()
        continuation = nil
        engine = nil
        if ownsSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            ownsSession = false
        }
    }

    nonisolated static func tap(_ sink: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in
            guard let copy = Self.copy(buffer) else { sink.finish(throwing: CaptureError.audio); return }
            if case .dropped = sink.yield(copy) { sink.finish(throwing: CaptureError.overflow) }
        }
    }

    private nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> sending AVAudioPCMBuffer? {
        // Snapshot into Sendable bytes first. A raw memcpy between two non-Sendable
        // buffers conservatively aliases their Swift concurrency regions.
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var samples: [Data] = []
        for segment in source {
            guard let bytes = segment.mData else { return nil }
            samples.append(Data(bytes: bytes, count: Int(segment.mDataByteSize)))
        }
        guard let result = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        result.frameLength = buffer.frameLength
        let target = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        guard samples.count == target.count else { return nil }
        for i in 0..<target.count {
            guard let dst = target[i].mData, Int(target[i].mDataByteSize) >= samples[i].count else { return nil }
            samples[i].copyBytes(to: dst.assumingMemoryBound(to: UInt8.self), count: samples[i].count)
        }
        return result
    }
}

@MainActor @Observable
final class SpeechTranscriptionService {
    enum Phase: Equatable { case idle, preparing, recording, finalizing, finished }
    private(set) var phase = Phase.idle
    private(set) var text = ""
    private(set) var backendName = ""
    private(set) var canRecord = false
    private(set) var canInstall = false
    private(set) var errorMessage: String?
    private let microphone: any MicrophoneCapturing

    init(microphone: (any MicrophoneCapturing)? = nil) {
        self.microphone = microphone ?? MicrophoneCapture()
    }
    private let locale = Locale(identifier: "ru-RU")
    enum ResourceStatus: Equatable { case checking, available, notInstalled, installing, unavailable, failed }
    private(set) var resourceStatus = ResourceStatus.checking
    private var selectedLocale: Locale?
    private func makeModule(_ locale: Locale) -> DictationTranscriber {
        var preset = DictationTranscriber.Preset.progressiveLongDictation
        preset.attributeOptions.insert(.audioTimeRange)
        return DictationTranscriber(locale: locale, preset: preset)
    }
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var generation = 0
    private var transcript = SpeechTranscript()
    private var startedAt: ContinuousClock.Instant?
    private var firstTextLogged = false
    private let logger = Logger(subsystem: "com.pavlovilya.nudge", category: "VoiceTiming")

    var isBusy: Bool { phase == .preparing || phase == .recording || phase == .finalizing }
    var permissionsGranted: Bool { canRecord && AVAudioApplication.shared.recordPermission == .granted }

    func prepare() async {
        guard !isBusy, resourceStatus != .installing else { return }
        resourceStatus = .checking
        logger.info("speech_prepare_started backend=DictationTranscriber")
        let token = generation
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            guard token == generation else { return }
            selectedLocale = nil; canRecord = false; canInstall = false; resourceStatus = .unavailable
            errorMessage = String(localized: "Russian dictation is unavailable. You can enter the text manually.")
            return
        }
        let status = await AssetInventory.status(forModules: [makeModule(locale)])
        guard token == generation, !Task.isCancelled else { return }
        selectedLocale = locale
        backendName = "DictationTranscriber"
        canRecord = status == .installed
        canInstall = status == .supported || status == .downloading
        resourceStatus = canRecord ? .available : (canInstall ? .notInstalled : .unavailable)
        errorMessage = canRecord ? nil : String(localized: "Install Apple dictation resources in Settings, or enter text manually.")
    }

    func installResources() async {
        guard !isBusy, canInstall, resourceStatus != .installing, let locale = selectedLocale else { return }
        resourceStatus = .installing
        let token = generation
        do {
            let module = makeModule(locale)
            if await AssetInventory.status(forModules: [module]) != .installed {
                _ = try await AssetInventory.reserve(locale: locale)
                guard token == generation, !Task.isCancelled else { return }
                if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await installation.downloadAndInstall()
                }
            }
            guard token == generation, !Task.isCancelled else { return }
            resourceStatus = .checking
            await prepare()
        } catch {
            guard token == generation else { return }
            resourceStatus = .failed
            errorMessage = String(localized: "Could not install system speech resources. Check connectivity and free storage, then retry. No speech was uploaded.")
        }
    }

    func start() async {
        guard !isBusy, canRecord else { return }
        cancel()
        phase = .preparing
        let token = generation
        text = ""; transcript = SpeechTranscript(); firstTextLogged = false; startedAt = nil
        do {
            let permitted = await AVAudioApplication.requestRecordPermission()
            guard token == generation, !Task.isCancelled else { return }
            guard permitted else { throw CaptureError.permission }
            logger.info("microphone_permission_granted")
            guard token == generation, !Task.isCancelled else { return }
            guard UIApplication.shared.applicationState == .active else { throw CaptureError.inactive }
            let naturalFormat = try microphone.configure()
            logger.info("audio_session_configured backend=\(self.backendName, privacy: .public)")
            if let locale = selectedLocale {
                let module = makeModule(locale)
                let status = await AssetInventory.status(forModules: [module])
                guard token == generation, !Task.isCancelled else { return }
                guard status == .installed else { throw CaptureError.unavailable }
                let analyzer = SpeechAnalyzer(modules: [module])
                self.analyzer = analyzer
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: naturalFormat) else { throw CaptureError.audio }
                guard token == generation, !Task.isCancelled else { return }
                try await analyzer.prepareToAnalyze(in: format)
                guard token == generation, !Task.isCancelled else { return }
                guard UIApplication.shared.applicationState == .active else { throw CaptureError.inactive }
                try startAnalyzer(analyzer, module: module, format: format, naturalFormat: naturalFormat, token: token)
            } else { throw CaptureError.unavailable }
            phase = .recording
            startedAt = .now
            logger.info("audio_engine_started backend=\(self.backendName, privacy: .public)")
        } catch {
            guard token == generation else { return }
            fail(error)
        }
    }

    private func startAnalyzer(_ analyzer: SpeechAnalyzer, module: DictationTranscriber, format: AVAudioFormat, naturalFormat: AVAudioFormat, token: Int) throws {
        let input = try microphone.start(format: naturalFormat)
        let (converted, sink) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
        guard let converter = AVAudioConverter(from: naturalFormat, to: format) else { throw CaptureError.audio }
        inputTask = Task {
            do {
                for try await buffer in input {
                    try Task.checkCancellation()
                    let result = try SpeechCallbacks.analyzerInput(converter, buffer: buffer)
                    if let input = result.input, case .dropped = sink.yield(input) { throw CaptureError.overflow }
                }
                // Drain resampler tail before finalizing the utterance.
                while !Task.isCancelled {
                    let result = try SpeechCallbacks.analyzerInput(converter, buffer: nil)
                    if let input = result.input, case .dropped = sink.yield(input) { throw CaptureError.overflow }
                    if result.status == .endOfStream || result.input == nil { break }
                }
                sink.finish()
            } catch { sink.finish(throwing: error) }
        }
        resultTask = Task { [weak self] in
            do {
                for try await result in module.results {
                    guard self?.generation == token, !Task.isCancelled else { return }
                    self?.accept(result.text, range: result.range, finalizedThrough: result.resultsFinalizationTime)
                }
            } catch { if self?.generation == token { self?.fail(error) } }
        }
        let results = resultTask
        analysisTask = Task { [weak self] in
            do {
                _ = try await analyzer.analyzeSequence(converted)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                await results?.value
                guard self?.generation == token, !Task.isCancelled else { return }
                self?.finish()
            } catch { if self?.generation == token { self?.fail(error) } }
        }
    }

    func stop() {
        guard phase == .recording else { return }
        phase = .finalizing
        logger.info("speech_stopped backend=\(self.backendName, privacy: .public)")
        microphone.stop()
    }
    func cancel(clearText: Bool = false) {
        generation += 1
        if isBusy { logger.info("speech_stopped backend=\(self.backendName, privacy: .public)") }
        microphone.stop()
        inputTask?.cancel(); resultTask?.cancel(); analysisTask?.cancel()
        inputTask = nil; resultTask = nil; analysisTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        phase = .idle
        errorMessage = nil
        if clearText { text = ""; transcript = SpeechTranscript() }
    }
    func interrupt() {
        guard isBusy else { return }
        cancel()
        errorMessage = String(localized: "Recording stopped. You can edit the partial text or record again.")
    }
    func accept(_ text: AttributedString, range: CMTimeRange, finalizedThrough: CMTime) {
        var parts: [SpeechTranscript.Part] = []
        var prefix = ""
        for run in text.runs {
            let fragment = String(text[run.range].characters)
            if let timed = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self],
               timed.isValid, CMTimeCompare(timed.duration, .zero) > 0 {
                parts.append(.init(text: prefix + fragment, range: timed))
                prefix = ""
            } else if !parts.isEmpty {
                // Untimed punctuation/whitespace belongs to the preceding word.
                parts[parts.count - 1].text += fragment
            } else { prefix += fragment }
        }
        if parts.isEmpty, !prefix.isEmpty { parts = [.init(text: prefix, range: range)] }
        transcript.replace(range: range, with: parts, finalizedThrough: finalizedThrough)
        self.text = transcript.text
        logFirstText()
    }

    private func logFirstText() {
        guard !text.isEmpty, !firstTextLogged, let startedAt else { return }
        firstTextLogged = true
        logger.info("speech_first_result elapsed_ms=\(Self.milliseconds(since: startedAt), privacy: .public)")
    }
    private func finish() {
        microphone.stop()
        if let startedAt { logger.info("speech_finished elapsed_ms=\(Self.milliseconds(since: startedAt), privacy: .public)") }
        // Reject any callback arriving after a final result, while preserving its text.
        cancel()
        phase = .finished
    }
    private func fail(_ error: Error) {
        let failure = error as NSError
        logger.error("speech_failed backend=\(self.backendName, privacy: .public) domain=\(failure.domain, privacy: .public) code=\(failure.code, privacy: .public)")
        cancel()
        errorMessage = error as? CaptureError == .permission
            ? String(localized: "Microphone access is denied. Allow it in Settings, or type the request.")
            : String(localized: "Offline recognition could not finish. Check the text, retry recording, or type manually. No cloud recognition is used.")
    }
    private nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
}
