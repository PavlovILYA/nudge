import AppIntents
import Foundation
import Observation
import SwiftData

/// LiveActivityIntent executes in the app process, including on a cold launch.
struct ChooseTimeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Actions"
    static let supportedModes: IntentModes = .foreground
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let isDiscoverable = false

    @Parameter(title: "Reminder ID") var reminderID: String

    init() { reminderID = "" }
    init(reminderID: String) { self.reminderID = reminderID }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: reminderID) else { throw RequestError.invalidID }
        SnoozeRequest.shared.reminderID = id
        return .result()
    }

    private enum RequestError: LocalizedError {
        case invalidID
        var errorDescription: String? { String(localized: "The reminder identifier is invalid.") }
    }
}

/// One pending presentation request; shared by the intent and the app's only window.
@MainActor @Observable
final class SnoozeRequest {
    static let shared = SnoozeRequest()
    var reminderID: UUID?
}


/// System Stop deliberately completes the task. This is separate from opening
/// Actions, which must never mutate completion or call the Stop handler.
struct CompleteTaskIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Done"
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @Parameter(title: "Reminder ID") var reminderID: String
    @Parameter(title: "Occurrence ID") var occurrenceID: String
    init() { reminderID = ""; occurrenceID = "" }
    init(reminderID: String, occurrenceID: String = "") { self.reminderID = reminderID; self.occurrenceID = occurrenceID }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await complete(in: ReminderPersistence.container().mainContext)
        return .result()
    }

    @MainActor
    func complete(in context: ModelContext, alarms: AlarmService = .live) async throws {
        guard let id = UUID(uuidString: reminderID) else { throw IntentError.invalidID }
        let store = ReminderStore(context: context, alarms: alarms)
        let descriptor = FetchDescriptor<Reminder>(predicate: #Predicate { $0.id == id })
        guard try context.fetch(descriptor).first != nil else { return }
        guard occurrenceID.isEmpty || UUID(uuidString: occurrenceID) != nil else { throw IntentError.invalidID }
        guard await store.completeCurrent(id: id, expectedOccurrence: UUID(uuidString: occurrenceID)) else { throw IntentError.failed }
    }

    private enum IntentError: LocalizedError {
        case invalidID, failed
        var errorDescription: String? {
            switch self {
            case .invalidID: String(localized: "The reminder identifier is invalid.")
            case .failed: String(localized: "Task completion could not finish. Open Nudge to check and retry.")
            }
        }
    }
}
