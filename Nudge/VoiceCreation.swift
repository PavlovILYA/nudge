import Foundation
import Observation

/// One confirmation may create at most one durable task, even after partial system failures.
@MainActor @Observable
final class VoiceCreation {
    private(set) var isSaving = false
    private(set) var createdID: UUID?

    func confirm(draft: ReminderDraft, now: Date, alarmEnabled: Bool = true, save: (String, Date?) async -> UUID?) async throws -> UUID? {
        guard !isSaving, createdID == nil else { return nil }
        let value = try draft.validated(now: now, alarmEnabled: alarmEnabled)
        isSaving = true
        defer { isSaving = false }
        createdID = await save(value.title, value.date)
        return createdID
    }
}

/// Interpretation fills untouched fields; explicit user edits always win.
struct VoiceTaskFields: Sendable {
    private(set) var title = ""
    private(set) var date: Date?
    private(set) var alarmEnabled = false
    private var titleEdited = false
    private var dateEdited = false
    private var alarmEdited = false

    mutating func apply(_ draft: ReminderDraft) {
        if !titleEdited { title = draft.title }
        if !dateEdited { date = draft.date }
        if !dateEdited && !alarmEdited { alarmEnabled = draft.date != nil }
    }
    mutating func editTitle(_ value: String) { title = value; titleEdited = true }
    mutating func editDate(_ value: Date?) { date = value; dateEdited = true }
    mutating func editAlarm(_ value: Bool) { alarmEnabled = value; alarmEdited = true }
}
