import AVFoundation
import CoreMedia
import Speech
import SwiftData
import XCTest
@testable import Nudge

final class InterpreterTests: XCTestCase {
    private func context(zone: String = "Europe/Moscow", now: String = "2026-11-24T09:00:00Z") -> InterpretationContext {
        var calendar = Calendar(identifier: .gregorian)
        let timezone = TimeZone(identifier: zone)!
        calendar.timeZone = timezone
        return InterpretationContext(now: ISO8601DateFormatter().date(from: now)!, calendar: calendar, timeZone: timezone, locale: Locale(identifier: "ru_RU"))
    }
    func testRussianCommands() async throws {
        let cases = [
            ("Слушай, напомни мне завтра в восемь вечера забрать посылку", "Забрать посылку", "2026-11-25T17:00:00Z"),
            ("Сегодня в 18:00 позвонить Маше", "Позвонить Маше", "2026-11-24T15:00:00Z"),
            ("Завтра в 9 утра забрать посылку", "Забрать посылку", "2026-11-25T06:00:00Z"),
            ("Послезавтра в 12 купить хлеб", "Купить хлеб", "2026-11-26T09:00:00Z"),
            ("Напомни через десять минут позвонить маме", "Позвонить маме", "2026-11-24T09:10:00Z"),
            ("Через час выйти", "Выйти", "2026-11-24T10:00:00Z"),
            ("Через 2 часа выйти", "Выйти", "2026-11-24T11:00:00Z"),
            ("В понедельник в 15:00 оплатить счёт", "Оплатить счёт", "2026-11-30T12:00:00Z"),
            ("В среду в 8 вечера забрать посылку", "Забрать посылку", "2026-11-25T17:00:00Z"),
            ("25 ноября в 14:30 оплатить счёт", "Оплатить счёт", "2026-11-25T11:30:00Z"),
            ("Завтра часов в семь вечера нужно забрать посылку", "Забрать посылку", "2026-11-25T16:00:00Z"),
            ("Поставь напоминание на среду на девять утра, оплатить счёт", "Оплатить счёт", "2026-11-25T06:00:00Z"),
            ("  Пожалуйста,  НАПОМНИ мне через 10 минут купить два билета! ", "Купить два билета", "2026-11-24T09:10:00Z")]
        for (text, title, date) in cases {
            let draft = try await RuleBasedInterpreter().interpret(text: text, context: context())
            XCTAssertEqual(draft.title, title, text)
            XCTAssertEqual(draft.date, ISO8601DateFormatter().date(from: date), text)
            XCTAssertTrue(draft.warnings.isEmpty, "\(text): \(draft.warnings)")
        }
    }
    func testMissingInvalidAmbiguousAndRecurring() async throws {
        for phrase in ["Завтра забрать посылку", "Позвонить маме", "В 18:00 позвонить", "Завтра в 9 или в 10 выйти", "Завтра и послезавтра в 9 выйти", "Каждый второй вторник в 15:00 выйти", "31 ноября в 12 выйти", "Завтра в 25:90 выйти", "Через 2 часа 10 минут выйти", "Завтра в 10:5 выйти", "Завтра в 10:100 выйти", "Завтра в 15:30:45 выйти", "Завтра в 10:10:45 выйти", "Завтра в 9 или 10 утра выйти"] {
            let draft = try await RuleBasedInterpreter().interpret(text: phrase, context: context())
            XCTAssertNil(draft.date, phrase)
            XCTAssertFalse(draft.warnings.isEmpty, phrase)
        }
        let past = try await RuleBasedInterpreter().interpret(text: "Сегодня в 9 утра выйти", context: context())
        XCTAssertTrue(past.warnings.contains(.pastDate))
        XCTAssertThrowsError(try past.validated(now: context().now))
    }
    func testTimeZonesDSTAndYearBoundary() async throws {
        let interpreter = RuleBasedInterpreter()
        let ny = try await interpreter.interpret(text: "Завтра в 9 утра выйти", context: context(zone: "America/New_York"))
        XCTAssertEqual(ny.date, ISO8601DateFormatter().date(from: "2026-11-25T14:00:00Z"))
        let gap = try await interpreter.interpret(text: "Завтра в 02:30 выйти", context: context(zone: "America/New_York", now: "2026-03-07T17:00:00Z"))
        XCTAssertNil(gap.date)
        let fold = try await interpreter.interpret(text: "Завтра в 01:30 выйти", context: context(zone: "America/New_York", now: "2026-10-31T16:00:00Z"))
        XCTAssertNil(fold.date)
        let nextYear = try await interpreter.interpret(text: "1 января в 9 утра выйти", context: context(now: "2026-12-31T09:00:00Z"))
        XCTAssertEqual(nextYear.date, ISO8601DateFormatter().date(from: "2027-01-01T06:00:00Z"))
    }
    func testReinterpretationAndDraftValidation() async throws {
        let interpreter = RuleBasedInterpreter()
        let first = try await interpreter.interpret(text: "Напомни забрать посылку", context: context())
        XCTAssertNil(first.date)
        let corrected = try await interpreter.interpret(text: "Напомни завтра в 20:00 забрать посылку", context: context())
        XCTAssertTrue(corrected.isCurrent(for: "Напомни завтра в 20:00 забрать посылку"))
        XCTAssertFalse(corrected.isCurrent(for: "Напомни завтра в 21:00 забрать посылку"))
        XCTAssertEqual(corrected.sourceText, "Напомни завтра в 20:00 забрать посылку")
        XCTAssertEqual(try corrected.validated(now: context().now).title, "Забрать посылку")
        XCTAssertThrowsError(try ReminderDraft(sourceText: "", title: " ", date: corrected.date, warnings: []).validated(now: context().now))
    }
}

