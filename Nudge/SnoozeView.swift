import SwiftUI

struct SnoozeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let reminder: Reminder
    let store: ReminderStore
    var onEdit: () -> Void = {}
    @State private var selectedInterval: SnoozeInterval?
    @State private var date = Date.now.addingTimeInterval(300)
    @State private var choosingDate = false
    @State private var minutes = 7

    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 92), spacing: 8)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(reminder.title).font(.headline)
                    LabeledContent("Next alarm") {
                        Text(date, format: .dateTime.month().day().hour().minute())
                    }
                    .font(.subheadline)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(SnoozeInterval.allCases) { interval in
                            Button {
                                selectedInterval = interval
                                let target = interval.date(from: .now)
                                date = target
                                save(target)
                            } label: {
                                HStack(spacing: 4) {
                                    if interval == .hour { Text("1 hr") }
                                    else { Text("\(interval.rawValue) min") }
                                    if selectedInterval == interval { Image(systemName: "checkmark") }
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .tint(.accentColor)
                            .background(selectedInterval == interval ? Color.accentColor.opacity(0.15) : .clear,
                                        in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel(interval == .hour
                                ? Text("1 hour") : Text("\(interval.rawValue) minutes"))
                            .accessibilityAddTraits(selectedInterval == interval ? .isSelected : [])
                        }
                    }
                    Stepper(value: $minutes, in: 1...1440) { Text("\(minutes) minutes") }
                    Button("Snooze for selected minutes") {
                        selectedInterval = nil
                        save(Date.now.addingTimeInterval(Double(minutes) * 60))
                    }.buttonStyle(.bordered).frame(minHeight: 44)
                    Button("Other date and time", systemImage: "calendar") {
                        selectedInterval = nil
                        withAnimation { choosingDate.toggle() }
                    }
                    .frame(minHeight: 44)
                    .accessibilityValue(choosingDate ? Text("Expanded") : Text("Collapsed"))
                    if choosingDate {
                        DatePicker("When", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                        Button("Schedule alarm") { save(date) }
                            .buttonStyle(.borderedProminent)
                            .frame(minHeight: 44)
                            .disabled(date <= .now)
                    }
                    Button("Turn off alarm", systemImage: "alarm.slash") {
                        if store.disableAlarm(reminder) { dismiss() }
                    }
                    Button("Edit task", systemImage: "pencil", action: onEdit)
                        .frame(minHeight: 44)
                    if let error = store.errorMessage {
                        Text(error).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently)
                    }
                    if store.isBusy { ProgressView("Saving and scheduling…") }
                }
                .padding()
            }
            .navigationTitle("Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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
