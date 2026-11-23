import SwiftUI

struct EditReminderView: View {
    @Environment(\.dismiss) private var dismiss
    let reminder: Reminder
    let store: ReminderStore
    let onSnooze: () -> Void
    @AppStorage(CalendarService.destinationKey) private var destinationID = ""
    @State private var confirmingDelete = false
    @State private var title: String
    @State private var date: Date
    @State private var sound: AlarmSound
    @State private var calendarEnabled: Bool

    init(reminder: Reminder, store: ReminderStore, onSnooze: @escaping () -> Void) {
        self.reminder = reminder
        self.store = store
        self.onSnooze = onSnooze
        _title = State(initialValue: reminder.title)
        _date = State(initialValue: reminder.scheduledAt)
        _sound = State(initialValue: reminder.sound)
        _calendarEnabled = State(initialValue: reminder.calendarEnabled == true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Task title", text: $title, axis: .vertical)
                    DatePicker("Original task time", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    Picker("Reminder sound", selection: $sound) {
                        ForEach(AlarmSound.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("Changing the task time moves its deadline and Calendar event, and resets Snooze. A moved task needs a future date.")
                }
                SoundDetails(sound: sound)
                CalendarTaskToggle(enabled: $calendarEnabled, hasExistingLink: reminder.calendarEventID != nil)
                CalendarTaskStatus(reminder: reminder, store: store)
                if reminder.completedAt == nil {
                    Section {
                        Button("Done", systemImage: "checkmark.circle") {
                            store.complete(reminder)
                            if reminder.completedAt != nil { dismiss() }
                        }
                        Button("Snooze", systemImage: "clock.arrow.circlepath", action: onSnooze)
                        Button("Turn off alarm", systemImage: "alarm.waves.left.and.right.slash") { store.disableAlarm(reminder) }
                        if reminder.alarmDisabled == true { Text("Alarm is off. The task is not completed.").foregroundStyle(.secondary) }
                    } header: { Text("Task actions") } footer: {
                        Text("Actions apply to the saved task. Use Save to apply changes in this form.")
                    }
                } else {
                    Label("Completed", systemImage: "checkmark.circle")
                }
                Section {
                    Button("Delete task", role: .destructive) { confirmingDelete = true }
                }
                if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
                if store.isBusy { ProgressView("Saving and scheduling…") }
            }
            .navigationTitle("Edit task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await store.edit(id: reminder.id, title: title, date: date, sound: sound,
                                calendarEnabled: calendarEnabled, calendarID: destinationID.isEmpty ? nil : destinationID) { dismiss() }
                        }
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Delete task?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete task and linked event", role: .destructive) {
                    if store.delete(reminder) { dismiss() }
                }
                if reminder.calendarEventID != nil || reminder.calendarEventDate != nil {
                    Button("Delete task only", role: .destructive) {
                        if store.delete(reminder, keepCalendarEvent: true) { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The alarm is cancelled in either case. Deleting only the task leaves Calendar unchanged, even if the linked event cannot be found.")
            }
            .disabled(store.isBusy)
            .interactiveDismissDisabled(store.isBusy)
        }
    }
}
