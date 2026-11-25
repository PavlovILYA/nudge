import AppIntents
import Foundation
import OSLog
import Observation
import SwiftData

/// LiveActivityIntent executes in the app process, including on a cold launch.
struct ChooseTimeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Actions"
    static let supportedModes: IntentModes = .foreground
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let isDiscoverable = false

    @Parameter(title: "Reminder ID") var reminderID: String

    @Parameter(title: "Alarm ID") var alarmID: String
    init() { reminderID = ""; alarmID = "" }
    init(reminderID: String, alarmID: String = "") { self.reminderID = reminderID; self.alarmID = alarmID }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await open(in: ReminderPersistence.container().mainContext)
        return .result()
    }

    @MainActor
    func open(in context: ModelContext, alarms: AlarmService = .live) async throws {
        guard let id = UUID(uuidString: reminderID), alarmID.isEmpty || UUID(uuidString: alarmID) != nil else { throw RequestError.invalidID }
        let store = ReminderStore(context: context, alarms: alarms)
        if await store.prepareActions(id: id, expectedAlarmID: alarmID.isEmpty ? id : UUID(uuidString: alarmID)) {
            SnoozeRequest.shared.reminderID = id
        } else if store.errorMessage != nil {
            throw RequestError.failed
        }
    }

    private enum RequestError: LocalizedError {
        case invalidID, failed
        var errorDescription: String? {
            switch self {
            case .invalidID: String(localized: "The reminder identifier is invalid.")
            case .failed: String(localized: "Actions could not be opened safely. Open Nudge to check the alarm.")
            }
        }
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
    @Parameter(title: "Alarm ID") var alarmID: String
    init() { reminderID = ""; occurrenceID = ""; alarmID = "" }
    init(reminderID: String, occurrenceID: String = "", alarmID: String = "") {
        self.reminderID = reminderID; self.occurrenceID = occurrenceID; self.alarmID = alarmID
    }

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
        guard let item = try context.fetch(descriptor).first else { return }
        guard alarmID.isEmpty || UUID(uuidString: alarmID) != nil else { throw IntentError.invalidID }
        // Pre-build7 configurations used the task UUID as their system ID.
        let expectedRegistration = alarmID.isEmpty ? id : UUID(uuidString: alarmID)
        let logger = Logger(subsystem: "com.pavlovilya.nudge", category: "AlarmActions")
        logger.info("stop_intent_received task=\(id.uuidString, privacy: .public) alarm=\(self.alarmID, privacy: .public)")
        guard item.alarmID == expectedRegistration else {
            logger.info("stop_intent_ignored_stale_registration")
            return
        }
        guard occurrenceID.isEmpty || UUID(uuidString: occurrenceID) != nil else { throw IntentError.invalidID }
        guard await store.completeCurrent(id: id, expectedOccurrence: UUID(uuidString: occurrenceID)) else { throw IntentError.failed }
        logger.info("stop_intent_finished completed=\(item.completedAt != nil) pending=\(item.alarmNeedsUpdate == true) alarm=\(item.alarmID.uuidString, privacy: .public)")
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
