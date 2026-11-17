import SwiftUI

struct CreateReminderView: View {
    @Environment(\.dismiss) private var dismiss
    let store: ReminderStore
    @State private var title = ""
    @State private var date = Date.now.addingTimeInterval(300)

    var body: some View {
        NavigationStack {
            Form {
                TextField("Task title", text: $title, axis: .vertical)
                DatePicker("When", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                if let error = store.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                if store.isBusy { ProgressView("Saving and scheduling…") }
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
                            if await store.create(title: title, date: date) { dismiss() }
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
