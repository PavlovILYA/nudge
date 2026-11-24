import SwiftUI

struct CreateReminderView: View {
    @Environment(\.dismiss) private var dismiss
    let store: ReminderStore
    @AppStorage(AlarmSound.preferenceKey) private var defaultSound: AlarmSound = .systemDefault
    @AppStorage(CalendarService.defaultKey) private var calendarDefault = false
    @AppStorage(CalendarService.destinationKey) private var calendarID = ""
    @State private var calendarEnabled = false
    @State private var soundOverride: AlarmSound?
    @State private var title = ""
    @State private var date = Date.now.addingTimeInterval(300)

    var body: some View {
        NavigationStack {
            Form {
                TextField("Task title", text: $title, axis: .vertical)
                DatePicker("When", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                Picker("Reminder sound", selection: $soundOverride) {
                    Text("Use default (\(defaultSound.title))").tag(AlarmSound?.none)
                    ForEach(AlarmSound.allCases) { sound in
                        Text(sound.title).tag(Optional(sound))
                    }
                }
                .pickerStyle(.navigationLink)
                SoundDetails(sound: soundOverride ?? defaultSound)
                CalendarTaskToggle(enabled: $calendarEnabled, hasExistingLink: false)
                if let error = store.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                if store.isBusy { ProgressView("Saving and scheduling…") }
            }
            .task {
                let calendar = CalendarService.live
                calendarEnabled = calendarDefault && calendar.hasAccess() && calendar.destinations().contains { $0.id == calendarID }
            }
            .navigationTitle("New reminder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(store.isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            store.errorMessage = nil
                            if await store.create(title: title, date: date, sound: soundOverride ?? defaultSound, calendarEnabled: calendarEnabled, calendarID: calendarID.isEmpty ? nil : calendarID) { dismiss() }
                        }
                    }
                    .disabled(store.isBusy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || date <= .now)
                }
            }
            .disabled(store.isBusy)
            .interactiveDismissDisabled(store.isBusy)
        }
    }
}
