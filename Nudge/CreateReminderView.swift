import SwiftUI

struct CreateReminderView: View {
    @Environment(\.dismiss) private var dismiss
    let store: ReminderStore
    @AppStorage(AlarmSound.preferenceKey) private var defaultSound: AlarmSound = AlarmSound.newReminderDefault
    @AppStorage(CalendarService.defaultKey) private var calendarDefault = false
    @AppStorage(CalendarService.destinationKey) private var calendarID = ""
    @State private var calendarEnabled = false
    @State private var soundOverride: AlarmSound?
    @State private var title = ""
    @State private var date: Date?
    @State private var alarmEnabled = false
    @State private var recurrence: RecurrenceRule?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Task title", text: $title, axis: .vertical)
                TaskScheduleFields(date: $date, alarmEnabled: $alarmEnabled)
                RecurrencePicker(rule: $recurrence, date: $date)
                DisclosureGroup("Sound and Calendar") {
                    Picker("Reminder sound", selection: $soundOverride) {
                        Text("Use default (\(defaultSound.title))").tag(AlarmSound?.none)
                        ForEach(AlarmSound.allCases) { sound in Text(sound.title).tag(Optional(sound)) }
                    }
                    SoundDetails(sound: soundOverride ?? defaultSound, compact: true)
                    CalendarTaskToggle(enabled: $calendarEnabled, hasExistingLink: false, compact: true)
                }
                if let error = store.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                if store.isBusy { ProgressView("Saving and scheduling…") }
            }
            .task {
                let calendar = CalendarService.live
                calendarEnabled = calendarDefault && calendar.hasAccess() && calendar.destinations().contains { $0.id == calendarID }
            }
            .navigationTitle("New task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(store.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            store.errorMessage = nil
                            if await store.create(title: title, date: date, sound: soundOverride ?? defaultSound, calendarEnabled: calendarEnabled, calendarID: calendarID.isEmpty ? nil : calendarID, alarmEnabled: alarmEnabled, recurrence: recurrence) { dismiss() }
                        }
                    }
                    .disabled(store.isBusy || !ReminderDraft(sourceText: "", title: title, date: date, warnings: [], recurrence: recurrence).canCreate(now: .now, alarmEnabled: alarmEnabled))
                }
            }
            .disabled(store.isBusy)
            .interactiveDismissDisabled(store.isBusy)
        }
    }
}


/// Shared optional task deadline and alarm controls. An explicitly enabled alarm
/// reveals a real future value; there is no hidden hasDate confirmation flag.
struct TaskScheduleFields: View {
    @Binding var date: Date?
    @Binding var alarmEnabled: Bool
    var canEnableAlarm = true

    var body: some View {
        Group {
            if date != nil {
                DatePicker("When", selection: Binding(get: { date ?? .now }, set: { date = $0 }), displayedComponents: [.date, .hourAndMinute])
                Button("Remove date", systemImage: "calendar.badge.minus") { date = nil; alarmEnabled = false }
            } else {
                Button("Add date", systemImage: "calendar.badge.plus") { date = .now.addingTimeInterval(3600) }
            }
            Toggle("Alarm", isOn: Binding(get: { alarmEnabled }, set: { enabled in
                alarmEnabled = enabled
                if enabled, (date.map { $0 <= .now } ?? true) { date = .now.addingTimeInterval(3600) }
            })).disabled(!canEnableAlarm)
            if alarmEnabled, (date.map { $0 <= .now } ?? true) {
                Text("Choose a date and time in the future.").font(.footnote).foregroundStyle(.orange)
            }
        }
    }
}
