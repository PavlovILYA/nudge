import AlarmKit
import OSLog
import SwiftUI

/// The only system boundary. Tests supply closures and never request permissions.
@MainActor
struct AlarmService {
    var authorize: () async throws -> Void = {}
    var schedule: (UUID, String, Date, AlarmSound) async throws -> Void
    var cancel: (UUID) throws -> Void
    var scheduledAlarms: () throws -> [UUID: Date]

    static let live = AlarmService(
        authorize: {
            let manager = AlarmManager.shared
            let authorization = try await manager.requestAuthorization()
            guard authorization == .authorized else { throw AlarmError.authorizationDenied }
        },
        schedule: { id, title, date, sound in
            let manager = AlarmManager.shared
            try Reminder.validateSnoozeDate(date)
            if sound.filename != nil, sound.resourceURL() == nil { throw AlarmError.missingSound }
            let chooseTime = AlarmButton(text: "Snooze", textColor: .white, systemImageName: "clock.arrow.circlepath")
            let alert: AlarmPresentation.Alert
            if #available(iOS 26.1, *) {
                // Modern iOS owns the stop control and may render the custom action as Open.
                alert = AlarmPresentation.Alert(
                    title: LocalizedStringResource(stringLiteral: title),
                    secondaryButton: chooseTime, secondaryButtonBehavior: .custom)
            } else {
                alert = AlarmPresentation.Alert(
                    title: LocalizedStringResource(stringLiteral: title),
                    stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"),
                    secondaryButton: chooseTime, secondaryButtonBehavior: .custom)
            }
            let attributes = AlarmAttributes<ReminderAlarmMetadata>(
                presentation: AlarmPresentation(alert: alert), tintColor: .accentColor
            )
            let configuration = AlarmManager.AlarmConfiguration(
                schedule: .fixed(date), attributes: attributes,
                secondaryIntent: ChooseTimeIntent(reminderID: id.uuidString), sound: sound.alertSound)
            let logger = Logger(subsystem: "com.pavlovilya.nudge", category: "AlarmScheduling")
            logger.info("Scheduling id=\(id.uuidString, privacy: .public) mode=\(sound.rawValue, privacy: .public) sound=\(sound.diagnostic, privacy: .public) date=\(date.ISO8601Format(), privacy: .public)")
            _ = try await manager.schedule(id: id, configuration: configuration)
            logger.info("Registration accepted id=\(id.uuidString, privacy: .public); delivery/audio/haptics unverified")
        },
        cancel: { id in
            let manager = AlarmManager.shared
            do {
                try manager.cancel(id: id)
            } catch {
                // Already-ended alarms are safe to forget. A failed read isn't proof of absence.
                guard let alarms = try? manager.alarms, !alarms.contains(where: { $0.id == id }) else {
                    throw error
                }
            }
        },
        scheduledAlarms: {
            var dates: [UUID: Date] = [:]
            for alarm in try AlarmManager.shared.alarms {
                if case .fixed(let date) = alarm.schedule { dates[alarm.id] = date }
            }
            return dates
        }
    )

    enum AlarmError: LocalizedError {
        case authorizationDenied, missingSound
        var errorDescription: String? {
            switch self {
            case .authorizationDenied:
                String(localized: "Alarm permission is denied. Allow alarms for Nudge in Settings.")
            case .missingSound:
                String(localized: "The selected sound file is missing. The alarm could not be scheduled.")
            }
        }
    }
}

private struct ReminderAlarmMetadata: AlarmMetadata {}
