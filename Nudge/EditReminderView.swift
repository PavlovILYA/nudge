import SwiftUI

struct EditReminderView: View {
    @Environment(\.dismiss) private var dismiss
    let reminder: Reminder
    let store: ReminderStore
    let onSnooze: () -> Void
    @AppStorage(CalendarService.destinationKey) private var destinationID = ""
    @State private var confirmingDelete = false
    @State private var title: String
    @State private var date: Date?
    @State private var alarmEnabled: Bool
    @State private var recurrence: RecurrenceRule?
    @State private var sound: AlarmSound
    @State private var calendarEnabled: Bool

    init(reminder: Reminder, store: ReminderStore, enableAlarmOnOpen: Bool = false, onSnooze: @escaping () -> Void) {
        self.reminder = reminder
        self.store = store
        self.onSnooze = onSnooze
        _title = State(initialValue: reminder.title)
        _recurrence = State(initialValue: reminder.recurrence)
        _date = State(initialValue: enableAlarmOnOpen && (reminder.scheduledAt.map { $0 <= .now } ?? true) ? Date.now.addingTimeInterval(3600) : reminder.scheduledAt)
        _alarmEnabled = State(initialValue: reminder.completedAt == nil && (enableAlarmOnOpen || (reminder.alarmEnabled && (store.activeAlarmDate(for: reminder) != nil || store.isAlerting(reminder) || reminder.alarmNeedsUpdate == true))))
        _sound = State(initialValue: reminder.sound)
        _calendarEnabled = State(initialValue: reminder.calendarEnabled == true)
    }

    private var canSave: Bool {
        let draft = ReminderDraft(sourceText: "", title: title, date: date, warnings: [], alarmEnabled: alarmEnabled, recurrence: recurrence)
        if draft.canCreate(now: .now, alarmEnabled: alarmEnabled) { return true }
        // Metadata edits preserve a future Snooze without moving an overdue deadline.
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && date != nil
            && date == reminder.scheduledAt && recurrence == reminder.recurrence && reminder.alarmDisabled != true && reminder.alarmNeedsUpdate != true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Task title", text: $title, axis: .vertical)
                    TaskScheduleFields(date: $date, alarmEnabled: $alarmEnabled, canEnableAlarm: reminder.completedAt == nil)
                    RecurrencePicker(rule: $recurrence, date: $date)
                    if reminder.recurrence != nil, let next = reminder.nextOccurrenceAt {
                        LabeledContent("Next occurrence") { Text(next, format: .dateTime.month().day().hour().minute()) }
                    }
                    Picker("Reminder sound", selection: $sound) {
                        ForEach(AlarmSound.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("Changing the task time updates its Calendar event. Snooze changes only the next alarm.")
                }
                SoundDetails(sound: sound)
                CalendarTaskToggle(enabled: $calendarEnabled, hasExistingLink: reminder.calendarEventID != nil)
                CalendarTaskStatus(reminder: reminder, store: store)
                if reminder.completedAt == nil {
                    Section {
                        Button("Done", systemImage: "checkmark.circle") {
                            if store.finishSeries(reminder) { dismiss() }
                        }
                        if reminder.recurrence != nil {
                            Button("Finish series", role: .destructive) { if store.finishSeries(reminder) { dismiss() } }
                        }
                        if store.isAlerting(reminder) { Button("Actions", systemImage: "ellipsis.circle", action: onSnooze) }
                        if reminder.alarmDisabled != true {
                            Button("Turn off alarm", systemImage: "alarm.waves.left.and.right.slash") {
                                store.disableAlarm(reminder)
                                alarmEnabled = reminder.alarmDisabled != true
                            }
                        }
                    } header: { Text("Task actions") } footer: {
                        Text("Actions apply to the saved task. Use Save to apply changes in this form.")
                    }
                } else {
                    Label("Completed", systemImage: "checkmark.circle")
                }
                if !reminder.completedOccurrences.isEmpty {
                    DisclosureGroup("Completed occurrences") {
                        ForEach(reminder.completedOccurrences.reversed(), id: \.id) { item in
                            Text(item.completedAt, format: .dateTime.month().day().year().hour().minute())
                        }
                    }
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
                                calendarEnabled: calendarEnabled, calendarID: destinationID.isEmpty ? nil : destinationID, alarmEnabled: alarmEnabled, recurrence: recurrence) { dismiss() }
                        }
                    }.disabled(!canSave)
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
            .onChange(of: reminder.completedAt) { _, completed in if completed != nil { alarmEnabled = false } }
            .onChange(of: reminder.alarmDisabled) { _, disabled in if disabled == true { alarmEnabled = false } }
            .disabled(store.isBusy)
            .interactiveDismissDisabled(store.isBusy)
        }
    }
}