@MainActor
final class VoiceCreationTests: XCTestCase {
    func testInterpretationSourceWaitsForSettledSpeechAndAllowsManualCorrection() {
        for partial in ["Напомни", "Напомни завтра", "Напомни завтра забрать посылку"] {
            XCTAssertNil(VoiceCaptureView.interpretationSource(text: partial, isCapturing: true, hasCreatedTask: false))
        }
        let full = "Напомни завтра забрать посылку и позвонить маме"
        XCTAssertEqual(VoiceCaptureView.interpretationSource(text: full, isCapturing: false, hasCreatedTask: false), full)
        let edited = "Завтра в 20:00 позвонить маме"
        XCTAssertEqual(VoiceCaptureView.interpretationSource(text: edited, isCapturing: false, hasCreatedTask: false), edited)
        XCTAssertNil(VoiceCaptureView.interpretationSource(text: full, isCapturing: false, hasCreatedTask: true))
        XCTAssertNil(VoiceCaptureView.interpretationSource(text: "  ", isCapturing: false, hasCreatedTask: false))
        XCTAssertEqual(InterpretationContext(now: .distantPast, calendar: .current, timeZone: .current, locale: Locale(identifier: "ru_RU")).defaultSoundID, AlarmSound.newReminderDefault.rawValue)
    }

