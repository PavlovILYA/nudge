import Foundation
import Observation

/// One confirmation may create at most one durable task, even after partial system failures.
@MainActor @Observable
final class VoiceCreation {
    private(set) var isSaving = false
    private(set) var createdID: UUID?

    func confirm(draft: ReminderDraft, now: Date, alarmEnabled: Bool? = nil, save: (String, Date?) async -> UUID?) async throws -> UUID? {
        guard !isSaving, createdID == nil else { return nil }
        let value = try draft.validated(now: now, alarmEnabled: alarmEnabled)
        isSaving = true
        defer { isSaving = false }
        // Validation may trim for emptiness checks; the visible voice text is saved verbatim.
        createdID = await save(draft.title, value.date)
        return createdID
    }
}

/// Interpretation fills untouched fields; explicit user edits always win.
struct VoiceTaskFields: Sendable {
    private(set) var date: Date?
    private(set) var alarmEnabled = false
    private(set) var recurrence: RecurrenceRule?
    private var recurrenceEdited = false
    private var dateEdited = false
    private var alarmEdited = false

    mutating func apply(_ draft: ReminderDraft) {
        if !dateEdited { date = draft.date }
        if !dateEdited && !alarmEdited { alarmEnabled = draft.alarmEnabled }
        if !recurrenceEdited { recurrence = draft.recurrence }
    }
    func draft(text: String, warnings: [ReminderDraft.Warning] = []) -> ReminderDraft {
        ReminderDraft(sourceText: text, title: text, date: date, warnings: warnings, alarmEnabled: alarmEnabled, recurrence: recurrence)
    }

    mutating func editRecurrence(_ value: RecurrenceRule?) { recurrence = value; recurrenceEdited = true }
    mutating func editDate(_ value: Date?) { date = value; dateEdited = true }
    mutating func editAlarm(_ value: Bool) { alarmEnabled = value; alarmEdited = true }
}
