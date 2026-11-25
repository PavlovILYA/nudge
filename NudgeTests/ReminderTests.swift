import ActivityKit
import AVFoundation
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
        reminder.alarmState = .absent // A missing registration alone does not prove completion.
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
        let alarms = AlarmService(schedule: { id, _, date, _ in
            let saved = try context.fetch(FetchDescriptor<Reminder>())
            XCTAssertEqual(saved.first?.alarmID, id)
            XCTAssertFalse(context.hasChanges)
            XCTAssertEqual(saved.first?.scheduledAt, date)
            throw TestError.denied
        }, cancel: { _ in }, scheduledAlarms: { [:] })
        let store = ReminderStore(context: context, alarms: alarms)
        let saved = await store.create(title: "Task", date: Date.now.addingTimeInterval(3600))
        XCTAssertTrue(saved)
        let reminder = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
        XCTAssertNil(reminder.completedAt)
        XCTAssertEqual(reminder.alarmState, .failed)
        XCTAssertNotNil(reminder.alarmError)
    }

    func testCancelFailureKeepsDurableCompletionAndAllowsRetry() throws {
        let context = try memoryContext()
        let reminder = try Reminder(title: "Task", scheduledAt: now.addingTimeInterval(60), now: now)
        context.insert(reminder)
        try context.save()
        let failing = ReminderStore(context: context, alarms: AlarmService(
            schedule: { _, _, _, _ in }, cancel: { _ in throw TestError.denied }, scheduledAlarms: { [:] }))
        failing.complete(reminder)
        XCTAssertNotNil(reminder.completedAt)
        XCTAssertEqual(reminder.alarmNeedsUpdate, true)
        failing.delete(reminder)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Reminder>()), 1)
        XCTAssertNotNil(failing.errorMessage)
        let working = ReminderStore(context: context, alarms: AlarmService(
            schedule: { _, _, _, _ in }, cancel: { XCTAssertEqual($0, reminder.alarmID) }, scheduledAlarms: { [:] }))
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
            schedule: { _, _, _, _ in XCTFail("Refresh must not reschedule") },
            cancel: { _ in XCTFail("Refresh must not cancel") }, scheduledAlarms: { [:] }))
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
            schedule: { id, _, date, _ in
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

    func testFailedSnoozeKeepsDurableIntentAndCanRetry() async throws {
        let context = try memoryContext()
        let reminder = try Reminder(title: "Task", scheduledAt: Date.now.addingTimeInterval(600))
        context.insert(reminder)
        try context.save()
        let target = Date.now.addingTimeInterval(1800)
        var shouldFail = true
        var registered: [UUID: Date] = [:]
        let store = ReminderStore(context: context, alarms: AlarmService(
            schedule: { id, _, date, _ in
                if shouldFail { throw TestError.denied }
                registered[id] = date
            }, cancel: { registered.removeValue(forKey: $0) }, scheduledAlarms: { registered }))
        let failed = await store.snooze(id: reminder.id, until: target)
        XCTAssertFalse(failed)
        XCTAssertNil(reminder.nextAlarmAt)
        XCTAssertNil(reminder.completedAt)
        XCTAssertEqual(reminder.pendingSnoozeAt, target)
        XCTAssertEqual(reminder.alarmState, .failed)
        XCTAssertNotNil(store.errorMessage)
        store.refresh()
        XCTAssertEqual(reminder.alarmState, .failed)
        shouldFail = false
        let retry = await store.snooze(id: reminder.id, until: target)
        XCTAssertTrue(retry)
        XCTAssertEqual(registered.count, 1)
        XCTAssertNil(reminder.pendingSnoozeAt)
    }

    func testPermissionAndCancellationFailuresDoNotReplaceOldAlarm() async throws {
        for denyAuthorization in [true, false] {
            let context = try memoryContext()
            let date = Date.now.addingTimeInterval(600)
            let reminder = try Reminder(title: "Task", scheduledAt: date)
            context.insert(reminder)
            try context.save()
            var cancelled = false
            let store = ReminderStore(context: context, alarms: AlarmService(
                authorize: { if denyAuthorization { throw TestError.denied } },
                schedule: { _, _, _, _ in XCTFail("Must not schedule after failure") },
                cancel: { _ in cancelled = true; throw TestError.denied },
                scheduledAlarms: { [reminder.alarmID: date] }))
            let result = await store.snooze(id: reminder.id, until: date.addingTimeInterval(300))
            XCTAssertFalse(result)
            XCTAssertEqual(cancelled, !denyAuthorization)
            XCTAssertNil(reminder.nextAlarmAt)
            XCTAssertNil(reminder.completedAt)
            XCTAssertNotNil(store.errorMessage)
        }
    }

    func testRejectsPastDeletedAndCompletedTasksWithoutSystemChanges() async throws {
        let context = try memoryContext()
        let date = Date.now.addingTimeInterval(600)
        let reminder = try Reminder(title: "Task", scheduledAt: date)
        context.insert(reminder)
        try context.save()
        let store = ReminderStore(context: context, alarms: AlarmService(
            schedule: { _, _, _, _ in XCTFail("Invalid request") },
            cancel: { _ in XCTFail("Invalid request") }, scheduledAlarms: { [:] }))
        let past = await store.snooze(id: reminder.id, until: .distantPast)
        XCTAssertFalse(past)
        reminder.completedAt = .now
        try context.save()
        let complete = await store.snooze(id: reminder.id, until: date)
        XCTAssertFalse(complete)
        context.delete(reminder)
        try context.save()
        let deleted = await store.snooze(id: reminder.id, until: date)
        XCTAssertFalse(deleted)
        XCTAssertNotNil(store.errorMessage)
    }

    func testRepeatedTapWhileSchedulingIsRejected() async throws {
        let context = try memoryContext()
        let reminder = try Reminder(title: "Task", scheduledAt: Date.now.addingTimeInterval(600))
        context.insert(reminder)
        try context.save()
        var continuation: CheckedContinuation<Void, Never>?
        var calls = 0
        let store = ReminderStore(context: context, alarms: AlarmService(
            schedule: { _, _, _, _ in
                calls += 1
                await withCheckedContinuation { continuation = $0 }
            }, cancel: { _ in }, scheduledAlarms: { [:] }))
        let target = Date.now.addingTimeInterval(1800)
        let first = Task { await store.snooze(id: reminder.id, until: target) }
        while continuation == nil { await Task.yield() }
        XCTAssertTrue(store.isBusy)
        let second = await store.snooze(id: reminder.id, until: target)
        XCTAssertFalse(second)
        store.complete(reminder)
        store.delete(reminder)
        XCTAssertNil(reminder.completedAt)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Reminder>()), 1)
        continuation?.resume()
        let success = await first.value
        XCTAssertTrue(success)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(store.isBusy)
    }

    func testReopeningReconcilesOnlyMatchingInterruptedSnooze() throws {
        for registered in [true, false] {
            let context = try memoryContext()
            let reminder = try Reminder(title: "Task", scheduledAt: Date.now.addingTimeInterval(600))
            let target = Date.now.addingTimeInterval(1800)
            reminder.pendingSnoozeAt = target
            context.insert(reminder)
            try context.save()
            let reopened = ModelContext(context.container)
            let store = ReminderStore(context: reopened, alarms: AlarmService(
                schedule: { _, _, _, _ in XCTFail("Never automatically retry interrupted intent") },
                cancel: { _ in XCTFail("Never cancel on refresh") },
                scheduledAlarms: { [reminder.alarmID: registered ? target : reminder.scheduledAt!] }))
            store.refresh()
            let saved = try XCTUnwrap(reopened.fetch(FetchDescriptor<Reminder>()).first)
            XCTAssertNil(saved.completedAt)
            XCTAssertEqual(saved.nextAlarmAt, registered ? target : nil)
            XCTAssertEqual(saved.pendingSnoozeAt, registered ? nil : target)
            XCTAssertEqual(saved.alarmState, registered ? .registered : .failed)
        }
    }

    func testLegacyVersion010StoreMigratesWithoutLosingTasks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("legacy.store"))
        let id = UUID()
        let completedID = UUID()
        do {
            let old = try ModelContainer(for: Legacy010.Reminder.self, configurations: configuration)
            let context = ModelContext(old)
            context.insert(Legacy010.Reminder(id: id, title: "Old task", scheduledAt: now))
            let completed = Legacy010.Reminder(id: completedID, title: "Completed", scheduledAt: now)
            completed.completedAt = now
            context.insert(completed)
            try context.save()
        }
        let upgraded = try ModelContainer(for: Reminder.self, configurations: configuration)
        let saved = try ModelContext(upgraded).fetch(FetchDescriptor<Reminder>())
        XCTAssertEqual(saved.count, 2)
        let incomplete = try XCTUnwrap(saved.first { $0.id == id })
        XCTAssertEqual(incomplete.title, "Old task")
        XCTAssertEqual(incomplete.alarmID, id)
        XCTAssertEqual(incomplete.scheduledAt, now)
        XCTAssertEqual(incomplete.effectiveAlarmAt, now)
        XCTAssertNil(incomplete.nextAlarmAt)
        XCTAssertNil(incomplete.pendingSnoozeAt)
        XCTAssertNil(incomplete.completedAt)
        XCTAssertEqual(saved.first { $0.id == completedID }?.completedAt, now)
    }

    func testTaskCompletedDuringAuthorizationIsNotRescheduled() async throws {
        let context = try memoryContext()
        let reminder = try Reminder(title: "Task", scheduledAt: Date.now.addingTimeInterval(600))
        context.insert(reminder)
        try context.save()
        let store = ReminderStore(context: context, alarms: AlarmService(
            authorize: { reminder.completedAt = .now; try context.save() },
            schedule: { _, _, _, _ in XCTFail("Task became completed") },
            cancel: { _ in XCTFail("Task became completed") }, scheduledAlarms: { [:] }))
        let result = await store.snooze(id: reminder.id, until: Date.now.addingTimeInterval(1800))
        XCTAssertFalse(result)
        XCTAssertNotNil(reminder.completedAt)
        XCTAssertNil(reminder.nextAlarmAt)
    }

    func testSaveFailuresBeforeAndAfterSchedulingAreRecoverable() async throws {
        for failingSave in [1, 3] {
            let context = try memoryContext()
            let original = Date.now.addingTimeInterval(600)
            let reminder = try Reminder(title: "Task", scheduledAt: original)
            context.insert(reminder)
            try context.save()
            let target = original.addingTimeInterval(600)
            var registered = [reminder.alarmID: original]
            var saves = 0
            var cancellations = 0
            let store = ReminderStore(context: context, alarms: AlarmService(
                schedule: { id, _, date, _ in registered[id] = date },
                cancel: { cancellations += 1; registered.removeValue(forKey: $0) },
                scheduledAlarms: { registered }), save: { context in
                    saves += 1
                    if saves == failingSave { throw TestError.denied }
                    try context.save()
                })
            let result = await store.snooze(id: reminder.id, until: target)
            XCTAssertFalse(result)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertNil(reminder.completedAt)
            XCTAssertEqual(cancellations, failingSave == 1 ? 0 : 1)
            XCTAssertEqual(registered.count, 1)
            XCTAssertEqual(registered[reminder.alarmID], failingSave == 1 ? original : target)
            XCTAssertEqual(reminder.pendingSnoozeAt, failingSave == 1 ? nil : target)
            store.refresh()
            XCTAssertEqual(reminder.nextAlarmAt, failingSave == 1 ? nil : target)
            XCTAssertNil(reminder.pendingSnoozeAt)
        }
    }

    func testUncertainScheduleErrorReconcilesWithoutAnotherSystemWrite() async throws {
        let context = try memoryContext()
        let reminder = try Reminder(title: "Task", scheduledAt: Date.now.addingTimeInterval(600))
        context.insert(reminder)
        try context.save()
        var registered: [UUID: Date] = [:]
        var calls = 0
        let store = ReminderStore(context: context, alarms: AlarmService(
            schedule: { id, _, date, _ in
                calls += 1
                registered[id] = date
                throw TestError.denied // System accepted it, client saw a failure.
            }, cancel: { registered.removeValue(forKey: $0) }, scheduledAlarms: { registered }))
        let target = Date.now.addingTimeInterval(1800)
        let result = await store.snooze(id: reminder.id, until: target)
        XCTAssertFalse(result)
        store.refresh()
        XCTAssertEqual(reminder.nextAlarmAt, target)
        XCTAssertNil(reminder.pendingSnoozeAt)
        XCTAssertEqual(reminder.alarmState, .registered)
        XCTAssertEqual(calls, 1)
    }

    func testIntentPassesCorrectTaskIDWithoutChangingTasks() async throws {
        defer { SnoozeRequest.shared.reminderID = nil }
        let id = UUID()
        _ = try await ChooseTimeIntent(reminderID: id.uuidString).perform()
        XCTAssertEqual(SnoozeRequest.shared.reminderID, id)
        let another = UUID()
        _ = try await ChooseTimeIntent(reminderID: another.uuidString).perform()
        XCTAssertEqual(SnoozeRequest.shared.reminderID, another)
        do {
            _ = try await ChooseTimeIntent(reminderID: "invalid").perform()
            XCTFail("Invalid ID must fail")
        } catch {
            XCTAssertEqual(SnoozeRequest.shared.reminderID, another)
        }
    }

    func testSoundDefaultsAndStableIdentifiers() throws {
        XCTAssertEqual(AlarmSound.allCases.map(\.rawValue), ["systemDefault", "soft", "prominent", "experimentalVibrationOnly"])
        let reminder = try Reminder(title: "Old task", scheduledAt: Date.now.addingTimeInterval(600))
        XCTAssertEqual(reminder.sound, .systemDefault)
        reminder.soundModeID = "unknown-future-mode"
        XCTAssertEqual(reminder.sound, .systemDefault)
        XCTAssertEqual(AlarmSound.preferenceKey, "defaultAlarmSound")
        let suite = "nudge-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AlarmSound.newReminderDefault, .experimentalVibrationOnly)
        XCTAssertEqual(AlarmSound.preferred(in: defaults), .experimentalVibrationOnly)
        XCTAssertNil(defaults.object(forKey: AlarmSound.preferenceKey))
        for sound in AlarmSound.allCases {
            defaults.set(sound.rawValue, forKey: AlarmSound.preferenceKey)
            XCTAssertEqual(AlarmSound.preferred(in: defaults), sound)
            XCTAssertEqual(defaults.string(forKey: AlarmSound.preferenceKey), sound.rawValue)
        }
        defaults.set(AlarmSound.experimentalVibrationOnly.rawValue, forKey: AlarmSound.preferenceKey)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(AlarmSound(rawValue: reopened.string(forKey: AlarmSound.preferenceKey) ?? ""), .experimentalVibrationOnly)
    }

    func testCreationUsesOneDefaultWithoutOverwritingExistingSoundPreference() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AlarmSound.preferenceKey)
        defer {
            if let previous { defaults.set(previous, forKey: AlarmSound.preferenceKey) }
            else { defaults.removeObject(forKey: AlarmSound.preferenceKey) }
        }
        var scheduled: [AlarmSound] = []
        let alarms = AlarmService(schedule: { _, _, _, sound in scheduled.append(sound) }, cancel: { _ in }, scheduledAlarms: { [:] })
        let context = try memoryContext()
        let store = ReminderStore(context: context, alarms: alarms)
        let cases: [(AlarmSound?, AlarmSound?, AlarmSound)] = [
            (nil, nil, .experimentalVibrationOnly),
            (.systemDefault, nil, .systemDefault),
            (.soft, nil, .soft),
            (.soft, .prominent, .prominent)
        ]
        for (preference, override, expected) in cases {
            if let preference { defaults.set(preference.rawValue, forKey: AlarmSound.preferenceKey) }
            else { defaults.removeObject(forKey: AlarmSound.preferenceKey) }
            let saved = await store.create(title: "New task", date: .now.addingTimeInterval(600), sound: override)
            XCTAssertTrue(saved)
            let reminder = try XCTUnwrap(store.reminder(id: XCTUnwrap(store.lastCreatedID)))
            XCTAssertEqual(reminder.sound, expected)
            XCTAssertEqual(scheduled.last, expected)
            XCTAssertEqual(defaults.string(forKey: AlarmSound.preferenceKey), preference?.rawValue)
        }
    }

    func testExactCAFNamesAndAlertSoundMapping() throws {
        XCTAssertNil(AlarmSound.systemDefault.filename)
        XCTAssertEqual(AlarmSound.systemDefault.alertSound, .default)
        let cases: [(AlarmSound, String)] = [(.soft, "nudge-soft.caf"), (.prominent, "nudge-prominent.caf"), (.experimentalVibrationOnly, "nudge-silent.caf")]
        for (sound, filename) in cases {
            XCTAssertEqual(sound.filename, filename)
            XCTAssertEqual(sound.alertSound, .named(filename))
            XCTAssertTrue(sound.diagnostic.contains(filename))
            let url = try XCTUnwrap(sound.resourceURL())
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.sampleRate, 44100)
            XCTAssertEqual(file.fileFormat.channelCount, 1)
            let duration = Double(file.length) / file.fileFormat.sampleRate
            XCTAssertGreaterThan(duration, 0)
            XCTAssertLessThan(duration, 30)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            let peak = (0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 0
            if sound == .experimentalVibrationOnly { XCTAssertEqual(peak, 0) }
            else { XCTAssertGreaterThan(peak, 0.01) }
        }
    }

    func testIndividualSoundPersistsAndSurvivesSnoozeFailureAndRetry() async throws {
        for sound in AlarmSound.allCases {
            let context = try memoryContext()
            var received: [AlarmSound] = []
            var registered: [UUID: Date] = [:]
            var fail = false
            let store = ReminderStore(context: context, alarms: AlarmService(
                schedule: { id, _, date, selectedSound in
                    received.append(selectedSound)
                    if fail { throw TestError.denied }
                    registered[id] = date
                }, cancel: { registered.removeValue(forKey: $0) }, scheduledAlarms: { registered }))
            let date = Date.now.addingTimeInterval(600)
            let created = await store.create(title: "Task", date: date, sound: sound)
            XCTAssertTrue(created)
            let reminder = try XCTUnwrap(context.fetch(FetchDescriptor<Reminder>()).first)
            let fresh = ModelContext(context.container)
            XCTAssertEqual(try fresh.fetch(FetchDescriptor<Reminder>()).first?.sound, sound)
            fail = true
            let failed = await store.snooze(id: reminder.id, until: date.addingTimeInterval(300))
            XCTAssertFalse(failed)
            XCTAssertEqual(reminder.sound, sound)
            XCTAssertNil(reminder.completedAt)
            fail = false
            let retried = await store.snooze(id: reminder.id, until: date.addingTimeInterval(300))
            XCTAssertTrue(retried)
            XCTAssertEqual(received, [sound, sound, sound])
            XCTAssertEqual(registered.count, 1)
            XCTAssertEqual(reminder.soundModeID, sound.rawValue)
            store.complete(reminder)
            XCTAssertNotNil(reminder.completedAt)
        }
    }

    func testVersion020StoreMigratesWithSafeSoundDefault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(url: directory.appendingPathComponent("legacy020.store"))
        let id = UUID()
        let original = now
        let next = now.addingTimeInterval(900)
        do {
            let old = try ModelContainer(for: Legacy020.Reminder.self, configurations: configuration)
            let context = ModelContext(old)
            let reminder = Legacy020.Reminder(id: id, scheduledAt: original)
            reminder.nextAlarmAt = next
            reminder.pendingSnoozeAt = next.addingTimeInterval(300)
            context.insert(reminder)
            let completed = Legacy020.Reminder(id: UUID(), scheduledAt: original)
            completed.completedAt = now
            context.insert(completed)
            try context.save()
        }
        let upgraded = try ModelContainer(for: Reminder.self, configurations: configuration)
        let saved = try ModelContext(upgraded).fetch(FetchDescriptor<Reminder>())
        XCTAssertEqual(saved.count, 2)
        let reminder = try XCTUnwrap(saved.first { $0.id == id })
        XCTAssertEqual(reminder.alarmID, id)
        XCTAssertEqual(reminder.title, "Legacy 0.2.0")
        XCTAssertEqual(reminder.scheduledAt, original)
        XCTAssertEqual(reminder.nextAlarmAt, next)
        XCTAssertEqual(reminder.pendingSnoozeAt, next.addingTimeInterval(300))
        XCTAssertEqual(reminder.sound, .systemDefault)
        XCTAssertNil(reminder.soundModeID)
        XCTAssertNil(reminder.completedAt)
        XCTAssertEqual(saved.filter { $0.completedAt == now }.count, 1)
    }

    private func memoryContext() throws -> ModelContext {
        let container = try ModelContainer(for: Reminder.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private enum TestError: Error { case denied }
}

// Frozen 0.1.0 persisted properties, using the same entity name as the shipping model.
private enum Legacy010 {
    @Model final class Reminder {
        @Attribute(.unique) var id: UUID
        var title: String
        var scheduledAt: Date
        var createdAt: Date
        var completedAt: Date?
        var alarmID: UUID
        var alarmState: AlarmRegistration
        var alarmError: String?

        init(id: UUID, title: String, scheduledAt: Date) {
            self.id = id
            self.title = title
            self.scheduledAt = scheduledAt
            self.createdAt = scheduledAt.addingTimeInterval(-60)
            self.alarmID = id
            self.alarmState = .registered
        }
    }
}

// Frozen 0.2.0 persisted entity, including its interrupted-snooze journal.
private enum Legacy020 {
    @Model final class Reminder {
        @Attribute(.unique) var id: UUID
        var title: String
        var scheduledAt: Date
        var createdAt: Date
        var nextAlarmAt: Date?
        var pendingSnoozeAt: Date?
        var completedAt: Date?
        var alarmID: UUID
        var alarmState: AlarmRegistration
        var alarmError: String?

        init(id: UUID, scheduledAt: Date) {
            self.id = id
            self.title = "Legacy 0.2.0"
            self.scheduledAt = scheduledAt
            self.createdAt = scheduledAt.addingTimeInterval(-60)
            self.alarmID = id
            self.alarmState = .registered
        }
    }
}