    func testVoiceRouteAndExistingReminderLinks() {
        let id = UUID()
        XCTAssertEqual(AppRoute(url: AppRoute.voiceURL), .voice)
        XCTAssertEqual(AppRoute(url: ReminderLink.url(for: id)), .reminder(id))
        XCTAssertEqual(ReminderLink.id(from: ReminderLink.url(for: id)), id)
        for invalid in ["nudge://voice/extra", "nudge://voice?cloud=true", "https://voice", "nudge://reminder/no"] {
            XCTAssertNil(AppRoute(url: URL(string: invalid)!))
        }
    }
    func testOneConfirmationCreatesOnlyOnceAndFailedSaveCanRetry() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let draft = ReminderDraft(sourceText: "Task", title: "Task", date: now.addingTimeInterval(600), warnings: [])
        let creation = VoiceCreation()
        let id = UUID()
        var calls = 0
        let first = try await creation.confirm(draft: draft, now: now) { _, _ in calls += 1; return id }
        let second = try await creation.confirm(draft: draft, now: now) { _, _ in calls += 1; return UUID() }
        XCTAssertEqual(first, id)
        XCTAssertNil(second)
        XCTAssertEqual(calls, 1)
        let retrying = VoiceCreation()
        let failure = try await retrying.confirm(draft: draft, now: now) { _, _ in nil }
        XCTAssertNil(failure)
        let retried = try await retrying.confirm(draft: draft, now: now) { _, _ in id }
        XCTAssertEqual(retried, id)
    }
    func testVersion050StoreKeepsTasksAlarmAndCalendarIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfiguration(url: directory.appendingPathComponent("legacy050.store"))
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let id = UUID()
        do {
            let old = try ModelContainer(for: Legacy050.Reminder.self, configurations: config)
            let context = ModelContext(old)
            context.insert(Legacy050.Reminder(id: id, date: date))
            let completed = Legacy050.Reminder(id: UUID(), date: date)
            completed.completedAt = date
            context.insert(completed)
            try context.save()
        }
        let current = try ModelContainer(for: Reminder.self, configurations: config)
        let items = try ModelContext(current).fetch(FetchDescriptor<Reminder>())
        XCTAssertEqual(items.count, 2)
        let saved = try XCTUnwrap(items.first { $0.id == id })
        XCTAssertEqual(saved.title, "Legacy 0.5.0")
        XCTAssertEqual(saved.alarmID, id)
        XCTAssertEqual(saved.scheduledAt, date)
        XCTAssertEqual(saved.createdAt, date.addingTimeInterval(-60))
        XCTAssertEqual(saved.nextAlarmAt, date.addingTimeInterval(300))
        XCTAssertEqual(saved.pendingSnoozeAt, date.addingTimeInterval(600))
        XCTAssertEqual(saved.sound, .experimentalVibrationOnly)
        XCTAssertEqual(saved.alarmDisabled, false)
        XCTAssertEqual(saved.alarmNeedsUpdate, true)
        XCTAssertNil(saved.alarmActionsVersion)
        XCTAssertNil(saved.recurrenceData)
        XCTAssertNil(saved.nextOccurrenceAt)
        XCTAssertNil(saved.occurrenceID)
        XCTAssertNil(saved.completedOccurrencesData)
        XCTAssertNil(saved.alarmWriteStarted)
        XCTAssertEqual(saved.calendarEnabled, true)
        XCTAssertEqual(saved.calendarIdentifier, "calendar")
        XCTAssertEqual(saved.calendarEventID, "event")
        XCTAssertEqual(saved.calendarExternalID, "server")
        XCTAssertEqual(saved.calendarEventDate, date)
        XCTAssertEqual(saved.calendarNeedsSync, true)
        XCTAssertEqual(saved.calendarError, "Calendar pending")
        XCTAssertEqual(saved.alarmState, .failed)
        XCTAssertEqual(saved.alarmError, "Alarm pending")
        XCTAssertNil(saved.completedAt)
        XCTAssertEqual(items.filter { $0.completedAt == date }.count, 1)
    }

    func testVoiceCreationPersistsExactlyTheVisibleText() async throws {
        let container = try ModelContainer(for: Reminder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let store = ReminderStore(context: context, alarms: AlarmService(
            schedule: { _, _, _, _ in XCTFail("Undated task") }, cancel: { _ in XCTFail("No signal") }, scheduledAlarms: { [:] }))
        let visible = "  Напомни забрать посылку\nи позвонить маме!  "
        let draft = VoiceTaskFields().draft(text: visible)
        let creation = VoiceCreation()
        let id = try await creation.confirm(draft: draft, now: .now) { title, date in
            guard await store.create(title: title, date: date, alarmEnabled: draft.alarmEnabled, preserveTitleWhitespace: true) else { return nil }
            return store.lastCreatedID
        }
        let saved = try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertEqual(saved.id, id)
        XCTAssertEqual(saved.title, visible)
        XCTAssertNil(saved.scheduledAt)
        XCTAssertFalse(saved.alarmEnabled)
    }

    func testConcurrentConfirmationDoesNotDuplicate() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let draft = ReminderDraft(sourceText: "Task", title: "Task", date: now.addingTimeInterval(600), warnings: [])
        let creation = VoiceCreation()
        var continuation: CheckedContinuation<UUID?, Never>?
        let first = Task { try await creation.confirm(draft: draft, now: now) { _, _ in await withCheckedContinuation { continuation = $0 } } }
        while continuation == nil { await Task.yield() }
        let repeated = try await creation.confirm(draft: draft, now: now) { _, _ in XCTFail("Duplicate save"); return UUID() }
        XCTAssertNil(repeated)
        let id = UUID(); continuation?.resume(returning: id)
        let result = try await first.value
        XCTAssertEqual(result, id)
    }
}

