import AppIntents
import Foundation
import Observation

/// LiveActivityIntent executes in the app process, including on a cold launch.
struct ChooseTimeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Choose Time"
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
        var errorDescription: String? { "The reminder identifier is invalid." }
    }
}

/// One pending presentation request; shared by the intent and the app's only window.
@MainActor @Observable
final class SnoozeRequest {
    static let shared = SnoozeRequest()
    var reminderID: UUID?
}
