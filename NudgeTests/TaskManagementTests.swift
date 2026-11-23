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

    func testFailedMetadataEditCannotBeReconciledByDateAlone() async throws {
        let context = try memory()
        let date = Date.now.addingTimeInterval(600)
        let reminder = try Reminder(title: "Before", scheduledAt: date)
        context.insert(reminder)
        try context.save()
        var fail = true
        var registrations = [reminder.id: date]
        var acceptedTitles: [String] = []
        let store = ReminderStore(context: context, alarms: AlarmService(
            schedule: { id, title, when, _ in
                registrations[id] = when
                if fail { throw TestError.failed }
                acceptedTitles.append(title)
            }, cancel: { registrations.removeValue(forKey: $0) }, scheduledAlarms: { registrations }))
        let result = await store.edit(id: reminder.id, title: "After", date: date, sound: .soft, calendarEnabled: false, calendarID: nil)
        XCTAssertFalse(result)
        XCTAssertEqual(reminder.title, "After")
        XCTAssertTrue(reminder.alarmNeedsUpdate == true)
        store.refresh()
        XCTAssertTrue(reminder.alarmNeedsUpdate == true)
        XCTAssertEqual(reminder.alarmState, .failed)
        fail = false
        let retried = await store.snooze(id: reminder.id, until: date)
        XCTAssertTrue(retried)
        XCTAssertEqual(acceptedTitles, ["After"])
        XCTAssertFalse(reminder.alarmNeedsUpdate == true)
    }

    func testCalendarUnlinkAndCompletionKeepEvents() async throws {
        let context = try memory()
        var writes = 0
        var removals = 0
        let store = ReminderStore(context: context, alarms: fakeAlarms(), calendar: CalendarService(
            hasAccess: { true }, upsert: { _ in writes += 1; return CalendarIdentity(eventID: "event", externalID: nil, calendarID: "calendar") },
            remove: { _ in removals += 1 }))
        _ = await store.create(title: "Task", date: Date.now.addingTimeInterval(600), calendarEnabled: true, calendarID: "calendar")
        let reminder = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        let unlinked = await store.edit(id: reminder.id, title: reminder.title, date: reminder.scheduledAt, sound: reminder.sound, calendarEnabled: false, calendarID: "calendar")
        XCTAssertTrue(unlinked)
        store.refreshCalendar()
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(reminder.calendarEventID, "event")
        store.complete(reminder)
        XCTAssertEqual(removals, 0)
        XCTAssertNotNil(reminder.completedAt)
        XCTAssertNil(store.activeAlarmDate(for: reminder))
    }

    func testPermissionRetryCreatesFirstEventAndMissingLinkedEventDoesNotCreateCopy() async throws {
        let context = try memory()
        var access = false
        var missing = false
        var writes = 0
        let store = ReminderStore(context: context, alarms: fakeAlarms(), calendar: CalendarService(
            hasAccess: { access }, upsert: { request in
                if missing { XCTAssertFalse(request.allowCreate); throw CalendarError.missing }
                XCTAssertTrue(request.allowCreate)
                writes += 1
                return CalendarIdentity(eventID: "event", externalID: "external", calendarID: "calendar")
            }, remove: { _ in }))
        _ = await store.create(title: "Task", date: Date.now.addingTimeInterval(600), calendarEnabled: true, calendarID: "calendar")
        let reminder = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertNil(reminder.calendarEventDate)
        access = true
        store.retryCalendar(reminder)
        XCTAssertEqual(writes, 1)
        missing = true
        store.retryCalendar(reminder)
        store.refreshCalendar()
        XCTAssertEqual(writes, 1)
        XCTAssertNotNil(reminder.calendarError)
        XCTAssertEqual(reminder.calendarEventID, "event")
        XCTAssertNil(reminder.completedAt)
    }

    func testVersion030StoreMigrationPreservesEveryExistingField() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("legacy030.store"))
        let id = UUID()
        let date = Date.now.addingTimeInterval(600)
        do {
            let container = try ModelContainer(for: Legacy030.Reminder.self, configurations: configuration)
            let context = ModelContext(container)
            let item = Legacy030.Reminder(id: id, date: date)
            context.insert(item)
            let completed = Legacy030.Reminder(id: UUID(), date: date)
            completed.completedAt = date
            context.insert(completed)
            try context.save()
        }
        let container = try ModelContainer(for: Reminder.self, configurations: configuration)
        let items = try ModelContext(container).fetch(FetchDescriptor<Reminder>())
        XCTAssertEqual(items.count, 2)
        let item = try XCTUnwrap(items.first { $0.id == id })
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.alarmID, id)
        XCTAssertEqual(item.title, "Legacy 0.3.0")
        XCTAssertEqual(item.scheduledAt, date)
        XCTAssertEqual(item.createdAt, date.addingTimeInterval(-60))
        XCTAssertEqual(item.nextAlarmAt, date.addingTimeInterval(300))
        XCTAssertEqual(item.pendingSnoozeAt, date.addingTimeInterval(600))
        XCTAssertEqual(item.sound, .experimentalVibrationOnly)
        XCTAssertEqual(item.alarmState, .failed)
        XCTAssertEqual(item.alarmError, "Legacy error")
        XCTAssertNil(item.completedAt)
        XCTAssertEqual(items.filter { $0.completedAt == date }.count, 1)
        XCTAssertNil(item.calendarEnabled)
        XCTAssertNil(item.calendarEventID)
        XCTAssertNil(item.calendarEventDate)
        XCTAssertNil(item.alarmDisabled)
        XCTAssertNil(item.alarmNeedsUpdate)
    }

    func testCreationFinalSaveFailureStillReportsDurableTask() async throws {
        let context = try memory()
        var saves = 0
        var registrations: [UUID: Date] = [:]
        let store = ReminderStore(context: context, alarms: AlarmService(
            schedule: { id, _, date, _ in registrations[id] = date }, cancel: { _ in }, scheduledAlarms: { registrations }),
            save: { context in saves += 1; if saves == 2 { throw TestError.failed }; try context.save() })
        let saved = await store.create(title: "Task", date: Date.now.addingTimeInterval(600))
        XCTAssertTrue(saved, "The creation sheet must dismiss once the UUID is durably saved")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Reminder>()), 1)
        XCTAssertEqual(registrations.count, 1)
        XCTAssertNotNil(store.errorMessage)
    }

    func testNativeStopDuringEditAuthorizationDoesNotRecreateAlarm() async throws {
        let context = try memory()
        let date = Date.now.addingTimeInterval(600)
        let reminder = try Reminder(title: "Before", scheduledAt: date)
        context.insert(reminder)
        try context.save()
        var registrations = [reminder.id: date]
        let store = ReminderStore(context: context, alarms: AlarmService(
            authorize: { registrations = [:] },
            schedule: { _, _, _, _ in XCTFail("Native Stop must be respected") },
            cancel: { _ in XCTFail("Do not replace an absent alarm") }, scheduledAlarms: { registrations }))
        let saved = await store.edit(id: reminder.id, title: "After", date: date, sound: .soft, calendarEnabled: false, calendarID: nil)
        XCTAssertTrue(saved)
        XCTAssertEqual(reminder.title, "After")
        XCTAssertTrue(registrations.isEmpty)
        XCTAssertNil(reminder.completedAt)
        XCTAssertNil(store.activeAlarmDate(for: reminder))
    }

    func testUnfindableEventKeepsTaskUntilExplicitLocalOnlyDeletion() async throws {
        let context = try memory()
        var removals = 0
        let store = ReminderStore(context: context, alarms: fakeAlarms(), calendar: CalendarService(
            hasAccess: { true }, upsert: { _ in CalendarIdentity(eventID: "old-id", externalID: "old-external", calendarID: "calendar") },
            remove: { _ in removals += 1; throw CalendarError.missing }))
        _ = await store.create(title: "Task", date: Date.now.addingTimeInterval(600), calendarEnabled: true, calendarID: "calendar")
        let reminder = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertFalse(store.delete(reminder))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Reminder>()), 1)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.delete(reminder, keepCalendarEvent: true))
        XCTAssertEqual(removals, 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Reminder>()), 0)
    }

    func testProviderNormalizationDoesNotCauseCalendarWriteFeedback() {
        let date = Date(timeIntervalSince1970: 1_900_000_000.4)
        let request = CalendarRequest(id: UUID(), title: "Task", date: date, calendarID: "calendar", eventID: nil, externalID: nil, previousDate: nil, allowCreate: true)
        XCTAssertTrue(request.matchesContent(title: "Task", start: date.addingTimeInterval(-0.4), end: request.endDate.addingTimeInterval(-0.4), notes: request.notes.replacingOccurrences(of: "\n", with: "\r\n"), hasAlarms: false, allDay: false))
        XCTAssertFalse(request.matchesContent(title: "Task", start: date.addingTimeInterval(60), end: request.endDate, notes: request.notes, hasAlarms: false, allDay: false))
        XCTAssertFalse(request.matchesContent(title: "Changed", start: date, end: request.endDate, notes: request.notes, hasAlarms: false, allDay: false))
        XCTAssertFalse(request.matchesContent(title: "Task", start: date, end: request.endDate, notes: request.notes, hasAlarms: true, allDay: false))
    }

    private func memory() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Reminder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }
    private func fakeAlarms() -> AlarmService {
        AlarmService(schedule: { _, _, _, _ in }, cancel: { _ in }, scheduledAlarms: { [:] })
    }
    private enum TestError: Error { case failed }
}

private enum Legacy030 {
    @Model final class Reminder {
        @Attribute(.unique) var id: UUID
        var title: String
        var scheduledAt: Date
        var createdAt: Date
        var nextAlarmAt: Date?
        var pendingSnoozeAt: Date?
        var soundModeID: String?
        var completedAt: Date?
        var alarmID: UUID
        var alarmState: AlarmRegistration
        var alarmError: String?

        init(id: UUID, date: Date) {
            self.id = id
            self.title = "Legacy 0.3.0"
            self.scheduledAt = date
            self.createdAt = date.addingTimeInterval(-60)
            self.nextAlarmAt = date.addingTimeInterval(300)
            self.pendingSnoozeAt = date.addingTimeInterval(600)
            self.soundModeID = "experimentalVibrationOnly"
            self.alarmID = id
            self.alarmState = .failed
            self.alarmError = "Legacy error"
        }
    }
}
