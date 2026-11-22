import SwiftUI

struct SnoozeView: View {
    @Environment(\.dismiss) private var dismiss
    let reminder: Reminder
    let store: ReminderStore
    @State private var selectedInterval: SnoozeInterval?
    @State private var date = Date.now.addingTimeInterval(300)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(reminder.title).font(.headline)
                    LabeledContent("Next alarm") {
                        Text(date, format: .dateTime.month().day().hour().minute())
                    }
                }
                Section("Snooze for") {
                    ForEach(SnoozeInterval.allCases) { interval in
                        Button {
                            selectedInterval = interval
                            let target = interval.date(from: .now)
                            date = target
                            save(target)
                        } label: {
                            HStack {
                                if interval == .hour { Text("1 hour") }
                                else { Text("\(interval.rawValue) minutes") }
                                Spacer()
                                if selectedInterval == interval {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .listRowBackground(selectedInterval == interval ? Color.accentColor.opacity(0.15) : nil)
                    }
                }
                Section("Choose a date") {
                    DatePicker("When", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                        .onChange(of: date) { _, _ in
                            if !store.isBusy { selectedInterval = nil }
                        }
                    Button("Schedule alarm") { save(date) }
                        .frame(minHeight: 44)
                        .disabled(date <= .now)
                }
                if let error = store.errorMessage {
                    Section { Text(error).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
                }
                if store.isBusy { ProgressView("Saving and scheduling…") }
            }
            .navigationTitle("Choose Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .disabled(store.isBusy)
            .interactiveDismissDisabled(store.isBusy)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func save(_ date: Date) {
        Task {
            if await store.snooze(id: reminder.id, until: date) { dismiss() }
        }
    }
}
