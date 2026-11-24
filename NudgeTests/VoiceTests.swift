import AVFoundation
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
    func testVersion040StoreKeepsTasksAlarmAndCalendarIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfiguration(url: directory.appendingPathComponent("legacy040.store"))
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let id = UUID()
        do {
            let old = try ModelContainer(for: Legacy040.Reminder.self, configurations: config)
            let context = ModelContext(old)
            context.insert(Legacy040.Reminder(id: id, date: date))
            let completed = Legacy040.Reminder(id: UUID(), date: date)
            completed.completedAt = date
            context.insert(completed)
            try context.save()
        }
        let current = try ModelContainer(for: Reminder.self, configurations: config)
        let items = try ModelContext(current).fetch(FetchDescriptor<Reminder>())
        XCTAssertEqual(items.count, 2)
        let saved = try XCTUnwrap(items.first { $0.id == id })
        XCTAssertEqual(saved.title, "Legacy 0.4.0")
        XCTAssertEqual(saved.alarmID, id)
        XCTAssertEqual(saved.scheduledAt, date)
        XCTAssertEqual(saved.createdAt, date.addingTimeInterval(-60))
        XCTAssertEqual(saved.nextAlarmAt, date.addingTimeInterval(300))
        XCTAssertEqual(saved.pendingSnoozeAt, date.addingTimeInterval(600))
        XCTAssertEqual(saved.sound, .experimentalVibrationOnly)
        XCTAssertEqual(saved.alarmDisabled, false)
        XCTAssertEqual(saved.alarmNeedsUpdate, true)
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

// Frozen 0.4.0 persisted fields. 0.5.0 deliberately adds no model properties.
private enum Legacy040 {
    @Model final class Reminder {
        @Attribute(.unique) var id: UUID
        var title: String
        var scheduledAt: Date
        var createdAt: Date
        var nextAlarmAt: Date?
        var pendingSnoozeAt: Date?
        var soundModeID: String?
        var alarmDisabled: Bool?
        var alarmNeedsUpdate: Bool?
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
            title = "Legacy 0.4.0"
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
    @MainActor
    func testAuthorizationFromBackgroundResumesCallerOnMainActor() async {
        for expected in [SFSpeechRecognizerAuthorizationStatus.authorized, .denied, .restricted, .authorized] {
            let status = await SpeechCallbacks.authorization { reply in
                DispatchQueue.global().async {
                    dispatchPrecondition(condition: .notOnQueue(.main))
                    reply(expected)
                }
            }
            // This assertion reproduces the actor context in which the real crash occurred.
            MainActor.assertIsolated()
            XCTAssertEqual(status, expected)
        }
    }

    @MainActor
    func testAlreadyAuthorizedSynchronousCallbackAndRepeatedRequests() async {
        for _ in 0..<2 {
            let status = await SpeechCallbacks.authorization { reply in reply(.authorized) }
            XCTAssertEqual(status, .authorized)
        }
    }

    @MainActor
    func testRecognitionCallbackHopsBeforeAccessingActorState() async {
        let delivered = expectation(description: "MainActor recognition delivery")
        let callback = SpeechCallbacks.recognition { update in
            MainActor.assertIsolated()
            XCTAssertNil(update.text)
            XCTAssertFalse(update.final)
            XCTAssertEqual(update.errorDomain, "SpeechCallbackTest")
            XCTAssertEqual(update.errorCode, 42)
            delivered.fulfill()
        }
        DispatchQueue.global().async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            callback(nil, NSError(domain: "SpeechCallbackTest", code: 42))
        }
        await fulfillment(of: [delivered], timeout: 3)
    }

    @MainActor
    func testAudioTapCanDeliverFromBackgroundWithoutMainActor() async throws {
        let (stream, sink) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream()
        let tap = MicrophoneCapture.tap(sink)
        // Only the callback crosses queues. Allocate the framework buffers on the invoking queue.
        DispatchQueue.global().async {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)!
            buffer.frameLength = 32
            buffer.floatChannelData![0].initialize(repeating: 0.25, count: 32)
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000))
            sink.finish()
        }
        var received = 0
        for try await input in stream {
            received += 1
            XCTAssertEqual(input.buffer.frameLength, 32)
            XCTAssertEqual(input.buffer.floatChannelData![0][0], 0.25)
        }
        XCTAssertEqual(received, 1)
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
    private var continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?
    func configure() throws -> AVAudioFormat {
        ownsResources = true
        return AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }
    func start(format: AVAudioFormat) throws -> AsyncThrowingStream<AnalyzerInput, Error> {
        let (stream, sink) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream()
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
