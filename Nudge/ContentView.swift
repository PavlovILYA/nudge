import AlarmKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Reminder.scheduledAt) private var reminders: [Reminder]
    @State private var store: ReminderStore
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
                            showingCompleted ? "No completed reminders" : "No reminders",
                            systemImage: showingCompleted ? "checkmark.circle" : "alarm",
                            description: Text(showingCompleted ? "Tasks you mark done appear here." : "Tap + to create your first reminder.")
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
                                Text(reminder.scheduledAt, format: .dateTime.month().day().year().hour().minute())
                                    .font(.subheadline)
                                if reminder.state(at: timeline.date) == .overdue {
                                    Label("Overdue", systemImage: "exclamationmark.circle")
                                        .foregroundStyle(.red)
                                } else if reminder.completedAt != nil {
                                    Label("Completed", systemImage: "checkmark.circle")
                                }
                                if reminder.completedAt == nil {
                                    alarmStatus(reminder)
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
                ToolbarItem(placement: .primaryAction) {
                    Button("Create reminder", systemImage: "plus") { showingCreate = true }
                }
            }
            .disabled(store.isBusy)
            .overlay {
                if store.isBusy { ProgressView("Saving and scheduling…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
            }
            .sheet(isPresented: $showingCreate) { CreateReminderView(store: store) }
            .alert("Nudge", isPresented: Binding(
                get: { store.errorMessage != nil && !showingCreate },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { store.refresh() }
            }
            .task {
                store.refresh()
                for await _ in AlarmManager.shared.alarmUpdates {
                    guard !Task.isCancelled else { return }
                    store.refresh()
                }
            }
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
            Label("Alarm not confirmed: \(reminder.alarmError ?? "Scheduling failed")", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}
