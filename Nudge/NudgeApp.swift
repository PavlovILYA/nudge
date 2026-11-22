import SwiftData
import SwiftUI

@main
struct NudgeApp: App {
    private let container: ModelContainer?
    private let storageError: String?

    init() {
        do {
            container = try ModelContainer(for: Reminder.self)
            storageError = nil
        } catch {
            container = nil
            storageError = error.localizedDescription
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
                    Text("Nudge could not open its saved reminders. Close and reopen the app to retry. Your data has not been reset.\n\(storageError ?? "")")
                }
            }
        }
    }
}