// Frozen task-first 0.5.0 schema immediately before recurrence additions.
// Earlier required-deadline migrations are covered by Legacy040 and older fixtures.
private enum Legacy050 {
    @Model final class Reminder {
        @Attribute(.unique) var id: UUID
        var title: String
        var scheduledAt: Date?
        var createdAt: Date
        var nextAlarmAt: Date?
        var pendingSnoozeAt: Date?
        var soundModeID: String?
        var alarmDisabled: Bool?
        var alarmNeedsUpdate: Bool?
        var alarmActionsVersion: Int?
        var calendarEnabled: Bool?
        var calendarIdentifier: String?
        var calendarEventID: String?
        var calendarExternalID: String?
        var calendarEventDate: Date?
        var calendarNeedsSync: Bool?
        var calendarError: String?
        var completedAt: Date?
        var alarmID: UUID
        var alarmState: AlarmRegistration
        var alarmError: String?

        init(id: UUID, date: Date) {
            self.id = id
            title = "Legacy 0.5.0"
            scheduledAt = date
            createdAt = date.addingTimeInterval(-60)
            nextAlarmAt = date.addingTimeInterval(300)
            pendingSnoozeAt = date.addingTimeInterval(600)
            soundModeID = "experimentalVibrationOnly"
            alarmDisabled = false
            alarmNeedsUpdate = true
            calendarEnabled = true
            calendarIdentifier = "calendar"
            calendarEventID = "event"
            calendarExternalID = "server"
            calendarEventDate = date
            calendarNeedsSync = true
            calendarError = "Calendar pending"
            alarmID = id
            alarmState = .failed
            alarmError = "Alarm pending"
        }
    }
}


final class SpeechCallbackTests: XCTestCase {
    func testOwnCategoryChangeDoesNotCancelNewRecording() {
        XCTAssertFalse(SpeechCallbacks.shouldInterruptRecording(for: .categoryChange))
        for reason in [AVAudioSession.RouteChangeReason.newDeviceAvailable, .oldDeviceUnavailable,
                       .noSuitableRouteForCategory, .routeConfigurationChange, .unknown] {
            XCTAssertTrue(SpeechCallbacks.shouldInterruptRecording(for: reason))
        }
        XCTAssertTrue(SpeechCallbacks.shouldInterruptRecording(for: nil))
    }

    @MainActor
    func testAudioTapCanDeliverFromBackgroundWithoutMainActor() async throws {
        let (stream, sink) = AsyncThrowingStream<AVAudioPCMBuffer, Error>.makeStream()
        let tap = MicrophoneCapture.tap(sink)
        // Only the callback crosses queues. Allocate the framework buffers on the invoking queue.
        DispatchQueue.global().async {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
            buffer.frameLength = 32
            buffer.floatChannelData![0].initialize(repeating: 0.25, count: 32)
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
            // Hardware owns and can reuse the original as soon as the tap returns.
            buffer.floatChannelData![0].update(repeating: -0.5, count: 32)
            sink.finish()
        }
        var received = 0
        for try await input in stream {
            received += 1
            XCTAssertEqual(input.format.commonFormat, .pcmFormatFloat32)
            XCTAssertEqual(input.frameLength, 32)
            XCTAssertEqual(input.floatChannelData![0][0], 0.25)
        }
        XCTAssertEqual(received, 1)
    }

