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
        for phrase in ["Завтра забрать посылку", "Позвонить маме", "В 18:00 позвонить", "Завтра в 9 или в 10 выйти", "Завтра и послезавтра в 9 выйти", "Каждый второй вторник в 15:00 выйти", "31 ноября в 12 выйти", "Завтра в 25:90 выйти", "Через 2 часа 10 минут выйти", "Завтра в 10:5 выйти", "Завтра в 10:100 выйти", "Завтра в 15:30:45 выйти", "Завтра в 10:10:45 выйти"] {
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
