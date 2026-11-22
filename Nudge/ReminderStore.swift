import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ReminderStore {
    private let context: ModelContext
    private let alarms: AlarmService
    private(set) var isBusy = false
    var errorMessage: String?

    init(context: ModelContext, alarms: AlarmService = .live) {
        self.context = context
        self.alarms = alarms
        context.autosaveEnabled = false
    }

    /// True means the task was saved, even when its alarm failed.
    func create(title: String, date: Date) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        let reminder: Reminder
        do {
            reminder = try Reminder(title: title, scheduledAt: date)
            context.insert(reminder)
            // This durable ID also covers termination during authorization/scheduling.
            try context.save()
        } catch {
            context.rollback()
            errorMessage = "Could not save reminder: \(error.localizedDescription)"
            return false
        }
        do {
            try await alarms.authorize()
            try await alarms.schedule(reminder.alarmID, reminder.title, reminder.scheduledAt)
            reminder.alarmState = .registered
            reminder.alarmError = nil
        } catch {
            reminder.alarmState = .failed
            reminder.alarmError = error.localizedDescription
            errorMessage = "Reminder saved. Alarm not confirmed: \(error.localizedDescription)"
        }
        saveChanges()
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
            if systemDate != date {
                reminder.pendingSnoozeAt = date
                reminder.alarmState = .unconfirmed
                reminder.alarmError = nil
                guard saveChanges() else { return false }
                pendingReminder = reminder
                // cancel removes both an alerting alarm and its old schedule.
                try alarms.cancel(reminder.alarmID)
                try await alarms.schedule(reminder.alarmID, reminder.title, date)
            }
            reminder.nextAlarmAt = date
            reminder.pendingSnoozeAt = nil
            reminder.alarmState = .registered
            reminder.alarmError = nil
            return saveChanges()
        } catch {
            if let reminder = pendingReminder {
                reminder.alarmState = .failed
                reminder.alarmError = error.localizedDescription
                guard saveChanges() else { return false }
            }
            errorMessage = "Could not snooze: \(error.localizedDescription) Check the alarm status and choose a time to retry. Task completion is unchanged."
            return false
        }
    }

    func incompleteReminder(id: UUID) throws -> Reminder {
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
        guard let reminder = try context.fetch(descriptor).first else { throw SnoozeError.missing }
        guard reminder.completedAt == nil else { throw SnoozeError.completed }
        return reminder
    }

    private enum SnoozeError: LocalizedError {
        case missing, completed
        var errorDescription: String? {
            switch self {
            case .missing: "This reminder was deleted."
            case .completed: "This task is already completed."
            }
        }
    }

    func complete(_ reminder: Reminder) {
        guard !isBusy, reminder.completedAt == nil else { return }
        do {
            try alarms.cancel(reminder.alarmID)
            reminder.completedAt = .now
            reminder.pendingSnoozeAt = nil
            reminder.alarmState = .absent
            reminder.alarmError = nil
            saveChanges()
        } catch {
            errorMessage = "Could not cancel the alarm. Task remains incomplete. Try again. \(error.localizedDescription)"
        }
    }

    func delete(_ reminder: Reminder) {
        guard !isBusy else { return }
        do {
            try alarms.cancel(reminder.alarmID)
            context.delete(reminder)
            saveChanges()
        } catch {
            errorMessage = "Could not cancel the alarm. Reminder kept so you can retry. \(error.localizedDescription)"
        }
    }

    /// A foreground snapshot only: absence cannot distinguish stopped from removed alarms.
    /// This never schedules an alarm or changes task completion.
    func refresh() {
        guard !isBusy else { return }
        do {
            let dates = try alarms.scheduledAlarms()
            for reminder in try context.fetch(FetchDescriptor<Reminder>()) where reminder.completedAt == nil {
                if let pending = reminder.pendingSnoozeAt {
                    if dates[reminder.alarmID] == pending {
                        reminder.nextAlarmAt = pending
                        reminder.pendingSnoozeAt = nil
                        reminder.alarmState = .registered
                        reminder.alarmError = nil
                    } else {
                        reminder.alarmState = .failed
                        reminder.alarmError = "Snooze was interrupted or failed. Choose a time to retry."
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
            // Stale registration must never be presented as a fresh confirmation.
            errorMessage = "Could not check system alarms: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func saveChanges() -> Bool {
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            errorMessage = "Could not save changes. System alarm changes may already have taken effect. Reopen Nudge to check, then retry. \(error.localizedDescription)"
            return false
        }
    }
}