    @MainActor
    func testAnalyzerConvertsFloat32BeforeCreatingInputAndDrainsTail() throws {
        let source = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                   channels: 1, interleaved: false)!
        let converter = try XCTUnwrap(AVAudioConverter(from: source, to: target))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4800))
        buffer.frameLength = 4800
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: 4800)
        var frames: AVAudioFrameCount = 0
        var heardSignal = false
        func inspect(_ input: AnalyzerInput?) {
            guard let input else { return }
            let pcm = input.buffer // Also works on iOS 26.
            XCTAssertEqual(pcm.format.commonFormat, .pcmFormatInt16)
            XCTAssertEqual(pcm.format.sampleRate, 16_000)
            XCTAssertEqual(pcm.format.channelCount, 1)
            XCTAssertNotNil(pcm.int16ChannelData)
            frames += pcm.frameLength
            if let samples = pcm.int16ChannelData?[0] {
                heardSignal = heardSignal || (0..<Int(pcm.frameLength)).contains { abs(Int(samples[$0]) - 8192) < 128 }
            }
        }
        // Fresh outputs are required: later conversion must not mutate earlier inputs.
        let first = try SpeechCallbacks.analyzerInput(converter, buffer: buffer)
        let firstBytes = first.input.map { input -> Data in
            let pcm = input.buffer
            return Data(bytes: pcm.int16ChannelData![0], count: Int(pcm.frameLength) * 2)
        }
        inspect(first.input)
        var ended = false
        for _ in 0..<8 {
            let tail = try SpeechCallbacks.analyzerInput(converter, buffer: nil)
            inspect(tail.input)
            if tail.status == .endOfStream || tail.input == nil { ended = true; break }
        }
        XCTAssertTrue(ended, "Converter did not finish EOF")
        XCTAssertGreaterThan(frames, 0)
        XCTAssertTrue(heardSignal, "Float32 0.25 should become approximately Int16 8192")
        if let input = first.input {
            let pcm = input.buffer
            XCTAssertEqual(Data(bytes: pcm.int16ChannelData![0], count: Int(pcm.frameLength) * 2), firstBytes)
        }
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(buffer.floatChannelData![0][0], 0.25)
    }

    @MainActor
    func testAnalyzerRejectsNonInt16DestinationAsAnErrorBeforeFrameworkPrecondition() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let converter = try XCTUnwrap(AVAudioConverter(from: format, to: format))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        XCTAssertThrowsError(try SpeechCallbacks.analyzerInput(converter, buffer: buffer))
    }

    @MainActor
    func testCancelReleasesCaptureAndIsSafeToRepeat() throws {
        let capture = TestMicrophone()
        let service = SpeechTranscriptionService(microphone: capture)
        // Simulate an owned capture without requesting system permissions or opening hardware.
        _ = try capture.start(format: capture.configure())
        XCTAssertTrue(capture.ownsResources)
        service.cancel(clearText: true)
        XCTAssertFalse(capture.ownsResources)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(service.text, "")
        service.cancel(clearText: true)
        XCTAssertFalse(capture.ownsResources)
        XCTAssertEqual(capture.stopCount, 2)
    }
}

@MainActor
private final class TestMicrophone: MicrophoneCapturing {
    private(set) var ownsResources = false
    private(set) var stopCount = 0
    private var continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation?
    func configure() throws -> AVAudioFormat {
        ownsResources = true
        return AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }
    func start(format: AVAudioFormat) throws -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let (stream, sink) = AsyncThrowingStream<AVAudioPCMBuffer, Error>.makeStream()
        continuation = sink
        return stream
    }
    func stop() {
        stopCount += 1
        continuation?.finish()
        continuation = nil
        ownsResources = false
    }
}

