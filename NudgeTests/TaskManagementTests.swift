import SwiftData
import XCTest
@testable import Nudge

@MainActor
final class TaskManagementTests: XCTestCase {
    func testEditKeepsUUIDAndSnoozeWhileMoveResetsDeadline() async throws {
        let context = try memory()
        let original = Date.now.addingTimeInterval(600)
        let reminder = try Reminder(title: "Before", scheduledAt: original)
        context.insert(reminder)
        try context.save()
        var registrations = [reminder.alarmID: original]
        var titles: [String] = []
        let store = ReminderStore(context: context, alarms: AlarmService(
            schedule: { id, title, date, _ in registrations[id] = date; titles.append(title) },
            cancel: { registrations.removeValue(forKey: $0) }, scheduledAlarms: { registrations }))
        let id = reminder.id
        let snoozed = original.addingTimeInterval(300)
        let snooze = await store.snooze(id: id, until: snoozed)
        XCTAssertTrue(snooze)
        XCTAssertEqual(reminder.scheduledAt, original)
        let edited = await store.edit(id: id, title: "After", date: original, sound: .soft, calendarEnabled: false, calendarID: nil)
        XCTAssertTrue(edited)
        XCTAssertEqual(reminder.id, id)
        XCTAssertEqual(reminder.title, "After")
        XCTAssertEqual(reminder.nextAlarmAt, snoozed)
        XCTAssertEqual(registrations[id], snoozed)
        let tomorrow = original.addingTimeInterval(86400)
        let moved = await store.edit(id: id, title: "After", date: tomorrow, sound: .soft, calendarEnabled: false, calendarID: nil)
        XCTAssertTrue(moved)
        XCTAssertEqual(reminder.scheduledAt, tomorrow)
        XCTAssertNil(reminder.nextAlarmAt)
        XCTAssertNil(reminder.pendingSnoozeAt)
        XCTAssertEqual(reminder.state(at: original.addingTimeInterval(400)), .pending)
        XCTAssertEqual(registrations.count, 1)
        XCTAssertEqual(registrations[id], tomorrow)
        XCTAssertEqual(titles.last, "After")
    }

    func testDisableDoesNotCompleteOrResurrectOnMetadataEdit() async throws {
        let context = try memory()
        let reminder = try Reminder(title: "Task", scheduledAt: Date.now.addingTimeInterval(600))
        context.insert(reminder)
        try context.save()
        var ids = [reminder.id: reminder.scheduledAt]
        let store = ReminderStore(context: context, alarms: AlarmService(
            schedule: { _, _, _, _ in XCTFail("Disabled alarm must stay disabled") },
            cancel: { ids.removeValue(forKey: $0) }, scheduledAlarms: { ids }))
        store.disableAlarm(reminder)
        store.refresh()
        XCTAssertNil(reminder.completedAt)
        XCTAssertTrue(reminder.alarmDisabled == true)
        XCTAssertNil(store.activeAlarmDate(for: reminder))
        let edited = await store.edit(id: reminder.id, title: "Renamed", date: reminder.scheduledAt, sound: .prominent, calendarEnabled: false, calendarID: nil)
        XCTAssertTrue(edited)
        XCTAssertEqual(reminder.sound, .prominent)
        XCTAssertTrue(ids.isEmpty)
    }

    func testActiveAlarmsUseSystemSnapshotAndExcludeCompletedAndStaleDates() throws {
        let context = try memory()
        let date = Date.now.addingTimeInterval(600)
        let reminder = try Reminder(title: "Task", scheduledAt: date)
        reminder.nextAlarmAt = date
        reminder.alarmState = .registered
        context.insert(reminder)
        try context.save()
        var registered: [UUID: Date] = [:]
        var failRead = false
        let store = ReminderStore(context: context, alarms: AlarmService(
            schedule: { _, _, _, _ in }, cancel: { registered.removeValue(forKey: $0) },
            scheduledAlarms: { if failRead { throw TestError.failed }; return registered }))
        store.refresh()
        XCTAssertNil(store.activeAlarmDate(for: reminder))
        registered[reminder.id] = date
        store.refresh()
        XCTAssertEqual(store.activeAlarmDate(for: reminder), date)
        failRead = true
        store.refresh()
        XCTAssertNil(store.activeAlarmDate(for: reminder))
        failRead = false
        store.refresh()
        store.complete(reminder)
        XCTAssertNotNil(reminder.completedAt)
        XCTAssertTrue(registered.isEmpty)
        XCTAssertNil(store.activeAlarmDate(for: reminder))
    }

