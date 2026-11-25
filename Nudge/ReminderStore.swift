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
    private(set) var alertingIDs: Set<UUID> = []
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
    func create(title: String, date: Date? = nil, sound: AlarmSound? = nil, calendarEnabled: Bool = false, calendarID: String? = nil, alarmEnabled: Bool? = nil, recurrence: RecurrenceRule? = nil) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        let reminder: Reminder
        lastCreatedID = nil
        do {
            reminder = try Reminder(title: title, scheduledAt: date, alarmEnabled: alarmEnabled)
            try reminder.setRecurrence(recurrence, reset: true)
            reminder.soundModeID = (sound ?? AlarmSound.preferred()).rawValue
            reminder.calendarEnabled = calendarEnabled
            reminder.calendarIdentifier = calendarID
            reminder.alarmNeedsUpdate = reminder.alarmDisabled != true
            reminder.alarmWriteStarted = false
            reminder.pendingSnoozeAt = reminder.alarmEnabled ? reminder.occurrenceDate : nil
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
        if reminder.alarmDisabled != true, let date = reminder.occurrenceDate {
            let occurrence = reminder.occurrenceID
            do {
                try await alarms.authorize()
                let current = try incompleteReminder(id: reminder.id)
                guard current.occurrenceID == occurrence else { throw SnoozeError.changed }
                guard current.alarmDisabled != true else { throw SnoozeError.disabled }
                try await replaceAlarm(current, date: date, cancelExisting: false)
            } catch {
                if reminder.completedAt == nil && reminder.alarmDisabled != true && reminder.occurrenceID == occurrence {
                    reminder.alarmState = .failed
                    reminder.alarmError = friendlyMessage(error)
                    errorMessage = String(localized: "Task saved, but its alarm could not be enabled. Open the task to retry.")
                }
                log(error)
            }
        }
        // The initial insert is already durable. Never leave creation retrying a new UUID.
        guard saveChanges() else { return true }
        _ = syncCalendar(reminder)
        return true
    }

    /// A durable pending date bridges the non-atomic database and system operations.
    func snooze(id: UUID, until date: Date, forceUpdate: Bool = false, requireExisting: Bool = false) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        var pendingReminder: Reminder?
        var pendingOccurrence: UUID?
        do {
            try Reminder.validateSnoozeDate(date)
            let initial = try incompleteReminder(id: id)
            let wasDisabled = initial.alarmDisabled == true
            let occurrence = initial.occurrenceID
            // Never remove the old registration before permission is granted.
            try await alarms.authorize()
            try Reminder.validateSnoozeDate(date)
            let reminder = try incompleteReminder(id: id) // Authorization can suspend.
            guard reminder.occurrenceID == occurrence else { throw SnoozeError.changed }
            guard wasDisabled || reminder.alarmDisabled != true else { throw SnoozeError.disabled }
            let systemDate = try alarms.scheduledAlarms()[reminder.alarmID]
            // An upgrade is allowed only while the exact old registration still exists.
            if requireExisting && systemDate != date { return false }
            if forceUpdate || systemDate != date || reminder.alarmNeedsUpdate == true {
                reminder.alarmNeedsUpdate = true
                reminder.alarmWriteStarted = false
                reminder.pendingSnoozeAt = date
                reminder.alarmDisabled = false
                reminder.alarmState = .unconfirmed
                reminder.alarmError = nil
                guard saveChanges() else { return false }
                pendingOccurrence = reminder.occurrenceID
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
            if let reminder = pendingReminder, reminder.completedAt == nil, reminder.alarmDisabled != true, reminder.occurrenceID == pendingOccurrence {
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

    /// Metadata changes preserve Snooze; an explicit deadline change resets it.
    func edit(id: UUID, title: String, date: Date?, sound: AlarmSound, calendarEnabled: Bool, calendarID: String?, alarmEnabled: Bool? = nil, recurrence: RecurrenceRule? = nil) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        var savedReminder: Reminder?
        var savedOccurrence: UUID?
        do {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw Reminder.ValidationError.emptyTitle }
            let item = try reminder(id: id)
            let enabled = (alarmEnabled ?? (item.alarmDisabled != true)) && item.completedAt == nil
            let wasDisabled = item.alarmDisabled == true
            let occurrence = item.occurrenceID
            let moved = date != item.scheduledAt
            let repeatChanged = recurrence != item.recurrence
            if let recurrence {
                guard let date else { throw Reminder.ValidationError.pastDate }
                _ = try recurrence.first(anchor: date)
            }
            if let date, !date.timeIntervalSince1970.isFinite { throw Reminder.ValidationError.pastDate }
            let metadataChanged = title != item.title || sound != item.sound
            let dates = enabled ? try alarms.scheduledAlarms() : registeredDates
            let cancellationNeeded = item.alarmDisabled != true || item.alarmNeedsUpdate == true || dates[item.alarmID] != nil || alertingIDs.contains(item.alarmID)
            let existingFuture = dates[item.alarmID].flatMap { $0 > .now ? $0 : nil }
            let occurrenceDate = (moved || repeatChanged) ? try date.map { try recurrence?.first(anchor: $0) ?? $0 } : item.occurrenceDate
            var target = moved || wasDisabled || repeatChanged ? occurrenceDate : (item.pendingSnoozeAt ?? existingFuture ?? (item.alarmNeedsUpdate == true ? date : nil))
            var needsAlarm = enabled && (moved || wasDisabled || repeatChanged || item.alarmNeedsUpdate == true || (metadataChanged && existingFuture != nil))
            if enabled && (moved || wasDisabled || repeatChanged) {
                guard let date = target else { throw Reminder.ValidationError.pastDate }
                try Reminder.validateSnoozeDate(date)
            }
            if needsAlarm { try await alarms.authorize() }
            let current = try reminder(id: id)
            guard current.occurrenceID == occurrence else { throw SnoozeError.changed }
            guard !needsAlarm || current.completedAt == nil else { throw SnoozeError.completed }
            guard !needsAlarm || wasDisabled || current.alarmDisabled != true else { throw SnoozeError.disabled }
            if needsAlarm && !moved && !repeatChanged && !wasDisabled && current.alarmNeedsUpdate != true {
                target = try alarms.scheduledAlarms()[current.alarmID].flatMap { $0 > .now ? $0 : nil }
                needsAlarm = target != nil
            }
            if needsAlarm {
                guard let target else { throw Reminder.ValidationError.pastDate }
                try Reminder.validateSnoozeDate(target)
            }
            current.applyEdit(title: title, date: date, sound: sound)
            try current.setRecurrence(recurrence, reset: moved || repeatChanged)
            current.calendarEnabled = calendarEnabled
            if current.calendarEventID == nil && current.calendarEventDate == nil { current.calendarIdentifier = calendarID }
            current.calendarNeedsSync = calendarEnabled
            if moved || repeatChanged { current.nextAlarmAt = nil; current.pendingSnoozeAt = nil }
            if !enabled {
                current.alarmDisabled = true
                current.nextAlarmAt = nil
                current.pendingSnoozeAt = nil
                current.alarmNeedsUpdate = cancellationNeeded // Persist cancellation before touching AlarmKit.
            } else if needsAlarm {
                current.alarmWriteStarted = false
                current.pendingSnoozeAt = target
                current.alarmNeedsUpdate = true
                current.alarmDisabled = false
                current.alarmState = .unconfirmed
            }
            guard saveChanges() else { return false }
            savedOccurrence = current.occurrenceID
            savedReminder = current
            if !enabled && cancellationNeeded { try cancelRegistration(current) }
            else if needsAlarm, let target {
                try await replaceAlarm(current, date: target)
                current.nextAlarmAt = target == date ? nil : target
            }
            guard saveChanges() else { return false }
            return syncCalendar(current)
        } catch {
            if let item = savedReminder, item.completedAt == nil, item.occurrenceID == savedOccurrence {
                item.alarmState = .failed
                item.alarmError = friendlyMessage(error)
                _ = saveChanges()
                _ = syncCalendar(item)
            }
            log(error)
            errorMessage = friendlyMessage(error)
            return false
        }
    }

    private func replaceAlarm(_ reminder: Reminder, date: Date, cancelExisting: Bool = true) async throws {
        let id = reminder.id
        let token = reminder.occurrenceID
        try await AlarmWriteQueue.perform(id: reminder.alarmID) {
            let current = try self.incompleteReminder(id: id)
            guard current.occurrenceID == token else { throw SnoozeError.changed }
            try await self.writeAlarm(current, date: date, cancelExisting: cancelExisting, token: token)
        }
    }

    private func writeAlarm(_ reminder: Reminder, date: Date, cancelExisting: Bool, token: UUID?) async throws {
        let id = reminder.id
        let alarmID = reminder.alarmID
        guard reminder.completedAt == nil else { throw SnoozeError.completed }
        guard reminder.alarmDisabled != true else { throw SnoozeError.disabled }
        try Reminder.validateSnoozeDate(date)
        if cancelExisting { try alarms.cancel(alarmID) }
        registeredDates.removeValue(forKey: alarmID)
        alertingIDs.remove(alarmID)
        reminder.alarmWriteStarted = true
        // This evidence distinguishes an uncertain new write from an old same-date alarm.
        try saveContext(context)
        // Stop/disable/delete can interleave while schedule() suspends. A late
        // system registration must not resurrect the task's alarm.
        do {
            try await alarms.register(alarmID, title: reminder.title, date: date, sound: reminder.sound, occurrenceID: token)
            let current = try incompleteReminder(id: id)
            guard current.occurrenceID == token else { throw SnoozeError.changed }
            guard current.alarmDisabled != true else { throw SnoozeError.disabled }
            registeredDates[alarmID] = date
            current.pendingSnoozeAt = nil
            current.alarmNeedsUpdate = false
            current.alarmWriteStarted = false
            current.alarmActionsVersion = AlarmService.actionsVersion
            current.alarmState = .registered
            current.alarmError = nil
        } catch {
            let schedulingError = error
            // An uncertain write for the still-current occurrence is reconciled
            // by its durable pending date, without deleting an accepted alarm.
            if let current = try context.fetch(FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })).first,
               current.completedAt == nil, current.alarmDisabled != true, current.occurrenceID == token {
                throw schedulingError
            }
            do { try alarms.cancel(alarmID) }
            catch {
                if let item = try context.fetch(FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })).first {
                    item.alarmNeedsUpdate = true
                    item.alarmError = String(localized: "Alarm cancellation is pending. Open Nudge to retry.")
                    _ = saveChanges()
                }
                throw error
            }
            throw schedulingError
        }
    }

    private func cancelRegistration(_ reminder: Reminder) throws {
        try alarms.cancel(reminder.alarmID)
        registeredDates.removeValue(forKey: reminder.alarmID)
        alertingIDs.remove(reminder.alarmID)
        reminder.alarmNeedsUpdate = false
        reminder.alarmWriteStarted = false
        reminder.alarmState = .absent
        reminder.alarmError = nil
    }

    @discardableResult
    func disableAlarm(_ reminder: Reminder) -> Bool {
        guard !isBusy, reminder.completedAt == nil else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        reminder.alarmDisabled = true
        reminder.alarmNeedsUpdate = true
        reminder.pendingSnoozeAt = nil
        reminder.nextAlarmAt = nil
        guard saveChanges() else { return false }
        do {
            try cancelRegistration(reminder)
            return saveChanges()
        } catch {
            reminder.alarmError = String(localized: "Alarm cancellation is pending. Open Nudge to retry.")
            _ = saveChanges()
            log(error)
            errorMessage = reminder.alarmError
            return false
        }
    }

    func enableAlarm(id: UUID) async -> Bool {
        do {
            let item = try incompleteReminder(id: id)
            guard let date = item.occurrenceDate else { throw Reminder.ValidationError.pastDate }
            try Reminder.validateSnoozeDate(date)
            return await snooze(id: id, until: date)
        } catch { errorMessage = friendlyMessage(error); return false }
    }

    func isAlerting(_ reminder: Reminder) -> Bool {
        reminder.completedAt == nil && alertingIDs.contains(reminder.alarmID)
    }

    /// Reconfigure only real future registrations from older versions; never
    /// recreate an absent/disabled alarm, and retain the stable alarm ID/date.
    func upgradeAlarmActions() async {
        guard !isBusy else { return }
        do {
            let dates = try alarms.scheduledAlarms()
            let items = try context.fetch(FetchDescriptor<Reminder>())
            for item in items where item.completedAt == nil && item.alarmDisabled != true
                && item.alarmActionsVersion != AlarmService.actionsVersion && item.alarmNeedsUpdate != true
                && item.pendingSnoozeAt == nil && item.alarmState != .failed {
                if let date = dates[item.alarmID], date > .now { _ = await snooze(id: item.id, until: date, forceUpdate: true, requireExisting: true) }
            }
        } catch { log(error) }
    }

    private func calendarRequest(_ reminder: Reminder, date: Date, allowCreate: Bool = false) -> CalendarRequest {
        CalendarRequest(id: reminder.id, title: reminder.title, date: date,
            calendarID: reminder.calendarIdentifier, eventID: reminder.calendarEventID,
            externalID: reminder.calendarExternalID, previousDate: reminder.calendarEventDate, allowCreate: allowCreate,
            recurrence: reminder.recurrence, seriesCompletedAt: reminder.completedAt)
    }

    @discardableResult
    private func syncCalendar(_ reminder: Reminder) -> Bool {
        guard reminder.calendarEnabled == true else { return true }
        guard let anchor = reminder.scheduledAt else {
            reminder.calendarNeedsSync = true // Keep any existing event until a deadline is supplied.
            reminder.calendarError = nil
            return saveChanges()
        }
        let date: Date
        do { date = try reminder.recurrence?.first(anchor: anchor) ?? anchor }
        catch { reminder.calendarError = error.localizedDescription; return saveChanges() }
        let request = calendarRequest(reminder, date: date, allowCreate: reminder.calendarEventDate == nil && reminder.calendarEventID == nil)
        do {
            guard calendar.hasAccess() else { throw CalendarError.permission }
            reminder.calendarNeedsSync = true
            if request.allowCreate { reminder.calendarEventDate = date }
            guard saveChanges() else { return false }
            let identity = try calendar.upsert(request)
            reminder.calendarEventID = identity.eventID
            reminder.calendarExternalID = identity.externalID
            reminder.calendarIdentifier = identity.calendarID
            reminder.calendarEventDate = date
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
            for item in try context.fetch(FetchDescriptor<Reminder>()) where (item.completedAt == nil || (item.recurrence != nil && item.calendarNeedsSync == true)) && item.calendarEnabled == true {
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
        case missing, completed, disabled, changed
        var errorDescription: String? {
            switch self {
            case .missing: String(localized: "This reminder was deleted.")
            case .completed: String(localized: "This task is already completed.")
            case .disabled: String(localized: "The alarm was turned off.")
            case .changed: String(localized: "The task occurrence changed. Open the task to check its next alarm.")
            }
        }
    }

    @discardableResult
    func complete(_ reminder: Reminder, entireSeries: Bool = false) -> Bool {
        guard reminder.recurrenceData == nil || entireSeries else { return false }
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        let cancellationNeeded = reminder.alarmDisabled != true || reminder.alarmNeedsUpdate == true || registeredDates[reminder.alarmID] != nil || alertingIDs.contains(reminder.alarmID)
        if reminder.completedAt == nil { reminder.completedAt = .now }
        reminder.alarmDisabled = true
        reminder.alarmNeedsUpdate = cancellationNeeded
        reminder.pendingSnoozeAt = nil
        reminder.nextAlarmAt = nil
        reminder.nextOccurrenceAt = nil
        if reminder.recurrenceData != nil && reminder.calendarEnabled == true { reminder.calendarNeedsSync = true }
        // Completion must survive a killed app or a subsequent cancellation error.
        guard saveChanges() else { return false }
        guard cancellationNeeded else { return true }
        do {
            try cancelRegistration(reminder)
            return saveChanges()
        } catch {
            reminder.alarmError = String(localized: "Task completed. Its alarm could not be cancelled yet; open Nudge to retry.")
            _ = saveChanges()
            log(error)
            errorMessage = reminder.alarmError
            return false
        }
    }

    /// Complete exactly the captured occurrence, even on a repeated cold Stop intent.
    func completeCurrent(id: UUID, expectedOccurrence: UUID?) async -> Bool {
        guard !isBusy else { return false }
        var advanced = false
        var advancedOccurrence: UUID?
        do {
            let item = try reminder(id: id)
            guard item.recurrenceData != nil else {
                guard item.occurrenceID == expectedOccurrence else { return true }
                return complete(item)
            }
            if item.completedAt != nil { return complete(item, entireSeries: true) }
            guard let rule = item.recurrence, let anchor = item.scheduledAt, let due = item.occurrenceDate else { throw RecurrenceRule.RuleError.invalid }
            guard let expectedOccurrence, item.occurrenceID == expectedOccurrence else { return true }
            isBusy = true
            defer { isBusy = false }
            let now = Date.now
            let next = try rule.next(after: max(now, due), anchor: anchor)
            var history = try item.completedOccurrencesData.map { try JSONDecoder().decode([CompletedOccurrence].self, from: $0) } ?? []
            if history.contains(where: { $0.id == expectedOccurrence }) { return true }
            history.append(CompletedOccurrence(id: expectedOccurrence, dueAt: due, completedAt: now))
            let cancellationPending = item.alarmDisabled == true && item.alarmNeedsUpdate == true
            let hadSignal = registeredDates[item.alarmID] != nil || alertingIDs.contains(item.alarmID)
            item.completedOccurrencesData = try JSONEncoder().encode(history)
            item.nextOccurrenceAt = next
            item.occurrenceID = UUID()
            advancedOccurrence = item.occurrenceID
            item.pendingSnoozeAt = item.alarmEnabled ? next : nil
            item.nextAlarmAt = nil
            item.alarmNeedsUpdate = item.alarmEnabled || cancellationPending
            item.alarmWriteStarted = false
            guard saveChanges() else { return false }
            advanced = true
            // Durable history/next token precede cancellation and registration.
            if item.alarmEnabled {
                try await alarms.authorize()
                guard item.completedAt == nil, item.alarmEnabled, item.occurrenceID == advancedOccurrence else { return true }
                try await replaceAlarm(item, date: next)
            } else if cancellationPending || hadSignal { try cancelRegistration(item) }
            guard saveChanges() else { return true }
            _ = syncCalendar(item) // Original series anchor, not nextOccurrenceAt.
            return true
        } catch {
            log(error)
            if advanced, let item = try? reminder(id: id), item.completedAt == nil, item.alarmEnabled, item.occurrenceID == advancedOccurrence {
                item.alarmNeedsUpdate = item.alarmEnabled
                item.alarmState = .failed
                item.alarmError = String(localized: "Occurrence completed. The next alarm needs a retry in Nudge.")
                _ = saveChanges()
            }
            errorMessage = advanced ? String(localized: "Occurrence completed. The next alarm needs a retry in Nudge.") : friendlyMessage(error)
            return advanced
        }
    }

    @discardableResult
    func finishSeries(_ item: Reminder) -> Bool {
        let finished = complete(item, entireSeries: true)
        if item.completedAt != nil { _ = syncCalendar(item) }
        return finished
    }

    func recoverRecurringAlarms() async {
        guard !isBusy else { return }
        do {
            let items = try context.fetch(FetchDescriptor<Reminder>())
            for item in items where item.recurrence != nil && item.alarmEnabled && item.alarmNeedsUpdate == true {
                if let date = item.pendingSnoozeAt ?? item.occurrenceDate, date > .now {
                    _ = await snooze(id: item.id, until: date)
                }
            }
        } catch { log(error) }
    }

    /// Same durable operation for a cold LiveActivityIntent and list completion.
    func complete(id: UUID) throws {
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
        guard let item = try context.fetch(descriptor).first else { return } // A deleted task stays deleted.
        guard complete(item) else { throw CompletionError.failed }
    }

    private enum CompletionError: LocalizedError {
        case failed
        var errorDescription: String? { String(localized: "Task completion could not finish. Open Nudge to check and retry.") }
    }

    @discardableResult
    func delete(_ reminder: Reminder, keepCalendarEvent: Bool = false) -> Bool {
        guard !isBusy else { return false }
        do {
            try alarms.cancel(reminder.alarmID)
            registeredDates.removeValue(forKey: reminder.alarmID)
            if !keepCalendarEvent && (reminder.calendarEventID != nil || reminder.calendarEventDate != nil) {
                guard let date = reminder.scheduledAt ?? reminder.calendarEventDate else { throw CalendarError.missing }
                try calendar.remove(calendarRequest(reminder, date: date))
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
            alertingIDs = try alarms.alertingAlarms()
            for reminder in try context.fetch(FetchDescriptor<Reminder>()) {
                if reminder.completedAt != nil || reminder.alarmDisabled == true {
                    if reminder.alarmNeedsUpdate == true || dates[reminder.alarmID] != nil || alertingIDs.contains(reminder.alarmID) {
                        do { try cancelRegistration(reminder) }
                        catch {
                            reminder.alarmNeedsUpdate = true
                            reminder.alarmError = String(localized: "Alarm cancellation is pending. Open Nudge to retry.")
                            log(error)
                        }
                    }
                    continue
                }
                let canAdopt = reminder.alarmWriteStarted == true || (reminder.alarmWriteStarted == nil && reminder.alarmNeedsUpdate != true && reminder.recurrenceData == nil)
                if let pending = reminder.pendingSnoozeAt, dates[reminder.alarmID] == pending, canAdopt {
                    reminder.nextAlarmAt = pending
                    reminder.pendingSnoozeAt = nil
                    reminder.alarmNeedsUpdate = false
                    reminder.alarmWriteStarted = false
                    reminder.alarmState = .registered
                    reminder.alarmError = nil
                } else if reminder.alarmNeedsUpdate == true {
                    reminder.alarmState = .failed
                    reminder.alarmError = String(localized: "The task was saved, but its alarm needs an update. Choose an alarm time to retry.")
                } else if reminder.pendingSnoozeAt != nil {
                    reminder.alarmState = .failed
                    reminder.alarmError = String(localized: "Snooze was interrupted or failed. Choose a time to retry.")
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
            alertingIDs = []
            // Stale registration must never be presented as a fresh confirmation.
            log(error)
            do {
                let items = try context.fetch(FetchDescriptor<Reminder>())
                if items.contains(where: { ($0.completedAt == nil && $0.alarmDisabled != true) || $0.alarmNeedsUpdate == true }) {
                    errorMessage = String(localized: "Could not check system alarms. Reopen Nudge to retry.")
                }
            } catch { errorMessage = String(localized: "Reminders unavailable") }
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
            .error("Operation failed domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public)")
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

/// Serializes writes for one system ID through their post-await state checks.
/// This is not a background scheduler; pending dates/tokens remain durable in SwiftData.
@MainActor
private enum AlarmWriteQueue {
    private struct Entry { let token: UUID; let task: Task<Void, Error> }
    private static var tails: [UUID: Entry] = [:]
    static func perform(id: UUID, operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tails[id]?.task
        let token = UUID()
        let task = Task { @MainActor in
            if let previous { do { try await previous.value } catch { /* A new operation may repair a failed one. */ } }
            try Task.checkCancellation()
            try await operation()
        }
        tails[id] = Entry(token: token, task: task)
        defer { if tails[id]?.token == token { tails.removeValue(forKey: id) } }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