final class SpeechTranscriptTests: XCTestCase {
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }
    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(start: time(start), end: time(end))
    }
    private func part(_ text: String, _ start: Double, _ end: Double) -> SpeechTranscript.Part {
        SpeechTranscript.Part(text: text, range: range(start, end))
    }
    func testSuccessiveVolatilePhrasesSurviveUntilFinalizationWithoutReissue() {
        var transcript = SpeechTranscript()
        transcript.replace(range: range(0, 3), with: [part("Напомни завтра в восемь вечера", 0, 3)], finalizedThrough: .zero)
        transcript.replace(range: range(3, 5), with: [part("забрать посылку,", 3, 5)], finalizedThrough: .zero)
        transcript.replace(range: range(7, 11), with: [part("а после этого позвонить маме", 7, 11)], finalizedThrough: .zero)
        let full = "Напомни завтра в восемь вечера забрать посылку, а после этого позвонить маме"
        XCTAssertEqual(transcript.text, full)
        // Finalizing the last range also finalizes earlier unchanged volatile ranges.
        transcript.replace(range: range(7, 11), with: [part("а после этого позвонить маме", 7, 11)], finalizedThrough: time(11))
        XCTAssertEqual(transcript.text, full)
        // A duplicate final event and a stale volatile event cannot duplicate or rewrite history.
        transcript.replace(range: range(7, 11), with: [part("а после этого позвонить маме", 7, 11)], finalizedThrough: time(11))
        transcript.replace(range: range(0, 3), with: [part("старый вариант", 0, 3)], finalizedThrough: .zero)
        XCTAssertEqual(transcript.text, full)
    }
    func testIntermediateCorrectionReplacesOnlyItsAudioRange() {
        var transcript = SpeechTranscript()
        transcript.replace(range: range(0, 2), with: [part("завтра в семь", 0, 2)], finalizedThrough: .zero)
        transcript.replace(range: range(2, 4), with: [part("позвонить маме", 2, 4)], finalizedThrough: .zero)
        transcript.replace(range: range(0, 2), with: [part("завтра в восемь", 0, 2)], finalizedThrough: .zero)
        XCTAssertEqual(transcript.text, "завтра в восемь позвонить маме")
        transcript.replace(range: range(0, 4), with: [part("Завтра в восемь позвонить маме.", 0, 4)], finalizedThrough: time(4))
        XCTAssertEqual(transcript.text, "Завтра в восемь позвонить маме.")
    }
    func testSplitRangeKeepsUnchangedWordsOutsideReplacement() {
        var transcript = SpeechTranscript()
        transcript.replace(range: range(0, 4), with: [part("забрать", 0, 1), part("пакет", 1, 2), part("позвонить", 2, 3), part("маме", 3, 4)], finalizedThrough: .zero)
        transcript.replace(range: range(0, 2), with: [part("Забрать посылку,", 0, 2)], finalizedThrough: time(2))
        XCTAssertEqual(transcript.text, "Забрать посылку, позвонить маме")
        transcript.replace(range: range(2, 4), with: [part("позвонить маме.", 2, 4)], finalizedThrough: time(4))
        XCTAssertEqual(transcript.text, "Забрать посылку, позвонить маме.")
    }
    func testRetractionSilenceBoundariesAndDifferentTimeScales() {
        var transcript = SpeechTranscript()
        transcript.replace(range: range(0, 1), with: [part("позвонить", 0, 1)], finalizedThrough: time(1))
        transcript.replace(range: range(1, 2), with: [part("ошибка", 1, 2)], finalizedThrough: time(1))
        transcript.replace(range: range(1, 2), with: [], finalizedThrough: time(1))
        XCTAssertEqual(transcript.text, "позвонить")
        transcript.replace(range: CMTimeRange(start: CMTime(value: 3000, timescale: 1000), duration: CMTime(value: 1000, timescale: 1000)), with: [part("маме", 3, 4)], finalizedThrough: time(4))
        XCTAssertEqual(transcript.text, "позвонить маме")
        transcript.replace(range: .invalid, with: [part("неверно", 0, 1)], finalizedThrough: .invalid)
        XCTAssertEqual(transcript.text, "позвонить маме")
    }
    func testPunctuationDoesNotGetDuplicatedOrSeparatedFromWords() {
        var transcript = SpeechTranscript()
        transcript.replace(range: range(0, 1), with: [part("Напомни", 0, 1)], finalizedThrough: .zero)
        transcript.replace(range: range(1, 2), with: [part(",", 1, 2)], finalizedThrough: .zero)
        transcript.replace(range: range(2, 3), with: [part("пожалуйста.", 2, 3)], finalizedThrough: time(3))
        XCTAssertEqual(transcript.text, "Напомни, пожалуйста.")
    }
    @MainActor
    func testModernAttributedWordsPreserveSuffixAndUntimedPunctuation() {
        let speech = SpeechTranscriptionService()
        func timed(_ text: String, _ start: Double, _ end: Double) -> AttributedString {
            var value = AttributedString(text)
            value[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = range(start, end)
            return value
        }
        let phrase = timed("забрать ", 0, 1) + timed("пакет", 1, 2) + AttributedString(",")
        speech.accept(phrase, range: range(0, 2), finalizedThrough: .zero)
        speech.accept(AttributedString("позвонить маме."), range: range(3, 5), finalizedThrough: .zero)
        speech.accept(timed("посылку", 1, 2) + AttributedString(","), range: range(1, 2), finalizedThrough: time(2))
        XCTAssertEqual(speech.text, "забрать посылку, позвонить маме.")
        speech.accept(AttributedString("позвонить маме."), range: range(3, 5), finalizedThrough: time(5))
        XCTAssertEqual(speech.text, "забрать посылку, позвонить маме.")
        speech.cancel(clearText: true)
        XCTAssertEqual(speech.text, "")
    }


}

