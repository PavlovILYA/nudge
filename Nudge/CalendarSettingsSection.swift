import SwiftUI

struct CalendarSettingsSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(CalendarService.defaultKey) private var defaultEnabled = false
    @AppStorage(CalendarService.destinationKey) private var destinationID = ""
    @State private var access = false
    @State private var destinations: [CalendarDestination] = []
    @State private var busy = false
    @State private var error: String?
    private let calendar = CalendarService.live

    private var ready: Bool { access && destinations.contains { $0.id == destinationID } }

    var body: some View {
        Section {
            if !access {
                Button("Connect Apple Calendar") {
                    Task {
                        busy = true
                        defer { busy = false }
                        do { try await calendar.authorize(); error = nil }
                        catch { self.error = String(localized: "Calendar access is unavailable. Connect Calendar in Settings or allow full access in iOS Settings.") }
                        refresh()
                    }
                }
            } else {
                Picker("Calendar", selection: $destinationID) {
                    if !destinations.contains(where: { $0.id == destinationID }) {
                        Text("Choose a calendar").tag(destinationID)
                    }
                    ForEach(destinations) { Text($0.name).tag($0.id) }
                }
                Button("Create or select Nudge calendar") {
                    do { destinationID = try calendar.createCalendar(); error = nil }
                    catch { self.error = String(localized: "Choose a writable calendar in Settings. A separate Nudge calendar may not be supported by this account.") }
                    refresh()
                }
            }
            Toggle("Add new tasks to Calendar", isOn: Binding(get: { ready && defaultEnabled }, set: { defaultEnabled = $0 }))
                .disabled(!ready)
            if busy { ProgressView() }
            if let error { Text(error).foregroundStyle(.orange) }
        } header: { Text("Apple Calendar") } footer: {
            Text("Calendar access is requested only here. New events last 15 minutes and have no extra alerts. Turning this default off leaves existing tasks and events unchanged.")
        }
        .disabled(busy)
        .task { refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private func refresh() {
        access = calendar.hasAccess()
        destinations = calendar.destinations()
    }
}

struct CalendarTaskToggle: View {
    @Binding var enabled: Bool
    let hasExistingLink: Bool
    @AppStorage(CalendarService.destinationKey) private var destinationID = ""
    @Environment(\.scenePhase) private var scenePhase
    @State private var ready = false
    private let calendar = CalendarService.live

    var body: some View {
        Section {
            Toggle("Add to Calendar", isOn: $enabled).disabled(!ready && !enabled)
            if !ready { Text("Connect Calendar and choose a destination in Settings.").font(.footnote).foregroundStyle(.secondary) }
        } footer: {
            Text("Turning the link off keeps any existing event. Snooze never moves the event; changing the task date does.")
        }
        .task { refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
    }

    private func refresh() {
        ready = calendar.hasAccess() && (hasExistingLink || calendar.destinations().contains { $0.id == destinationID })
    }
}

struct CalendarTaskStatus: View {
    let reminder: Reminder
    let store: ReminderStore
    var body: some View {
        if reminder.calendarEnabled == true {
            Section("Apple Calendar") {
                if let error = reminder.calendarError { Text(error).foregroundStyle(.orange) }
                else if reminder.calendarEventID == nil || reminder.calendarNeedsSync == true { Text("Calendar update pending") }
                else { Label("Linked to Calendar", systemImage: "calendar") }
                Button("Retry Calendar sync") { store.retryCalendar(reminder) }
            }
        } else if reminder.calendarEventID != nil || reminder.calendarEventDate != nil {
            Section { Text("Calendar link is off. The previous event is kept until the task is deleted.").font(.footnote) }
        }
    }
}