    func testCalendarCreateEditSnoozeAndDeleteWithoutDuplicates() async throws {
        let context = try memory()
        var events: [UUID: CalendarRequest] = [:]
        var writes = 0
        let calendar = CalendarService(hasAccess: { true }, upsert: { request in
            events[request.id] = request
            writes += 1
            return CalendarIdentity(eventID: "event", externalID: "external", calendarID: "calendar")
        }, remove: { events.removeValue(forKey: $0.id) })
        let store = ReminderStore(context: context, alarms: fakeAlarms(), calendar: calendar)
        let date = Date.now.addingTimeInterval(600)
        let created = await store.create(title: "Task", date: date, sound: .experimentalVibrationOnly, calendarEnabled: true, calendarID: "calendar")
        XCTAssertTrue(created)
        let reminder = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertEqual(reminder.calendarEventID, "event")
        XCTAssertEqual(reminder.calendarExternalID, "external")
        XCTAssertEqual(events[reminder.id]?.date, date)
        XCTAssertEqual(events[reminder.id]?.endDate, date.addingTimeInterval(900))
        XCTAssertEqual(events[reminder.id]?.url, ReminderLink.url(for: reminder.id))
        let before = writes
        let snoozed = await store.snooze(id: reminder.id, until: date.addingTimeInterval(300))
        XCTAssertTrue(snoozed)
        XCTAssertEqual(writes, before)
        XCTAssertEqual(events[reminder.id]?.date, date)
        let newDate = date.addingTimeInterval(86400)
        let edited = await store.edit(id: reminder.id, title: "Changed", date: newDate, sound: reminder.sound, calendarEnabled: true, calendarID: "calendar")
        XCTAssertTrue(edited)
        XCTAssertEqual(events[reminder.id]?.title, "Changed")
        XCTAssertEqual(events[reminder.id]?.date, newDate)
        store.retryCalendar(reminder)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(reminder.sound, .experimentalVibrationOnly)
        store.delete(reminder)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Reminder>()), 0)
    }

    func testCalendarDenialDoesNotLoseTaskOrWorkingAlarm() async throws {
        let context = try memory()
        var registrations: [UUID: Date] = [:]
        let store = ReminderStore(context: context, alarms: AlarmService(
            schedule: { id, _, date, _ in registrations[id] = date }, cancel: { registrations.removeValue(forKey: $0) }, scheduledAlarms: { registrations }),
            calendar: CalendarService(hasAccess: { false }, upsert: { _ in XCTFail("No permission"); throw TestError.failed }, remove: { _ in throw TestError.failed }))
        let created = await store.create(title: "Task", date: Date.now.addingTimeInterval(600), calendarEnabled: true, calendarID: "calendar")
        XCTAssertTrue(created)
        let reminder = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertEqual(registrations.count, 1)
        XCTAssertNil(reminder.completedAt)
        XCTAssertNotNil(reminder.calendarError)
        XCTAssertNil(reminder.calendarEventDate)
    }

    func testUnknownCalendarWriteIsRecoveredByIdentityWithoutNewInsert() async throws {
        let context = try memory()
        var event: CalendarRequest?
        var first = true
        let calendar = CalendarService(hasAccess: { true }, upsert: { request in
            if event == nil { XCTAssertTrue(request.allowCreate); event = request }
            else { XCTAssertFalse(request.allowCreate) }
            if first { first = false; throw TestError.failed }
            return CalendarIdentity(eventID: "recovered", externalID: "stable", calendarID: "calendar")
        }, remove: { _ in throw TestError.failed })
        let store = ReminderStore(context: context, alarms: fakeAlarms(), calendar: calendar)
        _ = await store.create(title: "Task", date: Date.now.addingTimeInterval(600), calendarEnabled: true, calendarID: "calendar")
        let reminder = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertNotNil(reminder.calendarEventDate)
        XCTAssertNotNil(reminder.calendarError)
        store.retryCalendar(reminder)
        XCTAssertEqual(reminder.calendarEventID, "recovered")
        XCTAssertNil(reminder.calendarError)
        store.delete(reminder)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Reminder>()), 1)
        XCTAssertNil(reminder.completedAt)
    }

    func testURLValidationAndOwnershipRequireUUIDAndMarker() {
        let id = UUID()
        let url = ReminderLink.url(for: id)
        XCTAssertEqual(ReminderLink.id(from: url), id)
        XCTAssertTrue(CalendarRequest.owns(url: url, notes: CalendarRequest.marker(for: id), id: id))
        XCTAssertFalse(CalendarRequest.owns(url: url, notes: "Foreign event", id: id))
        XCTAssertFalse(CalendarRequest.owns(url: ReminderLink.url(for: UUID()), notes: CalendarRequest.marker(for: id), id: id))
        for invalid in ["nudge://reminder/no", "nudge://reminder/\(id)/more", "https://reminder/\(id)", "nudge://wrong/\(id)"] {
            XCTAssertNil(ReminderLink.id(from: URL(string: invalid)!))
        }
    }

    private func memory() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Reminder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }
    private func fakeAlarms() -> AlarmService {
        AlarmService(schedule: { _, _, _, _ in }, cancel: { _ in }, scheduledAlarms: { [:] })
    }
    private enum TestError: Error { case failed }
}