@MainActor
final class OptionalVoiceTaskTests: XCTestCase {
    func testManualFieldsSurviveNewInterpretationAndResetForNextRecording() {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        var fields = VoiceTaskFields()
        fields.apply(ReminderDraft(sourceText: "first", title: "Parsed", date: date, warnings: []))
        fields.editDate(date.addingTimeInterval(600))
        fields.editAlarm(false)
        fields.apply(ReminderDraft(sourceText: "corrected", title: "New parser title", date: date.addingTimeInterval(1200), warnings: []))
        XCTAssertEqual(fields.date, date.addingTimeInterval(600))
        XCTAssertFalse(fields.alarmEnabled)
        fields = VoiceTaskFields()
        fields.apply(ReminderDraft(sourceText: "undated", title: "Undated", date: nil, warnings: [.missingDate]))
        XCTAssertNil(fields.date)
        XCTAssertFalse(fields.alarmEnabled)
    }

    func testConfirmationUsesVisibleTextEvenWithStaleInterpretation() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var fields = VoiceTaskFields()
        fields.apply(ReminderDraft(sourceText: "old request", title: "Hidden parsed title", date: now.addingTimeInterval(600), warnings: []))
        let chosenDate = now.addingTimeInterval(1200)
        let rule = RecurrenceRule(unit: .days, interval: 3)
        fields.editDate(chosenDate)
        fields.editAlarm(false)
        fields.editRecurrence(rule)
        var input = VoiceTextBuffer()
        input.edit("  Полная исправленная фраза\nи продолжение  ")
        // Even an already queued interpretation can only fill untouched parameters.
        fields.apply(ReminderDraft(sourceText: "old request", title: "Another stale title", date: now.addingTimeInterval(1800), warnings: []))
        let snapshot = fields.draft(text: input.text)
        input.edit("Правка после нажатия Create")
        let creation = VoiceCreation()
        _ = try await creation.confirm(draft: snapshot, now: now) { title, date in
            XCTAssertEqual(title, "  Полная исправленная фраза\nи продолжение  ")
            XCTAssertEqual(date, chosenDate)
            return UUID()
        }
        XCTAssertEqual(snapshot.title, snapshot.sourceText)
        XCTAssertFalse(snapshot.alarmEnabled)
        XCTAssertEqual(snapshot.recurrence, rule)
        XCTAssertThrowsError(try fields.draft(text: " \n ").validated(now: now))
    }

    func testTypedRepeatDraftKeepsFullRequestAndManualRepeat() throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let rule = RecurrenceRule(unit: .weeks, interval: 2, timeZoneID: "Europe/Moscow")
        let draft = ReminderDraft(sourceText: "Полная исходная фраза", title: "Короткое название", date: now.addingTimeInterval(600), warnings: [], alarmEnabled: false, recurrence: rule)
        XCTAssertNoThrow(try draft.validated(now: now))
        XCTAssertEqual(draft.sourceText, "Полная исходная фраза")
        var fields = VoiceTaskFields()
        fields.apply(draft)
        XCTAssertFalse(fields.alarmEnabled)
        fields.editRecurrence(RecurrenceRule(unit: .days, interval: 3))
        fields.apply(draft)
        XCTAssertEqual(fields.recurrence?.unit, .days)
        XCTAssertEqual(fields.recurrence?.interval, 3)
        let roundTrip = try JSONDecoder().decode(RecurrenceRule.self, from: JSONEncoder().encode(rule))
        XCTAssertEqual(roundTrip, rule)
        var undated = draft
        undated.date = nil
        XCTAssertThrowsError(try undated.validated(now: now))
    }

    func testUndatedTaskAndDisplayedFutureDateNeedNoHiddenConfirmation() async throws {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let noDate = ReminderDraft(sourceText: "Позвонить маме", title: "Позвонить маме", date: nil, warnings: [.missingDate])
        XCTAssertTrue(noDate.canCreate(now: now, alarmEnabled: false))
        XCTAssertFalse(noDate.canCreate(now: now, alarmEnabled: true))
        var dated = noDate
        dated.date = now.addingTimeInterval(600)
        XCTAssertTrue(dated.canCreate(now: now, alarmEnabled: true))
        let creation = VoiceCreation()
        var saves = 0
        let id = UUID()
        let created = try await creation.confirm(draft: noDate, now: now, alarmEnabled: false) { title, date in
            saves += 1
            XCTAssertEqual(title, "Позвонить маме")
            XCTAssertNil(date)
            return id
        }
        XCTAssertEqual(created, id)
        _ = try await creation.confirm(draft: noDate, now: now, alarmEnabled: false) { _, _ in saves += 1; return UUID() }
        XCTAssertEqual(saves, 1)
    }
}

