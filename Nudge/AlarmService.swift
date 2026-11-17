import AlarmKit
import SwiftUI

/// The only system boundary. Tests supply closures and never request permissions.
@MainActor
struct AlarmService {
    var schedule: (UUID, String, Date) async throws -> Void
    var cancel: (UUID) throws -> Void
    var alarmIDs: () throws -> Set<UUID>

    static let live = AlarmService(
        schedule: { id, title, date in
            let manager = AlarmManager.shared
            let authorization = try await manager.requestAuthorization()
            guard authorization == .authorized else { throw AlarmError.authorizationDenied }
            // Authorization may have taken long enough for the chosen time to pass.
            guard date > .now else { throw Reminder.ValidationError.pastDate }
            let alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: title),
                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle")
            )
            let attributes = AlarmAttributes<ReminderAlarmMetadata>(
                presentation: AlarmPresentation(alert: alert), tintColor: .accentColor
            )
            let configuration = AlarmManager.AlarmConfiguration(schedule: .fixed(date), attributes: attributes)
            _ = try await manager.schedule(id: id, configuration: configuration)
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
        alarmIDs: { Set(try AlarmManager.shared.alarms.map(\.id)) }
    )

    private enum AlarmError: LocalizedError {
        case authorizationDenied
        var errorDescription: String? {
            "Alarm permission is denied. Allow alarms for Nudge in Settings. This task is saved without a confirmed alarm."
        }
    }
}

private struct ReminderAlarmMetadata: AlarmMetadata {}
