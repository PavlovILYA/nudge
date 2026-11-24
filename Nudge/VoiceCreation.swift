import Foundation
import Observation

/// One confirmation may create at most one durable task, even after partial system failures.
@MainActor @Observable
final class VoiceCreation {
    private(set) var isSaving = false
    private(set) var createdID: UUID?

    func confirm(draft: ReminderDraft, now: Date, save: (String, Date) async -> UUID?) async throws -> UUID? {
        guard !isSaving, createdID == nil else { return nil }
        let value = try draft.validated(now: now)
        isSaving = true
        defer { isSaving = false }
        createdID = await save(value.title, value.date)
        return createdID
    }
}