final class VoiceTextBufferTests: XCTestCase {
    func testDictateEditDictateEditDictateAndLateFieldCommit() {
        var input = VoiceTextBuffer()
        let first = input.begin()
        input.update("Первая фраза", session: first)
        input.finish(session: first)
        input.edit("Первая фраза (это я написал вручную)")
        let second = input.begin()
        // Losing keyboard focus can send the same binding value after begin().
        input.edit(input.text)
        input.update("запоздалый первый результат", session: first)
        input.update("вторая гипотеза", session: second)
        input.update("вторая фраза", session: second)
        input.finish(session: second)
        input.edit(input.text + " и ещё вручную")
        let third = input.begin()
        input.edit(input.text)
        input.update("старый callback", session: second)
        input.update("третья фраза", session: third)
        input.finish(session: third)
        XCTAssertEqual(input.text, "Первая фраза (это я написал вручную) вторая фраза и ещё вручную третья фраза")
    }

    func testContinuationPreservesManualEditsAndRejectsLateResults() {
        var input = VoiceTextBuffer()
        let first = input.begin()
        input.update("забрать посылку", session: first)
        input.finish(session: first)
        input.edit("Забрать посылку завтра")
        input.update("старый callback", session: first)
        XCTAssertEqual(input.text, "Забрать посылку завтра")
        let second = input.begin()
        input.update("и позвонить", session: second)
        input.update("и позвонить маме", session: second)
        input.finish(session: second)
        XCTAssertEqual(input.text, "Забрать посылку завтра и позвонить маме")
        input.update("late", session: second)
        XCTAssertEqual(input.text, "Забрать посылку завтра и позвонить маме")
        input.edit("")
        XCTAssertEqual(input.text, "")
    }
}

final class SnoozeAndVersionTests: XCTestCase {
    func testMinutesSliderAndKeyboardKeepActualOutOfScaleValue() {
        var minutes = SnoozeMinutes()
        minutes.slide(to: 35)
        XCTAssertEqual(minutes.value, 35)
        XCTAssertEqual(minutes.text, "35")
        minutes.text = "90"
        XCTAssertEqual(minutes.sliderValue, 90)
        minutes.text = "1440"
        XCTAssertEqual(minutes.value, 1440)
        XCTAssertEqual(minutes.sliderValue, 120)
        XCTAssertEqual(minutes.text, "1440")
        for invalid in ["", "0", "-1", "1.5", "1441", " 35", "abc", "999999999999999999999"] {
            minutes.text = invalid
            XCTAssertNil(minutes.value)
        }
    }
    func testInstalledVersionUsesBundleValues() {
        XCTAssertEqual(InstalledVersion(info: ["CFBundleShortVersionString": "0.5.0", "CFBundleVersion": "7"]).display, "0.5.0.7")
        XCTAssertEqual(InstalledVersion(info: ["CFBundleShortVersionString": "0.5.0", "CFBundleVersion": "42"]).display, "0.5.0.42")
    }
}
