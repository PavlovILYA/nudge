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

    func complete(_ reminder: Reminder) {
        guard !isBusy, reminder.completedAt == nil else { return }
        do {
            try alarms.cancel(reminder.alarmID)
            reminder.completedAt = .now
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
            let ids = try alarms.alarmIDs()
            for reminder in try context.fetch(FetchDescriptor<Reminder>()) where reminder.completedAt == nil {
                if ids.contains(reminder.alarmID) {
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

    private func saveChanges() {
        do {
            try context.save()
        } catch {
            context.rollback()
            errorMessage = "Could not save changes. System alarm changes may already have taken effect. Reopen Nudge to check, then retry. \(error.localizedDescription)"
        }
    }
}
