import Foundation
import Observation
import OSLog
import SwiftData

@MainActor
@Observable
final class ReminderStore {
    private let context: ModelContext
    private let alarms: AlarmService
    private let calendar: CalendarService
    private(set) var lastCreatedID: UUID?
    private(set) var registeredDates: [UUID: Date] = [:]
    private let saveContext: (ModelContext) throws -> Void
    private(set) var isBusy = false
    var errorMessage: String?

    init(context: ModelContext, alarms: AlarmService = .live, calendar: CalendarService = .live,
         save: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context
        self.alarms = alarms
        self.calendar = calendar
        self.saveContext = save
        context.autosaveEnabled = false
    }

    /// True means the task was saved, even when its alarm failed.
    func create(title: String, date: Date, sound: AlarmSound = .systemDefault, calendarEnabled: Bool = false, calendarID: String? = nil) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        let reminder: Reminder
        lastCreatedID = nil
        do {
            reminder = try Reminder(title: title, scheduledAt: date)
            reminder.soundModeID = sound.rawValue
            reminder.calendarEnabled = calendarEnabled
            reminder.calendarIdentifier = calendarID
            context.insert(reminder)
            // This durable ID also covers termination during authorization/scheduling.
            try saveContext(context)
            lastCreatedID = reminder.id
        } catch {
            context.rollback()
            log(error)
            errorMessage = String(localized: "Could not save the reminder. Try again.")
            return false
        }
        do {
            try await alarms.authorize()
            try await alarms.schedule(reminder.alarmID, reminder.title, reminder.scheduledAt, reminder.sound)
            reminder.alarmState = .registered
            registeredDates[reminder.alarmID] = reminder.scheduledAt
            reminder.alarmError = nil
        } catch {
            reminder.alarmState = .failed
            reminder.alarmError = friendlyMessage(error)
            log(error)
            errorMessage = String(localized: "Reminder saved, but its alarm is not confirmed. Check alarm access in Settings and choose a time to retry.")
        }
        // The initial insert is already durable. Never leave creation retrying a new UUID.
        guard saveChanges() else { return true }
        _ = syncCalendar(reminder)
        return true
    }

    /// A durable pending date bridges the non-atomic database and system operations.
    func snooze(id: UUID, until date: Date) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        var pendingReminder: Reminder?
        do {
            try Reminder.validateSnoozeDate(date)
            _ = try incompleteReminder(id: id)
            // Never remove the old registration before permission is granted.
            try await alarms.authorize()
            try Reminder.validateSnoozeDate(date)
            let reminder = try incompleteReminder(id: id) // Authorization can suspend.
            let systemDate = try alarms.scheduledAlarms()[reminder.alarmID]
            if systemDate != date || reminder.alarmNeedsUpdate == true {
                reminder.pendingSnoozeAt = date
                reminder.alarmDisabled = false
                reminder.alarmState = .unconfirmed
                reminder.alarmError = nil
                guard saveChanges() else { return false }
                pendingReminder = reminder
                try await replaceAlarm(reminder, date: date)
            }
            reminder.nextAlarmAt = date
            reminder.alarmNeedsUpdate = false
            reminder.alarmDisabled = false
            registeredDates[reminder.alarmID] = date
            reminder.pendingSnoozeAt = nil
            reminder.alarmState = .registered
            reminder.alarmError = nil
            return saveChanges()
        } catch {
            if let reminder = pendingReminder {
                reminder.alarmState = .failed
                reminder.alarmError = friendlyMessage(error)
                guard saveChanges() else { return false }
            }
            log(error)
            errorMessage = friendlyMessage(error)
            return false
        }
    }

    func reminder(id: UUID) throws -> Reminder {
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
        guard let reminder = try context.fetch(descriptor).first else { throw SnoozeError.missing }
        return reminder
    }

    func activeAlarmDate(for reminder: Reminder, at now: Date = .now) -> Date? {
        guard reminder.completedAt == nil, let date = registeredDates[reminder.alarmID], date > now else { return nil }
        return date
    }

    /// Metadata changes preserve a snooze; moving the original deadline resets it.
    func edit(id: UUID, title: String, date: Date, sound: AlarmSound, calendarEnabled: Bool, calendarID: String?) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        var savedReminder: Reminder?
        do {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw Reminder.ValidationError.emptyTitle }
            let item = try reminder(id: id)
            let moved = date != item.scheduledAt
            if moved { try Reminder.validateSnoozeDate(date) }
            let metadataChanged = title != item.title || sound != item.sound
            let dates = metadataChanged || moved || item.alarmNeedsUpdate == true ? try alarms.scheduledAlarms() : registeredDates
            let existingFuture = dates[item.alarmID].flatMap { $0 > .now ? $0 : nil }
            var target = moved ? date : (item.pendingSnoozeAt ?? existingFuture)
            var needsAlarm = item.completedAt == nil && (moved || item.alarmNeedsUpdate == true || (metadataChanged && existingFuture != nil && item.alarmDisabled != true))
            if needsAlarm { try await alarms.authorize() }
            let current = try reminder(id: id)
            // Completion during permission acquisition must never restart its alarm.
            guard !needsAlarm || current.completedAt == nil else { throw SnoozeError.completed }
            if needsAlarm && !moved && current.alarmNeedsUpdate != true {
                // Native Stop can run while authorization suspends; metadata edits must not resurrect it.
                let actual = try alarms.scheduledAlarms()[current.alarmID]
                target = actual.flatMap { $0 > .now ? $0 : nil }
                needsAlarm = target != nil
                if target == nil { registeredDates.removeValue(forKey: current.alarmID) }
            }
            if needsAlarm, let target { try Reminder.validateSnoozeDate(target) }
            current.applyEdit(title: title, date: date, sound: sound)
            current.calendarEnabled = calendarEnabled
            if current.calendarEventID == nil && current.calendarEventDate == nil { current.calendarIdentifier = calendarID }
            current.calendarNeedsSync = calendarEnabled
            if moved { current.nextAlarmAt = nil; current.pendingSnoozeAt = nil }
            if needsAlarm {
                current.pendingSnoozeAt = target
                current.alarmNeedsUpdate = true
                current.alarmDisabled = false
                current.alarmState = .unconfirmed
            }
            guard saveChanges() else { return false }
            savedReminder = current
            if needsAlarm, let target {
                try await replaceAlarm(current, date: target)
                current.nextAlarmAt = target == date ? nil : target
                guard saveChanges() else { return false }
            }
            return syncCalendar(current)
        } catch {
            if let item = savedReminder {
                item.alarmState = .failed
                item.alarmError = friendlyMessage(error)
                _ = saveChanges()
                _ = syncCalendar(item) // Calendar failure cannot undo the locally saved edit.
            }
            log(error)
            errorMessage = friendlyMessage(error)
            return false
        }
    }

    private func replaceAlarm(_ reminder: Reminder, date: Date) async throws {
        try alarms.cancel(reminder.alarmID)
        registeredDates.removeValue(forKey: reminder.alarmID)
        try await alarms.schedule(reminder.alarmID, reminder.title, date, reminder.sound)
        registeredDates[reminder.alarmID] = date
        reminder.pendingSnoozeAt = nil
        reminder.alarmNeedsUpdate = false
        reminder.alarmState = .registered
        reminder.alarmError = nil
    }

    func disableAlarm(_ reminder: Reminder) {
        guard !isBusy, reminder.completedAt == nil else { return }
        do {
            try alarms.cancel(reminder.alarmID)
            registeredDates.removeValue(forKey: reminder.alarmID)
            reminder.alarmDisabled = true
            reminder.alarmNeedsUpdate = false
            reminder.pendingSnoozeAt = nil
            reminder.alarmState = .absent
            reminder.alarmError = nil
            saveChanges()
        } catch {
            log(error)
            errorMessage = String(localized: "Could not turn off the alarm. The task is unchanged. Try again.")
        }
    }

    private func calendarRequest(_ reminder: Reminder, allowCreate: Bool = false) -> CalendarRequest {
        CalendarRequest(id: reminder.id, title: reminder.title, date: reminder.scheduledAt,
            calendarID: reminder.calendarIdentifier, eventID: reminder.calendarEventID,
            externalID: reminder.calendarExternalID, previousDate: reminder.calendarEventDate, allowCreate: allowCreate)
    }

    @discardableResult
    private func syncCalendar(_ reminder: Reminder) -> Bool {
        guard reminder.calendarEnabled == true else { return true }
        let request = calendarRequest(reminder, allowCreate: reminder.calendarEventDate == nil && reminder.calendarEventID == nil)
        do {
            guard calendar.hasAccess() else { throw CalendarError.permission }
            reminder.calendarNeedsSync = true
            if request.allowCreate { reminder.calendarEventDate = reminder.scheduledAt }
            guard saveChanges() else { return false }
            let identity = try calendar.upsert(request)
            reminder.calendarEventID = identity.eventID
            reminder.calendarExternalID = identity.externalID
            reminder.calendarIdentifier = identity.calendarID
            reminder.calendarEventDate = reminder.scheduledAt
            reminder.calendarNeedsSync = false
            reminder.calendarError = nil
            return saveChanges()
        } catch {
            // These adapter validations happen before writing; retrying a first insert is safe.
            if request.allowCreate, let failure = error as? CalendarError, failure == .permission || failure == .destination {
                reminder.calendarEventDate = nil
            }
            reminder.calendarNeedsSync = true
            reminder.calendarError = (error as? CalendarError)?.errorDescription
                ?? String(localized: "Calendar could not be updated. The task is kept; check alarm status separately. Retry Calendar sync.")
            log(error)
            _ = saveChanges()
            return false
        }
    }

    func retryCalendar(_ reminder: Reminder) {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        _ = syncCalendar(reminder)
    }

    func refreshCalendar() {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            for item in try context.fetch(FetchDescriptor<Reminder>()) where item.completedAt == nil && item.calendarEnabled == true {
                _ = syncCalendar(item)
            }
        } catch { log(error) }
    }

    func incompleteReminder(id: UUID) throws -> Reminder {
        let reminder = try reminder(id: id)
        guard reminder.completedAt == nil else { throw SnoozeError.completed }
        return reminder
    }

    private enum SnoozeError: LocalizedError {
        case missing, completed
        var errorDescription: String? {
            switch self {
            case .missing: String(localized: "This reminder was deleted.")
            case .completed: String(localized: "This task is already completed.")
            }
        }
    }

    func complete(_ reminder: Reminder) {
        guard !isBusy, reminder.completedAt == nil else { return }
        do {
            try alarms.cancel(reminder.alarmID)
            registeredDates.removeValue(forKey: reminder.alarmID)
            reminder.alarmNeedsUpdate = false
            reminder.completedAt = .now
            reminder.pendingSnoozeAt = nil
            reminder.alarmState = .absent
            reminder.alarmError = nil
            saveChanges()
        } catch {
            log(error)
            errorMessage = String(localized: "Could not cancel the alarm. Task remains incomplete. Try again.")
        }
    }

    @discardableResult
    func delete(_ reminder: Reminder, keepCalendarEvent: Bool = false) -> Bool {
        guard !isBusy else { return false }
        do {
            try alarms.cancel(reminder.alarmID)
            registeredDates.removeValue(forKey: reminder.alarmID)
            if !keepCalendarEvent && (reminder.calendarEventID != nil || reminder.calendarEventDate != nil) {
                try calendar.remove(calendarRequest(reminder))
            }
            context.delete(reminder)
            return saveChanges()
        } catch {
            log(error)
            errorMessage = String(localized: "Could not delete the task safely. Its alarm may be off; the task is kept. Check Calendar access and retry.")
            return false
        }
    }

    /// A foreground snapshot only: absence cannot distinguish stopped from removed alarms.
    /// This never schedules an alarm or changes task completion.
    func refresh() {
        guard !isBusy else { return }
        do {
            let dates = try alarms.scheduledAlarms()
            registeredDates = dates
            for reminder in try context.fetch(FetchDescriptor<Reminder>()) where reminder.completedAt == nil {
                if reminder.alarmNeedsUpdate == true {
                    reminder.alarmState = .failed
                    reminder.alarmError = String(localized: "The task was saved, but its alarm needs an update. Choose an alarm time to retry.")
                } else if let pending = reminder.pendingSnoozeAt {
                    if dates[reminder.alarmID] == pending {
                        reminder.nextAlarmAt = pending
                        reminder.pendingSnoozeAt = nil
                        reminder.alarmState = .registered
                        reminder.alarmError = nil
                    } else {
                        reminder.alarmState = .failed
                        reminder.alarmError = String(localized: "Snooze was interrupted or failed. Choose a time to retry.")
                    }
                } else if dates[reminder.alarmID] != nil {
                    reminder.alarmState = .registered
                    reminder.alarmError = nil
                } else if reminder.alarmState != .failed {
                    reminder.alarmState = .absent
                }
            }
            saveChanges()
        } catch {
            registeredDates = [:]
            // Stale registration must never be presented as a fresh confirmation.
            log(error)
            errorMessage = String(localized: "Could not check system alarms. Reopen Nudge to retry.")
        }
    }

    private func friendlyMessage(_ error: Error) -> String {
        if error is Reminder.ValidationError || error is SnoozeError || error is AlarmService.AlarmError {
            return error.localizedDescription
        }
        return String(localized: "Could not schedule the alarm. Check alarm access in Settings and choose a time to retry. Task completion is unchanged.")
    }

    private func log(_ error: Error) {
        Logger(subsystem: "com.pavlovilya.nudge", category: "ReminderStore")
            .error("Operation failed: \(error.localizedDescription, privacy: .public)")
    }

    @discardableResult
    private func saveChanges() -> Bool {
        do {
            try saveContext(context)
            return true
        } catch {
            context.rollback()
            log(error)
            errorMessage = String(localized: "Could not save changes. The system alarm may already have changed. Reopen Nudge to check, then retry.")
            return false
        }
    }
}
