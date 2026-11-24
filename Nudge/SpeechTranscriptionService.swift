import AVFoundation
import Observation
import OSLog
import Speech
import UIKit

private enum CaptureError: Error, Equatable { case audio, overflow, unavailable, permission, inactive }

/// Audio ownership only: tap buffers are copied before crossing into an async stream.
@MainActor
private final class MicrophoneCapture {
    private var engine: AVAudioEngine?
    private var tapped = false
    private var ownsSession = false
    private var continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?

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

    func start(format: AVAudioFormat) throws -> AsyncThrowingStream<AnalyzerInput, Error> {
        guard let engine else { throw CaptureError.audio }
        let (stream, sink) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation = sink
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            guard let copy = Self.copy(buffer) else { sink.finish(throwing: CaptureError.audio); return }
            if case .dropped = sink.yield(AnalyzerInput(buffer: copy)) { sink.finish(throwing: CaptureError.overflow) }
        }
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

    private nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let result = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        result.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        guard source.count == target.count else { return nil }
        for i in 0..<source.count {
            guard let src = source[i].mData, let dst = target[i].mData,
                  target[i].mDataByteSize >= source[i].mDataByteSize else { return nil }
            memcpy(dst, src, Int(source[i].mDataByteSize))
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
    private let microphone = MicrophoneCapture()
    private let locale = Locale(identifier: "ru-RU")
    private var module: (any SpeechModule)?
    private var downloadLocale: Locale?
    private var downloadableModule: (any SpeechModule)?
    private var legacy: SFSpeechRecognizer?
    private var analyzer: SpeechAnalyzer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var resultTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var generation = 0
    private var finalized = ""
    private var startedAt: ContinuousClock.Instant?
    private var firstTextLogged = false
    private let logger = Logger(subsystem: "com.pavlovilya.nudge", category: "VoiceTiming")

    var isBusy: Bool { phase == .preparing || phase == .recording || phase == .finalizing }
    var permissionsGranted: Bool {
        canRecord && AVAudioApplication.shared.recordPermission == .granted
            && (module != nil || SFSpeechRecognizer.authorizationStatus() == .authorized)
    }

    func prepare() async {
        guard !isBusy else { return }
        phase = .preparing
        let token = generation
        var selected: (any SpeechModule)?
        var download: (any SpeechModule)?
        var downloadLocale: Locale?
        var name = ""
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            guard token == generation, !Task.isCancelled else { return }
            let candidate = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
            let status = await AssetInventory.status(forModules: [candidate])
            guard token == generation, !Task.isCancelled else { return }
            if status == .installed { selected = candidate; name = "SpeechTranscriber" }
            else { download = candidate; downloadLocale = supported }
        }
        if selected == nil, let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            guard token == generation, !Task.isCancelled else { return }
            let candidate = DictationTranscriber(locale: supported, preset: .progressiveShortDictation)
            let status = await AssetInventory.status(forModules: [candidate])
            guard token == generation, !Task.isCancelled else { return }
            if status == .installed { selected = candidate; name = "DictationTranscriber" }
            else if download == nil { download = candidate; downloadLocale = supported }
        }
        guard token == generation, !Task.isCancelled else { return }
        module = selected
        downloadableModule = download
        self.downloadLocale = downloadLocale
        legacy = nil
        if selected == nil, let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition {
            legacy = recognizer
            name = "SFSpeechRecognizer · on-device"
        }
        backendName = name
        canRecord = selected != nil || legacy != nil
        canInstall = download != nil
        phase = .idle
        errorMessage = canRecord ? nil : String(localized: "Offline Russian recognition is unavailable. Install system language resources if offered, or enter the text manually.")
    }

    func installResources() async {
        guard !isBusy, let candidate = downloadableModule else { return }
        phase = .preparing
        let token = generation
        do {
            if let localized = downloadLocale {
                _ = try await AssetInventory.reserve(locale: localized) // false means already reserved, not failure.
                guard token == generation, !Task.isCancelled else { return }
            }
            let installation = try await AssetInventory.assetInstallationRequest(supporting: [candidate])
            guard token == generation, !Task.isCancelled else { return }
            if let installation { try await installation.downloadAndInstall() }
            guard token == generation, !Task.isCancelled else { return }
            phase = .idle
            await prepare()
        } catch {
            guard token == generation else { return }
            phase = .idle
            errorMessage = String(localized: "Could not install system speech resources. Check connectivity and free storage, then retry. No speech was uploaded.")
        }
    }

    func start() async {
        guard !isBusy, canRecord else { return }
        cancel()
        phase = .preparing
        let token = generation
        text = ""; finalized = ""; firstTextLogged = false
        do {
            let permitted = await AVAudioApplication.requestRecordPermission()
            guard token == generation, !Task.isCancelled else { return }
            guard permitted else { throw CaptureError.permission }
            if module == nil {
                let status = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                }
                guard token == generation, !Task.isCancelled else { return }
                guard status == .authorized else { throw CaptureError.permission }
            }
            guard token == generation, !Task.isCancelled else { return }
            guard UIApplication.shared.applicationState == .active else { throw CaptureError.inactive }
            let naturalFormat = try microphone.configure()
            if let module {
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
            } else {
                guard let legacy, legacy.supportsOnDeviceRecognition, legacy.isAvailable else { throw CaptureError.unavailable }
                try startLegacy(legacy, format: naturalFormat, token: token)
            }
            phase = .recording
            startedAt = .now
            logger.info("recording_started backend=\(self.backendName, privacy: .public)")
            deadlineTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, self?.generation == token else { return }
                self?.stop()
            }
        } catch {
            guard token == generation else { return }
            fail(error)
        }
    }

    private func startAnalyzer(_ analyzer: SpeechAnalyzer, module: any SpeechModule, format: AVAudioFormat, naturalFormat: AVAudioFormat, token: Int) throws {
        let input = try microphone.start(format: naturalFormat)
        let (converted, sink) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
        guard let converter = AVAudioConverter(from: naturalFormat, to: format) else { throw CaptureError.audio }
        inputTask = Task {
            do {
                for try await input in input {
                    try Task.checkCancellation()
                    let buffer = input.buffer // iOS 26 compatibility; 27-only read-only APIs are not required.
                    let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / naturalFormat.sampleRate)) + 32
                    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw CaptureError.audio }
                    var supplied = false
                    var error: NSError?
                    let status = converter.convert(to: output, error: &error) { _, state in
                        if supplied { state.pointee = .noDataNow; return nil }
                        supplied = true; state.pointee = .haveData; return buffer
                    }
                    guard status != .error, error == nil else { throw CaptureError.audio }
                    if output.frameLength > 0, case .dropped = sink.yield(AnalyzerInput(buffer: output)) { throw CaptureError.overflow }
                }
                // Drain resampler tail before finalizing the utterance.
                while !Task.isCancelled {
                    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw CaptureError.audio }
                    var error: NSError?
                    let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
                    guard status != .error, error == nil else { throw CaptureError.audio }
                    if output.frameLength > 0, case .dropped = sink.yield(AnalyzerInput(buffer: output)) { throw CaptureError.overflow }
                    if status == .endOfStream || output.frameLength == 0 { break }
                }
                sink.finish()
            } catch { sink.finish(throwing: error) }
        }
        if let transcriber = module as? SpeechTranscriber {
            resultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard self?.generation == token, !Task.isCancelled else { return }
                        self?.accept(String(result.text.characters), final: result.isFinal)
                    }
                } catch { if self?.generation == token { self?.fail(error) } }
            }
        } else if let transcriber = module as? DictationTranscriber {
            resultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard self?.generation == token, !Task.isCancelled else { return }
                        self?.accept(String(result.text.characters), final: result.isFinal)
                    }
                } catch { if self?.generation == token { self?.fail(error) } }
            }
        }
        let results = resultTask
        analysisTask = Task { [weak self] in
            do {
                _ = try await analyzer.analyzeSequence(inputSequence: converted)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                await results?.value
                guard self?.generation == token, !Task.isCancelled else { return }
                self?.finish()
            } catch { if self?.generation == token { self?.fail(error) } }
        }
    }

    private func startLegacy(_ recognizer: SFSpeechRecognizer, format: AVAudioFormat, token: Int) throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if let text { self.text = text; self.logFirstText() }
                if final { self.finish() }
                else if failed { self.fail(CaptureError.unavailable) }
            }
        }
        let input = try microphone.start(format: format)
        inputTask = Task { [weak self] in
            do {
                for try await input in input {
                    guard self?.generation == token, !Task.isCancelled else { return }
                    request.append(input.buffer)
                }
                guard self?.generation == token, !Task.isCancelled else { return }
                request.endAudio() // All queued buffers have been appended before EOF.
            } catch { if self?.generation == token { self?.fail(error) } }
        }
    }

    func stop() {
        guard phase == .recording else { return }
        phase = .finalizing
        microphone.stop()
        deadlineTask?.cancel()
        let token = generation
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, self?.generation == token, self?.phase == .finalizing else { return }
            self?.fail(CaptureError.unavailable)
        }
    }
    func cancel() {
        generation += 1
        microphone.stop()
        inputTask?.cancel(); resultTask?.cancel(); analysisTask?.cancel(); deadlineTask?.cancel()
        inputTask = nil; resultTask = nil; analysisTask = nil; deadlineTask = nil
        recognitionTask?.cancel(); recognitionTask = nil; request = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        phase = .idle
        errorMessage = nil
    }
    func interrupt() {
        guard isBusy else { return }
        cancel()
        errorMessage = String(localized: "Recording stopped. You can edit the partial text or record again.")
    }
    private func accept(_ fragment: String, final: Bool) {
        if final { finalized += fragment + " "; text = finalized.trimmingCharacters(in: .whitespacesAndNewlines) }
        else { text = (finalized + fragment).trimmingCharacters(in: .whitespacesAndNewlines) }
        logFirstText()
    }
    private func logFirstText() {
        guard !text.isEmpty, !firstTextLogged, let startedAt else { return }
        firstTextLogged = true
        logger.info("first_text_ms=\(Self.milliseconds(since: startedAt), privacy: .public)")
    }
    private func finish() {
        microphone.stop()
        deadlineTask?.cancel()
        if let startedAt { logger.info("transcription_finished_ms=\(Self.milliseconds(since: startedAt), privacy: .public)") }
        // Reject any callback arriving after a final result, while preserving its text.
        cancel()
        phase = .finished
    }
    private func fail(_ error: Error) {
        cancel()
        errorMessage = error as? CaptureError == .permission
            ? String(localized: "Microphone or speech permission is denied. Allow access in iOS Settings, or enter text manually.")
            : String(localized: "Offline recognition could not finish. Check the text, retry recording, or type manually. No cloud recognition is used.")
    }
    private nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
}
