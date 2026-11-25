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
        var ids = [reminder.id: try XCTUnwrap(reminder.scheduledAt)]
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
            save: { context in saves += 1; if saves == 3 { throw TestError.failed }; try context.save() })
        let saved = await store.create(title: "Task", date: Date.now.addingTimeInterval(600))
        XCTAssertTrue(saved, "The creation sheet must dismiss once the UUID is durably saved")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Reminder>()), 1)
        XCTAssertEqual(registrations.count, 1)
        XCTAssertNotNil(store.errorMessage)
    }

    func testMissingRegistrationDuringEditAuthorizationDoesNotRecreateAlarm() async throws {
        let context = try memory()
        let date = Date.now.addingTimeInterval(600)
        let reminder = try Reminder(title: "Before", scheduledAt: date)
        context.insert(reminder)
        try context.save()
        var registrations = [reminder.id: date]
        let store = ReminderStore(context: context, alarms: AlarmService(
            authorize: { registrations = [:] },
            schedule: { _, _, _, _ in XCTFail("An absent alarm must not be recreated") },
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

@MainActor
final class TaskFirstTests: XCTestCase {
    private func memory() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Reminder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }
    func testTaskWithoutDateOrAlarmNeverAsksForAlarmPermission() async throws {
        let context = try memory()
        let store = ReminderStore(context: context, alarms: AlarmService(authorize: { XCTFail("No alarm requested") },
            schedule: { _, _, _, _ in XCTFail("No alarm requested") }, cancel: { _ in XCTFail("No registration") }, scheduledAlarms: { [:] }))
        let saved = await store.create(title: "Обычная задача")
        XCTAssertTrue(saved)
        let task = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertNil(task.scheduledAt)
        XCTAssertEqual(task.alarmDisabled, true)
        XCTAssertNil(task.completedAt)
        XCTAssertEqual(task.state(at: .now), .pending)
        XCTAssertTrue(store.complete(task))
        XCTAssertNotNil(task.completedAt)
    }
    func testSystemStopIsDurableIdempotentAndKeepsCalendar() async throws {
        let context = try memory()
        let task = try Reminder(title: "Task", scheduledAt: .now.addingTimeInterval(600))
        task.nextAlarmAt = .now.addingTimeInterval(900)
        task.pendingSnoozeAt = .now.addingTimeInterval(1200)
        task.calendarEventID = "event"
        context.insert(task)
        try context.save()
        var cancellations = 0
        let alarms = AlarmService(schedule: { _, _, _, _ in XCTFail("Stop cannot schedule") }, cancel: { _ in cancellations += 1 }, scheduledAlarms: { [:] })
        let intent = CompleteTaskIntent(reminderID: task.id.uuidString)
        try await intent.complete(in: context, alarms: alarms)
        let completedAt = task.completedAt
        try await intent.complete(in: context, alarms: alarms)
        let reopenedContext = ModelContext(context.container)
        let saved = try XCTUnwrap(reopenedContext.fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertNotNil(saved.completedAt)
        XCTAssertEqual(saved.completedAt, completedAt)
        XCTAssertEqual(saved.calendarEventID, "event")
        XCTAssertNil(saved.nextAlarmAt)
        XCTAssertNil(saved.pendingSnoozeAt)
        XCTAssertEqual(saved.alarmDisabled, true)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(try reopenedContext.fetchCount(FetchDescriptor<Reminder>()), 1)
    }
    func testOpeningActionsDoesNotCompleteTask() async throws {
        let context = try memory()
        let task = try Reminder(title: "Task", scheduledAt: .now.addingTimeInterval(600))
        context.insert(task); try context.save()
        _ = try await ChooseTimeIntent(reminderID: task.id.uuidString).perform()
        XCTAssertEqual(SnoozeRequest.shared.reminderID, task.id)
        XCTAssertNil(task.completedAt)
        SnoozeRequest.shared.reminderID = nil
    }
    func testDisabledAlarmCanBeEnabledTwiceWithoutDuplicate() async throws {
        let context = try memory()
        let task = try Reminder(title: "Task", scheduledAt: .now.addingTimeInterval(600), alarmEnabled: false)
        context.insert(task); try context.save()
        var registrations: [UUID: Date] = [:]
        var schedules = 0
        let store = ReminderStore(context: context, alarms: AlarmService(schedule: { id, _, date, _ in schedules += 1; registrations[id] = date },
            cancel: { registrations.removeValue(forKey: $0) }, scheduledAlarms: { registrations }))
        let first = await store.enableAlarm(id: task.id)
        let second = await store.enableAlarm(id: task.id)
        XCTAssertTrue(first && second)
        XCTAssertEqual(schedules, 1)
        XCTAssertEqual(registrations.count, 1)
        XCTAssertTrue(store.disableAlarm(task))
        XCTAssertTrue(registrations.isEmpty)
        XCTAssertNil(task.completedAt)
    }
    func testCompletionDuringScheduleRemovesLateRegistration() async throws {
        let context = try memory()
        let task = try Reminder(title: "Task", scheduledAt: .now.addingTimeInterval(600))
        context.insert(task); try context.save()
        var continuation: CheckedContinuation<Void, Never>?
        var registrations: [UUID: Date] = [:]
        let alarms = AlarmService(schedule: { id, _, date, _ in
            await withCheckedContinuation { continuation = $0 }
            registrations[id] = date
        }, cancel: { registrations.removeValue(forKey: $0) }, scheduledAlarms: { registrations })
        let store = ReminderStore(context: context, alarms: alarms)
        let snoozing = Task { await store.snooze(id: task.id, until: .now.addingTimeInterval(1200)) }
        while continuation == nil { await Task.yield() }
        try await CompleteTaskIntent(reminderID: task.id.uuidString).complete(in: context, alarms: alarms)
        continuation?.resume()
        let snoozed = await snoozing.value
        XCTAssertFalse(snoozed)
        XCTAssertTrue(registrations.isEmpty)
        XCTAssertNotNil(task.completedAt)
        XCTAssertNil(task.pendingSnoozeAt)
    }
    func testPendingCancellationIsRetriedWithoutRescheduling() throws {
        let context = try memory()
        let task = try Reminder(title: "Task", scheduledAt: .now.addingTimeInterval(600))
        context.insert(task); try context.save()
        var fail = true
        var registrations = [task.alarmID: try XCTUnwrap(task.scheduledAt)]
        let store = ReminderStore(context: context, alarms: AlarmService(schedule: { _, _, _, _ in XCTFail("Do not recreate") },
            cancel: { id in if fail { throw CancellationError() }; registrations.removeValue(forKey: id) }, scheduledAlarms: { registrations }))
        XCTAssertFalse(store.complete(task))
        XCTAssertNotNil(task.completedAt)
        XCTAssertEqual(task.alarmNeedsUpdate, true)
        fail = false
        store.refresh()
        XCTAssertTrue(registrations.isEmpty)
        XCTAssertEqual(task.alarmNeedsUpdate, false)
        XCTAssertNil(task.alarmError)
    }
    func testUpgradeRetainsIDDateAndDoesNotRearmDisabledTask() async throws {
        let context = try memory()
        let date = Date.now.addingTimeInterval(600)
        let active = try Reminder(title: "Active", scheduledAt: date)
        let off = try Reminder(title: "Off", scheduledAt: date, alarmEnabled: false)
        context.insert(active); context.insert(off); try context.save()
        var registrations = [active.alarmID: date]
        var schedules = 0
        let store = ReminderStore(context: context, alarms: AlarmService(schedule: { id, _, date, _ in schedules += 1; registrations[id] = date },
            cancel: { registrations.removeValue(forKey: $0) }, scheduledAlarms: { registrations }))
        await store.upgradeAlarmActions()
        await store.upgradeAlarmActions()
        XCTAssertEqual(schedules, 1)
        XCTAssertEqual(registrations, [active.alarmID: date])
        XCTAssertEqual(active.alarmActionsVersion, AlarmService.actionsVersion)
        XCTAssertEqual(off.alarmDisabled, true)
    }
    func testActionUpgradeDoesNotResurrectLegacyAlarmStoppedDuringAuthorization() async throws {
        let context = try memory()
        let date = Date.now.addingTimeInterval(600)
        let task = try Reminder(title: "Old", scheduledAt: date)
        context.insert(task); try context.save()
        var registrations = [task.alarmID: date]
        let store = ReminderStore(context: context, alarms: AlarmService(authorize: { registrations = [:] },
            schedule: { _, _, _, _ in XCTFail("Old Stop must not rearm") }, cancel: { _ in XCTFail("Registration is absent") }, scheduledAlarms: { registrations }))
        await store.upgradeAlarmActions()
        XCTAssertTrue(registrations.isEmpty)
        XCTAssertNil(task.completedAt, "Absence alone does not prove completion")
    }
    func testUncertainScheduleErrorAfterStopStillCancelsLateAlarm() async throws {
        let context = try memory()
        let task = try Reminder(title: "Task", scheduledAt: .now.addingTimeInterval(600))
        context.insert(task); try context.save()
        var continuation: CheckedContinuation<Void, Never>?
        var registrations: [UUID: Date] = [:]
        let alarms = AlarmService(schedule: { id, _, date, _ in
            await withCheckedContinuation { continuation = $0 }
            registrations[id] = date
            throw CancellationError() // Framework may have accepted the registration.
        }, cancel: { registrations.removeValue(forKey: $0) }, scheduledAlarms: { registrations })
        let store = ReminderStore(context: context, alarms: alarms)
        let pending = Task { await store.snooze(id: task.id, until: .now.addingTimeInterval(1200)) }
        while continuation == nil { await Task.yield() }
        try await CompleteTaskIntent(reminderID: task.id.uuidString).complete(in: context, alarms: alarms)
        continuation?.resume()
        let succeeded = await pending.value
        XCTAssertFalse(succeeded)
        XCTAssertTrue(registrations.isEmpty)
        XCTAssertNotNil(task.completedAt)
    }
    func testStopIntentCanOpenAndPersistAcrossColdDiskContainers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ModelConfiguration(url: directory.appendingPathComponent("tasks.store"))
        let id = UUID()
        do {
            let container = try ModelContainer(for: Reminder.self, configurations: config)
            let task = try Reminder(id: id, title: "Task", scheduledAt: .now.addingTimeInterval(600))
            task.calendarEventID = "kept-event"
            container.mainContext.insert(task)
            try container.mainContext.save()
        }
        do {
            let container = try ModelContainer(for: Reminder.self, configurations: config)
            let alarms = AlarmService(schedule: { _, _, _, _ in XCTFail("Stop cannot schedule") }, cancel: { _ in }, scheduledAlarms: { [:] })
            try await CompleteTaskIntent(reminderID: id.uuidString).complete(in: container.mainContext, alarms: alarms)
        }
        let reopened = try ModelContainer(for: Reminder.self, configurations: config)
        let task = try XCTUnwrap(reopened.mainContext.fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertEqual(task.id, id)
        XCTAssertEqual(task.alarmID, id)
        XCTAssertNotNil(task.completedAt)
        XCTAssertEqual(task.calendarEventID, "kept-event")
    }

    func testMetadataEditPreservesFutureSnoozeOnOverdueTask() async throws {
        let context = try memory()
        let past = Date.now.addingTimeInterval(-600)
        let future = Date.now.addingTimeInterval(600)
        let task = try Reminder(title: "Before", scheduledAt: past, alarmEnabled: false)
        task.alarmDisabled = false
        task.nextAlarmAt = future
        context.insert(task); try context.save()
        var registrations = [task.alarmID: future]
        let store = ReminderStore(context: context, alarms: AlarmService(schedule: { id, _, date, _ in registrations[id] = date },
            cancel: { registrations.removeValue(forKey: $0) }, scheduledAlarms: { registrations }))
        let saved = await store.edit(id: task.id, title: "After", date: past, sound: .soft, calendarEnabled: false, calendarID: nil, alarmEnabled: true)
        XCTAssertTrue(saved)
        XCTAssertEqual(task.scheduledAt, past)
        XCTAssertEqual(task.nextAlarmAt, future)
        XCTAssertEqual(registrations[task.alarmID], future)
    }

    func testPendingCancellationKeepsDesiredAlarmOffDuringMetadataEdit() async throws {
        let context = try memory()
        let date = Date.now.addingTimeInterval(600)
        let task = try Reminder(title: "Before", scheduledAt: date, alarmEnabled: false)
        task.alarmNeedsUpdate = true
        context.insert(task); try context.save()
        XCTAssertFalse(task.alarmEnabled)
        var registrations = [task.alarmID: date]
        let store = ReminderStore(context: context, alarms: AlarmService(schedule: { _, _, _, _ in XCTFail("Off intent must survive editing") },
            cancel: { registrations.removeValue(forKey: $0) }, scheduledAlarms: { registrations }))
        let saved = await store.edit(id: task.id, title: "After", date: date, sound: task.sound, calendarEnabled: false, calendarID: nil, alarmEnabled: task.alarmEnabled)
        XCTAssertTrue(saved)
        XCTAssertTrue(registrations.isEmpty)
        XCTAssertFalse(task.alarmEnabled)
    }

    func testActionUpgradePreservesInterruptedSnoozeForExplicitRetry() async throws {
        let context = try memory()
        let date = Date.now.addingTimeInterval(600)
        let pending = date.addingTimeInterval(600)
        let task = try Reminder(title: "Pending", scheduledAt: date)
        task.pendingSnoozeAt = pending
        context.insert(task); try context.save()
        let store = ReminderStore(context: context, alarms: AlarmService(
            authorize: { XCTFail("Do not overwrite interrupted operation") },
            schedule: { _, _, _, _ in XCTFail("Do not overwrite pending time") },
            cancel: { _ in XCTFail("Keep the old registration") }, scheduledAlarms: { [task.alarmID: date] }))
        await store.upgradeAlarmActions()
        XCTAssertEqual(task.pendingSnoozeAt, pending)
        XCTAssertEqual(task.scheduledAt, date)
        XCTAssertNil(task.alarmActionsVersion)
    }

}

final class RecurrenceDateTests: XCTestCase {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    func testDaysWeeksWeekdaysAndHours() throws {
        let anchor = date("2026-11-24T06:00:00Z") // Tuesday 09:00 Moscow.
        for (rule, expected) in [
            (RecurrenceRule(unit: .hours, interval: 3, timeZoneID: "Europe/Moscow"), "2026-11-24T09:00:00Z"),
            (RecurrenceRule(unit: .days, timeZoneID: "Europe/Moscow"), "2026-11-25T06:00:00Z"),
            (RecurrenceRule(unit: .days, interval: 3, timeZoneID: "Europe/Moscow"), "2026-11-27T06:00:00Z"),
            (RecurrenceRule(unit: .weeks, interval: 2, timeZoneID: "Europe/Moscow"), "2026-12-08T06:00:00Z"),
            (RecurrenceRule(unit: .weekdays, weekdays: [3], timeZoneID: "Europe/Moscow"), "2026-12-01T06:00:00Z"),
            (RecurrenceRule(unit: .weekdays, weekdays: [3, 5], timeZoneID: "Europe/Moscow"), "2026-11-26T06:00:00Z")
        ] { XCTAssertEqual(try rule.next(after: anchor, anchor: anchor), date(expected)) }
    }
    func testMonthEndsLeapYearAndInvalidRules() throws {
        let monthly = RecurrenceRule(unit: .months, timeZoneID: "UTC")
        let january = date("2028-01-31T09:00:00Z")
        XCTAssertEqual(try monthly.next(after: january, anchor: january), date("2028-03-31T09:00:00Z"))
        let feb29 = date("2028-02-29T09:00:00Z")
        XCTAssertEqual(try monthly.next(after: feb29, anchor: feb29), date("2028-03-29T09:00:00Z"))
        let fifth = RecurrenceRule(unit: .months, monthDay: 5, timeZoneID: "UTC")
        XCTAssertEqual(try fifth.next(after: date("2026-12-05T09:00:00Z"), anchor: date("2026-11-05T09:00:00Z")), date("2027-01-05T09:00:00Z"))
        XCTAssertThrowsError(try RecurrenceRule(unit: .days, interval: 0).next(after: january, anchor: january))
        XCTAssertThrowsError(try RecurrenceRule(unit: .weekdays).validate())
        XCTAssertThrowsError(try RecurrenceRule(unit: .months, monthDay: 32).validate())
    }
    func testDSTKeepsCalendarClockAndHoursAreElapsed() throws {
        let daily = RecurrenceRule(unit: .days, timeZoneID: "America/New_York")
        let before = date("2026-03-07T14:00:00Z")
        XCTAssertEqual(try daily.next(after: before, anchor: before), date("2026-03-08T13:00:00Z"))
        let fall = date("2026-10-31T13:00:00Z")
        XCTAssertEqual(try daily.next(after: fall, anchor: fall), date("2026-11-01T14:00:00Z"))
        let hours = RecurrenceRule(unit: .hours, interval: 24, timeZoneID: "America/New_York")
        XCTAssertEqual(try hours.next(after: before, anchor: before).timeIntervalSince(before), 86400)
        let missingClock = date("2026-03-07T07:30:00Z")
        XCTAssertEqual(try daily.next(after: missingClock, anchor: missingClock), date("2026-03-08T07:00:00Z"))
    }
}

@MainActor
final class RecurringStoreTests: XCTestCase {
    func testRecurringDoneIsIdempotentKeepsAnchorAndOffIntentAndEndsSeries() async throws {
        let container = try ModelContainer(for: Reminder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let anchor = Date.now.addingTimeInterval(600)
        let store = ReminderStore(context: context, alarms: AlarmService(
            authorize: { XCTFail("Off task must not request AlarmKit") }, schedule: { _, _, _, _ in XCTFail("Off task") },
            cancel: { _ in XCTFail("No signal exists") }, scheduledAlarms: { [:] }))
        let created = await store.create(title: "Daily", date: anchor, alarmEnabled: false, recurrence: RecurrenceRule(unit: .days))
        XCTAssertTrue(created)
        let task = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        let token = try XCTUnwrap(task.occurrenceID)
        let intent = CompleteTaskIntent(reminderID: task.id.uuidString, occurrenceID: token.uuidString)
        let alarms = AlarmService(schedule: { _, _, _, _ in XCTFail("Off task") }, cancel: { _ in XCTFail("Off task") }, scheduledAlarms: { [:] })
        try await intent.complete(in: context, alarms: alarms)
        let next = task.nextOccurrenceAt
        try await intent.complete(in: context, alarms: alarms)
        XCTAssertEqual(task.nextOccurrenceAt, next)
        XCTAssertEqual(task.completedOccurrences.count, 1)
        XCTAssertEqual(task.scheduledAt, anchor)
        XCTAssertEqual(task.alarmDisabled, true)
        XCTAssertNil(task.completedAt)
        let reopened = ModelContext(container)
        let saved = try XCTUnwrap(reopened.fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertEqual(saved.completedOccurrences.count, 1)
        XCTAssertEqual(saved.recurrence?.unit, .days)
        XCTAssertEqual(saved.nextOccurrenceAt, next)
        XCTAssertTrue(store.finishSeries(task))
        XCTAssertNotNil(task.completedAt)
        XCTAssertNil(task.nextOccurrenceAt)
    }
    func testRecurringAlarmStopRegistersNextAndSnoozePreservesRuleAndCalendarAnchor() async throws {
        let context = ModelContext(try ModelContainer(for: Reminder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        var registrations: [UUID: Date] = [:]
        var events: [UUID: CalendarRequest] = [:]
        let alarms = AlarmService(schedule: { id, _, date, _ in registrations[id] = date },
            cancel: { registrations.removeValue(forKey: $0) }, scheduledAlarms: { registrations })
        let calendar = CalendarService(hasAccess: { true }, upsert: { request in
            events[request.id] = request
            return CalendarIdentity(eventID: "same-event", externalID: nil, calendarID: "calendar")
        }, remove: { _ in XCTFail("Completion must not delete Calendar") })
        let store = ReminderStore(context: context, alarms: alarms, calendar: calendar)
        let anchor = Date.now.addingTimeInterval(600)
        let rule = RecurrenceRule(unit: .days, interval: 3)
        _ = await store.create(title: "Every 3 days", date: anchor, calendarEnabled: true, calendarID: "calendar", alarmEnabled: true, recurrence: rule)
        let task = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        let token = task.occurrenceID
        let done = await store.completeCurrent(id: task.id, expectedOccurrence: token)
        XCTAssertTrue(done)
        let next = try XCTUnwrap(task.nextOccurrenceAt)
        XCTAssertEqual(registrations[task.alarmID], next)
        XCTAssertEqual(events[task.id]?.date, anchor)
        XCTAssertEqual(events.count, 1)
        _ = await store.completeCurrent(id: task.id, expectedOccurrence: token)
        XCTAssertEqual(task.completedOccurrences.count, 1)
        _ = await store.snooze(id: task.id, until: next.addingTimeInterval(600))
        XCTAssertEqual(task.recurrence, rule)
        XCTAssertEqual(task.nextOccurrenceAt, next)
        XCTAssertEqual(task.scheduledAt, anchor)
        XCTAssertEqual(events[task.id]?.date, anchor)
        XCTAssertTrue(store.finishSeries(task))
        XCTAssertTrue(registrations.isEmpty)
    }
    func testFailedNextRegistrationKeepsCompletionForForegroundRecovery() async throws {
        let context = ModelContext(try ModelContainer(for: Reminder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        var fail = false
        var registrations: [UUID: Date] = [:]
        let alarms = AlarmService(schedule: { id, _, date, _ in
            if fail { throw CancellationError() }
            registrations[id] = date
        }, cancel: { registrations.removeValue(forKey: $0) }, scheduledAlarms: { registrations })
        let store = ReminderStore(context: context, alarms: alarms)
        _ = await store.create(title: "Daily", date: .now.addingTimeInterval(600), recurrence: RecurrenceRule(unit: .days))
        let task = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        fail = true
        let done = await store.completeCurrent(id: task.id, expectedOccurrence: task.occurrenceID)
        XCTAssertTrue(done)
        XCTAssertEqual(task.completedOccurrences.count, 1)
        XCTAssertEqual(task.alarmNeedsUpdate, true)
        fail = false
        await store.recoverRecurringAlarms()
        XCTAssertEqual(task.completedOccurrences.count, 1)
        XCTAssertEqual(registrations[task.alarmID], task.nextOccurrenceAt)
    }
    func testCalendarNativeRulesAndHourlyAnchorStrategy() {
        var request = CalendarRequest(id: UUID(), title: "Repeat", date: Date(timeIntervalSince1970: 1_900_000_000), calendarID: nil, eventID: nil, externalID: nil, previousDate: nil, allowCreate: true)
        request.recurrence = RecurrenceRule(unit: .weekdays, weekdays: [3, 5])
        let rule = request.nativeRecurrence
        XCTAssertNotNil(rule)
        XCTAssertTrue(request.matchesRecurrence(rule.map { [$0] }))
        request.recurrence = RecurrenceRule(unit: .hours, interval: 3)
        XCTAssertNil(request.nativeRecurrence)
        XCTAssertTrue(request.matchesRecurrence(nil))
        XCTAssertTrue(request.notes.contains(CalendarRequest.marker(for: request.id)))
    }
    func testFailedCancellationCannotAdoptOldSameDateOccurrence() async throws {
        let context = ModelContext(try ModelContainer(for: Reminder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        var registrations: [UUID: Date] = [:]
        var failCancel = false
        let alarms = AlarmService(schedule: { id, _, date, _ in registrations[id] = date },
            cancel: { id in if failCancel { throw CancellationError() }; registrations.removeValue(forKey: id) },
            scheduledAlarms: { registrations })
        let store = ReminderStore(context: context, alarms: alarms)
        let anchor = Date.now.addingTimeInterval(600)
        _ = await store.create(title: "Repeat", date: anchor, recurrence: RecurrenceRule(unit: .days))
        let task = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        let oldToken = task.occurrenceID
        failCancel = true
        let edited = await store.edit(id: task.id, title: task.title, date: anchor, sound: task.sound,
            calendarEnabled: false, calendarID: nil, recurrence: RecurrenceRule(unit: .days, interval: 3))
        XCTAssertFalse(edited)
        XCTAssertNotEqual(task.occurrenceID, oldToken)
        XCTAssertEqual(registrations[task.alarmID], anchor)
        store.refresh()
        XCTAssertEqual(task.alarmNeedsUpdate, true)
        XCTAssertEqual(task.alarmWriteStarted, false)
        XCTAssertEqual(task.alarmState, .failed)
        _ = await store.completeCurrent(id: task.id, expectedOccurrence: oldToken)
        XCTAssertTrue(task.completedOccurrences.isEmpty)
        failCancel = false
        await store.recoverRecurringAlarms()
        XCTAssertEqual(task.alarmNeedsUpdate, false)
    }

    func testEndSeriesPersistsCalendarRetryBeforeExternalUpdate() async throws {
        let container = try ModelContainer(for: Reminder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        var failCalendar = false
        var endedRequests = 0
        let calendar = CalendarService(hasAccess: { true }, upsert: { request in
            if failCalendar { throw CalendarError.permission }
            if request.seriesCompletedAt != nil { endedRequests += 1 }
            return CalendarIdentity(eventID: "owned-series", externalID: nil, calendarID: "calendar")
        }, remove: { _ in XCTFail("Keep series history") })
        let alarms = AlarmService(schedule: { _, _, _, _ in XCTFail("Disabled") }, cancel: { _ in }, scheduledAlarms: { [:] })
        let store = ReminderStore(context: context, alarms: alarms, calendar: calendar)
        _ = await store.create(title: "Series", date: .now.addingTimeInterval(600), calendarEnabled: true,
            calendarID: "calendar", alarmEnabled: false, recurrence: RecurrenceRule(unit: .days))
        let task = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        failCalendar = true
        _ = store.finishSeries(task)
        let reopened = ModelContext(container)
        let saved = try XCTUnwrap(reopened.fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertNotNil(saved.completedAt)
        XCTAssertEqual(saved.calendarNeedsSync, true)
        failCalendar = false
        let nextStore = ReminderStore(context: reopened, alarms: alarms, calendar: calendar)
        nextStore.refreshCalendar()
        XCTAssertEqual(saved.calendarNeedsSync, false)
        XCTAssertEqual(endedRequests, 1)
    }

    func testNewerOccurrenceWinsWhileOlderCompletionAwaitsAuthorization() async throws {
        let context = ModelContext(try ModelContainer(for: Reminder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        var onAuthorize: (() async -> Void)?
        var registrations: [UUID: Date] = [:]
        var registeredToken: UUID?
        let alarms = AlarmService(authorize: {
            let action = onAuthorize
            onAuthorize = nil
            await action?()
        }, schedule: { _, _, _, _ in XCTFail("Use token-aware registration") },
            cancel: { registrations.removeValue(forKey: $0) }, scheduledAlarms: { registrations },
            scheduleOccurrence: { id, _, date, _, token in registrations[id] = date; registeredToken = token })
        let first = ReminderStore(context: context, alarms: alarms)
        let second = ReminderStore(context: context, alarms: alarms)
        _ = await first.create(title: "Race", date: .now.addingTimeInterval(600), recurrence: RecurrenceRule(unit: .days))
        let task = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertEqual(registeredToken, task.occurrenceID)
        onAuthorize = {
            _ = await second.completeCurrent(id: task.id, expectedOccurrence: task.occurrenceID)
        }
        _ = await first.completeCurrent(id: task.id, expectedOccurrence: task.occurrenceID)
        XCTAssertEqual(task.completedOccurrences.count, 2)
        XCTAssertEqual(registeredToken, task.occurrenceID)
        XCTAssertEqual(registrations[task.alarmID], task.nextOccurrenceAt)
        XCTAssertEqual(task.alarmNeedsUpdate, false)
        XCTAssertNil(task.alarmError)
    }

}
