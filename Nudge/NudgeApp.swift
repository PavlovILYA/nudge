import OSLog
import SwiftData
import SwiftUI

@main
struct NudgeApp: App {
    @UIApplicationDelegateAdaptor(NudgeAppDelegate.self) private var appDelegate
    private let container: ModelContainer?

    init() {
        do {
            container = try ReminderPersistence.container()
        } catch {
            container = nil
            Logger(subsystem: "com.pavlovilya.nudge", category: "Storage")
                .fault("Could not open reminders domain=\((error as NSError).domain, privacy: .public) code=\((error as NSError).code, privacy: .public)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if let container {
                ContentView(context: container.mainContext)
                    .modelContainer(container)
            } else {
                ContentUnavailableView {
                    Label("Reminders unavailable", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("Nudge could not open its saved reminders. Close and reopen the app to retry. Your data has not been reset.")
                }
            }
        }
    }
}


/// LiveActivityIntent runs in this app process. Reuse the exact default store and
/// MainActor context, including while an interactive scheduling call is suspended.
@MainActor
enum ReminderPersistence {
    private static var cached: ModelContainer?
    static func container() throws -> ModelContainer {
        if let cached { return cached }
        let container = try ModelContainer(for: Reminder.self)
        cached = container
        return container
    }
}
