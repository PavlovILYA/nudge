import Foundation
import SwiftData

@Model
final class Reminder {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var title: String
    private(set) var scheduledAt: Date
    private(set) var createdAt: Date
    var completedAt: Date?
    private(set) var alarmID: UUID
    var alarmState: AlarmRegistration
    var alarmError: String?

    init(id: UUID = UUID(), title: String, scheduledAt: Date, now: Date = .now) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ValidationError.emptyTitle }
        guard scheduledAt > now else { throw ValidationError.pastDate }
        self.id = id
        self.title = title
        self.scheduledAt = scheduledAt
        self.createdAt = now
        self.alarmID = id
        self.alarmState = .unconfirmed
    }

    func state(at now: Date) -> TaskState {
        if completedAt != nil { return .completed }
        return scheduledAt > now ? .pending : .overdue
    }

    enum TaskState { case pending, overdue, completed }

    enum ValidationError: LocalizedError {
        case emptyTitle, pastDate
        var errorDescription: String? {
            switch self {
            case .emptyTitle: "Enter a task title."
            case .pastDate: "Choose a date and time in the future."
            }
        }
    }
}

enum AlarmRegistration: String, Codable {
    case unconfirmed, registered, failed, absent
}
