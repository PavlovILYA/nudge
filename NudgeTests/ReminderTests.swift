import SwiftData
import XCTest
@testable import Nudge

@MainActor
final class ReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCreationValidation() throws {
        XCTAssertThrowsError(try Reminder(title: " \n ", scheduledAt: now.addingTimeInterval(60), now: now))
        XCTAssertThrowsError(try Reminder(title: "Task", scheduledAt: now, now: now))
        XCTAssertThrowsError(try Reminder(title: "Task", scheduledAt: now.addingTimeInterval(-1), now: now))
        let reminder = try Reminder(title: "  Task\n", scheduledAt: now.addingTimeInterval(60), now: now)
        XCTAssertEqual(reminder.title, "Task")
        XCTAssertEqual(reminder.createdAt, now)
    }

    func testClassificationAndExplicitCompletion() throws {
        let reminder = try Reminder(title: "Task", scheduledAt: now.addingTimeInterval(60), now: now)
        XCTAssertEqual(reminder.state(at: now), .pending)
        XCTAssertEqual(reminder.state(at: now.addingTimeInterval(60)), .overdue)
        reminder.alarmState = .absent // A stopped/missing alarm never completes its task.
        XCTAssertNil(reminder.completedAt)
        XCTAssertEqual(reminder.state(at: now.addingTimeInterval(120)), .overdue)
        reminder.completedAt = now.addingTimeInterval(120)
        XCTAssertEqual(reminder.state(at: now), .completed)
    }

    func testPersistentIdentifiersAndDatesSurviveReopeningStore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("reminders.store"))
        let identifier = UUID()
        let date = now.addingTimeInterval(120)
        do {
            let container = try ModelContainer(for: Reminder.self, configurations: configuration)
            let context = ModelContext(container)
            let reminder = try Reminder(id: identifier, title: "Persist", scheduledAt: date, now: now)
            context.insert(reminder)
            try context.save()
        }
        let reopened = try ModelContainer(for: Reminder.self, configurations: configuration)
        let saved = try ModelContext(reopened).fetch(FetchDescriptor<Reminder>())
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.id, identifier)
        XCTAssertEqual(saved.first?.alarmID, identifier)
        XCTAssertEqual(saved.first?.scheduledAt, date)
        XCTAssertEqual(saved.first?.alarmState, .unconfirmed)
    }

    func testCreationPersistsBeforeSchedulingAndKeepsTaskOnFailure() async throws {
        let context = try memoryContext()
        let alarms = AlarmService(schedule: { id, _, date in
            let saved = try context.fetch(FetchDescriptor<Reminder>())
            XCTAssertEqual(saved.first?.alarmID, id)
            XCTAssertFalse(context.hasChanges)
            XCTAssertEqual(saved.first?.scheduledAt, date)
            throw TestError.denied
        }, cancel: { _ in }, alarmIDs: { [] })
        let store = ReminderStore(context: context, alarms: alarms)
        let saved = await store.create(title: "Task", date: Date.now.addingTimeInterval(3600))
        XCTAssertTrue(saved)
        let reminder = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertNil(reminder.completedAt)
        XCTAssertEqual(reminder.alarmState, .failed)
        XCTAssertNotNil(reminder.alarmError)
    }

    func testCancelFailureRetainsIncompleteTaskAndAllowsRetry() throws {
        let context = try memoryContext()
        let reminder = try Reminder(title: "Task", scheduledAt: now.addingTimeInterval(60), now: now)
        context.insert(reminder)
        try context.save()
        let failing = ReminderStore(context: context, alarms: AlarmService(
            schedule: { _, _, _ in }, cancel: { _ in throw TestError.denied }, alarmIDs: { [] }))
        failing.complete(reminder)
        XCTAssertNil(reminder.completedAt)
        failing.delete(reminder)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Reminder>()), 1)
        XCTAssertNotNil(failing.errorMessage)
        let working = ReminderStore(context: context, alarms: AlarmService(
            schedule: { _, _, _ in }, cancel: { XCTAssertEqual($0, reminder.alarmID) }, alarmIDs: { [] }))
        working.complete(reminder)
        XCTAssertNotNil(reminder.completedAt)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Reminder>()), 1)
        working.delete(reminder)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Reminder>()), 0)
    }

    func testRefreshDoesNotScheduleOrCompleteMissingAlarms() throws {
        let context = try memoryContext()
        let reminder = try Reminder(title: "Task", scheduledAt: now.addingTimeInterval(60), now: now)
        context.insert(reminder)
        try context.save()
        let store = ReminderStore(context: context, alarms: AlarmService(
            schedule: { _, _, _ in XCTFail("Refresh must not reschedule") },
            cancel: { _ in XCTFail("Refresh must not cancel") }, alarmIDs: { [] }))
        store.refresh()
        XCTAssertNil(reminder.completedAt)
        XCTAssertEqual(reminder.alarmState, .absent)
        XCTAssertEqual(reminder.id, reminder.alarmID)
    }

    func testFiveSnoozeIntervalsAndDateValidation() throws {
        XCTAssertEqual(SnoozeInterval.allCases.map(\.rawValue), [5, 10, 15, 30, 60])
        for interval in SnoozeInterval.allCases {
            XCTAssertEqual(interval.date(from: now).timeIntervalSince(now), Double(interval.rawValue * 60))
        }
        XCTAssertThrowsError(try Reminder.validateSnoozeDate(now, now: now))
        XCTAssertThrowsError(try Reminder.validateSnoozeDate(now.addingTimeInterval(-1), now: now))
        XCTAssertThrowsError(try Reminder.validateSnoozeDate(Date(timeIntervalSince1970: .infinity), now: now))
        XCTAssertNoThrow(try Reminder.validateSnoozeDate(now.addingTimeInterval(1), now: now))
    }

    func testSnoozePersistsNewTimeWithoutCompletingOrDuplicating() async throws {
        let context = try memoryContext()
        let original = Date.now.addingTimeInterval(3600)
        let target = original.addingTimeInterval(300)
        let reminder = try Reminder(title: "Task", scheduledAt: original)
        context.insert(reminder)
        try context.save()
        var registered = [reminder.alarmID: original]
        var schedules = 0
        let store = ReminderStore(context: context, alarms: AlarmService(
            schedule: { id, _, date in
                XCTAssertTrue(registered.isEmpty)
                XCTAssertEqual(reminder.pendingSnoozeAt, target)
                XCTAssertFalse(context.hasChanges)
                schedules += 1
                registered[id] = date
            }, cancel: { registered.removeValue(forKey: $0) },
            scheduledAlarms: { registered }))
        let result = await store.snooze(id: reminder.id, until: target)
        XCTAssertTrue(result)
        XCTAssertEqual(reminder.scheduledAt, original)
        XCTAssertEqual(reminder.nextAlarmAt, target)
        XCTAssertNil(reminder.pendingSnoozeAt)
        XCTAssertNil(reminder.completedAt)
        XCTAssertEqual(reminder.alarmState, .registered)
        XCTAssertEqual(registered.count, 1)
        let repeated = await store.snooze(id: reminder.id, until: target)
        XCTAssertTrue(repeated)
        XCTAssertEqual(schedules, 1)
        let fresh = ModelContext(context.container)
        let saved = try XCTUnwrap(fresh.fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertEqual(saved.nextAlarmAt, target)
        XCTAssertEqual(saved.scheduledAt, original)
        XCTAssertNil(saved.completedAt)
    }

    private func memoryContext() throws -> ModelContext {
        let container = try ModelContainer(for: Reminder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private enum TestError: Error { case denied }
}
