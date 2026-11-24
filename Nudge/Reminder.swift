import Foundation
import SwiftData

@Model
final class Reminder {
    @Attribute(.unique) private(set) var id: UUID
    private(set) var title: String
    private(set) var scheduledAt: Date
    private(set) var createdAt: Date
    // Optional additions preserve the 0.1.0 store through lightweight migration.
    var nextAlarmAt: Date?
    var pendingSnoozeAt: Date?
    var soundModeID: String?
    var alarmDisabled: Bool?
    var alarmNeedsUpdate: Bool?
    var calendarEnabled: Bool?
    var calendarIdentifier: String?
    var calendarEventID: String?
    var calendarExternalID: String?
    var calendarEventDate: Date?
    var calendarNeedsSync: Bool?
    var calendarError: String?
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

    func applyEdit(title: String, date: Date, sound: AlarmSound) {
        self.title = title
        self.scheduledAt = date
        self.soundModeID = sound.rawValue
    }

    var sound: AlarmSound { AlarmSound(rawValue: soundModeID ?? "") ?? .systemDefault }

    var effectiveAlarmAt: Date { nextAlarmAt ?? scheduledAt }

    static func validateSnoozeDate(_ date: Date, now: Date = .now) throws {
        guard date.timeIntervalSince1970.isFinite, date > now else { throw ValidationError.pastDate }
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
            case .emptyTitle: String(localized: "Enter a task title.")
            case .pastDate: String(localized: "Choose a date and time in the future.")
            }
        }
    }
}

enum AlarmRegistration: String, Codable {
    case unconfirmed, registered, failed, absent
}

enum SnoozeInterval: Int, CaseIterable, Identifiable {
    case five = 5, ten = 10, fifteen = 15, thirty = 30, hour = 60
    var id: Int { rawValue }
    func date(from now: Date) -> Date { now.addingTimeInterval(Double(rawValue * 60)) }
}
