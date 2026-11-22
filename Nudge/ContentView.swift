import AlarmKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Reminder.scheduledAt) private var reminders: [Reminder]
    @State private var store: ReminderStore
    @State private var snoozeRequest = SnoozeRequest.shared
    @State private var snoozingReminder: Reminder?
    @State private var showingSettings = false
    @State private var showingCreate = false
    @State private var showingCompleted = false

    init(context: ModelContext) {
        _store = State(initialValue: ReminderStore(context: context))
    }

    private var visibleReminders: [Reminder] {
        reminders.filter { showingCompleted == ($0.completedAt != nil) }
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                List {
                    Section {
                        Toggle("Show completed", isOn: $showingCompleted)
                    }
                    if visibleReminders.isEmpty {
                        ContentUnavailableView(
                            showingCompleted ? String(localized: "No completed reminders") : String(localized: "No reminders"),
                            systemImage: showingCompleted ? "checkmark.circle" : "alarm",
                            description: Text(showingCompleted ? String(localized: "Tasks you mark done appear here.") : String(localized: "Tap + to create your first reminder."))
                        )
                    }
                    ForEach(visibleReminders) { reminder in
                        HStack(alignment: .top, spacing: 12) {
                            if reminder.completedAt == nil {
                                Button {
                                    store.complete(reminder)
                                } label: {
                                    Image(systemName: "circle")
                                        .font(.title2)
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Complete \(reminder.title)")
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(reminder.title).font(.headline)
                                Text(reminder.sound.title).font(.caption).foregroundStyle(.secondary)
                                Text(reminder.scheduledAt, format: .dateTime.month().day().year().hour().minute())
                                    .font(.subheadline)
                                if let next = reminder.nextAlarmAt {
                                    Text("Next alarm: \(next.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.subheadline).foregroundStyle(.tint)
                                }
                                if reminder.state(at: timeline.date) == .overdue {
                                    Label("Overdue", systemImage: "exclamationmark.circle")
                                        .foregroundStyle(.red)
                                } else if reminder.completedAt != nil {
                                    Label("Completed", systemImage: "checkmark.circle")
                                }
                                if reminder.completedAt == nil {
                                    alarmStatus(reminder)
                                    Button("Choose Time", systemImage: "clock.arrow.circlepath") {
                                        store.errorMessage = nil
                                        snoozingReminder = reminder
                                    }
                                    .buttonStyle(.borderless)
                                    .frame(minHeight: 44)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { store.delete(reminder) }
                        }
                    }
                    Section {
                        Text("Stopping an alarm does not complete its task. Mark it done here when finished.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Nudge")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Create reminder", systemImage: "plus") { showingCreate = true }
                }
            }
            .disabled(store.isBusy)
            .overlay {
                if store.isBusy { ProgressView("Saving and scheduling…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            }
            .sheet(isPresented: $showingSettings, onDismiss: presentRequestedSnooze) { SoundSettingsView() }
            .sheet(isPresented: $showingCreate, onDismiss: presentRequestedSnooze) { CreateReminderView(store: store) }
            .sheet(item: $snoozingReminder, onDismiss: presentRequestedSnooze) { reminder in
                SnoozeView(reminder: reminder, store: store)
            }
            .onChange(of: snoozeRequest.reminderID) { _, _ in presentRequestedSnooze() }
            .onChange(of: store.isBusy) { _, busy in
                if !busy { presentRequestedSnooze() }
            }
            .alert("Nudge", isPresented: Binding(
                get: { store.errorMessage != nil && !showingCreate && !showingSettings && snoozingReminder == nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { store.refresh(); presentRequestedSnooze() }
            }
            .task {
                store.refresh()
                presentRequestedSnooze()
                for await _ in AlarmManager.shared.alarmUpdates {
                    guard !Task.isCancelled else { return }
                    store.refresh()
                }
            }
        }
    }

    private func presentRequestedSnooze() {
        guard let id = snoozeRequest.reminderID, !store.isBusy else { return }
        if showingSettings {
            showingSettings = false
            return
        }
        if showingCreate {
            showingCreate = false
            return // Present after the existing sheet has dismissed.
        }
        if let current = snoozingReminder, current.id != id {
            snoozingReminder = nil
            return
        }
        snoozeRequest.reminderID = nil
        do {
            snoozingReminder = try store.incompleteReminder(id: id)
            store.errorMessage = nil
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func alarmStatus(_ reminder: Reminder) -> some View {
        switch reminder.alarmState {
        case .registered:
            Text("Alarm registered at last check").font(.caption).foregroundStyle(.secondary)
        case .unconfirmed:
            Label("Alarm not confirmed", systemImage: "questionmark.circle").font(.caption)
        case .absent:
            Label("No alarm registered · may have ended or stopped", systemImage: "alarm.waves.left.and.right.slash")
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Label("Alarm not confirmed. Choose a time to retry.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
