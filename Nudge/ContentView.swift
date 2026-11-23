import AlarmKit
import EventKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Reminder.scheduledAt) private var reminders: [Reminder]
    @State private var store: ReminderStore
    @State private var snoozeRequest = SnoozeRequest.shared
    @State private var section = TaskSection.tasks
    @State private var sheet: TaskSheet?
    @State private var pendingSheet: TaskSheet?

    private enum TaskSection: String, CaseIterable {
        case alarms, tasks, history
        var title: String {
            switch self {
            case .alarms: String(localized: "Alarms")
            case .tasks: String(localized: "Tasks")
            case .history: String(localized: "History")
            }
        }
    }
    private enum TaskSheet: Identifiable, Equatable {
        case create, settings, edit(UUID), snooze(UUID)
        var id: String { String(describing: self) }
    }

    init(context: ModelContext) { _store = State(initialValue: ReminderStore(context: context)) }

    private func visible(at now: Date) -> [Reminder] {
        reminders.filter {
            switch section {
            case .alarms: store.activeAlarmDate(for: $0, at: now) != nil
            case .tasks: $0.completedAt == nil
            case .history: $0.completedAt != nil
            }
        }
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                List {
                    Picker("Section", selection: $section) {
                        ForEach(TaskSection.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    if visible(at: timeline.date).isEmpty {
                        Text("Nothing here yet").foregroundStyle(.secondary)
                    }
                    ForEach(visible(at: timeline.date)) { reminder in
                        HStack(alignment: .top) {
                            Button { present(.edit(reminder.id)) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(reminder.title).font(.headline)
                                    Text(reminder.sound.title).font(.caption).foregroundStyle(.secondary)
                                    Text(reminder.scheduledAt, format: .dateTime.month().day().year().hour().minute()).font(.subheadline)
                                    if reminder.completedAt != nil {
                                        Label("Completed", systemImage: "checkmark.circle")
                                    } else {
                                        if let date = store.activeAlarmDate(for: reminder, at: timeline.date) {
                                            Text("Alarm: \(date.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.tint)
                                        } else if reminder.alarmDisabled == true {
                                            Text("Alarm is off").foregroundStyle(.secondary)
                                        } else {
                                            Text("No upcoming alarm confirmed").foregroundStyle(.secondary)
                                        }
                                        if reminder.state(at: timeline.date) == .overdue {
                                            Label("Overdue", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                                        }
                                        if reminder.alarmState == .failed { Text("Alarm needs attention").foregroundStyle(.orange) }
                                        if reminder.calendarEnabled == true {
                                            Text(reminder.calendarError != nil ? String(localized: "Calendar needs attention") : String(localized: "Calendar linked"))
                                                .font(.caption).foregroundStyle(reminder.calendarError != nil ? .orange : .secondary)
                                        }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            if reminder.completedAt == nil {
                                Button("Snooze", systemImage: "clock.arrow.circlepath") { present(.snooze(reminder.id)) }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
                            }
                        }
                        .contextMenu {
                            Button("Edit task", systemImage: "pencil") { present(.edit(reminder.id)) }
                            if reminder.completedAt == nil {
                                Button("Done", systemImage: "checkmark.circle") { store.complete(reminder) }
                                Button("Snooze", systemImage: "clock.arrow.circlepath") { present(.snooze(reminder.id)) }
                                Button("Turn off alarm", systemImage: "alarm.slash") { store.disableAlarm(reminder) }
                                Button("Move task", systemImage: "calendar") { present(.edit(reminder.id)) }
                            }
                            Button("Delete", role: .destructive) { store.delete(reminder) }
                        }
                        .swipeActions { Button("Delete", role: .destructive) { store.delete(reminder) } }
                    }
                }
            }
            .navigationTitle("Nudge")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Settings", systemImage: "gearshape") { present(.settings) } }
                ToolbarItem(placement: .primaryAction) { Button("Create reminder", systemImage: "plus") { present(.create) } }
            }
            .disabled(store.isBusy)
            .sheet(item: $sheet, onDismiss: consumePending) { destination in
                switch destination {
                case .create: CreateReminderView(store: store)
                case .settings: SoundSettingsView()
                case .edit(let id):
                    if let reminder = try? store.reminder(id: id) {
                        EditReminderView(reminder: reminder, store: store) { present(.snooze(id)) }
                    }
                case .snooze(let id):
                    if let reminder = try? store.incompleteReminder(id: id) {
                        SnoozeView(reminder: reminder, store: store) { present(.edit(id)) }
                    }
                }
            }
            .alert("Nudge", isPresented: Binding(get: { store.errorMessage != nil && sheet == nil && pendingSheet == nil },
                set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .onOpenURL { url in
                guard let id = ReminderLink.id(from: url) else {
                    store.errorMessage = String(localized: "The reminder link is invalid."); return
                }
                present(.edit(id))
            }
            .onChange(of: snoozeRequest.reminderID) { _, _ in consumeAlarmRequest() }
            .onChange(of: store.isBusy) { _, busy in if !busy { consumePending() } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { store.refresh(); store.refreshCalendar() } }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: RunLoop.main)) { _ in
                store.refreshCalendar()
            }
            .task {
                store.refresh()
                store.refreshCalendar()
                consumeAlarmRequest()
                for await _ in AlarmManager.shared.alarmUpdates {
                    guard !Task.isCancelled else { return }
                    store.refresh()
                }
            }
        }
    }

    private func consumeAlarmRequest() {
        guard let id = snoozeRequest.reminderID else { return }
        snoozeRequest.reminderID = nil
        present(.snooze(id))
    }
    private func consumePending() {
        guard let target = pendingSheet, !store.isBusy, sheet == nil else { return }
        pendingSheet = nil
        present(target)
    }
    private func present(_ target: TaskSheet) {
        guard !store.isBusy else { pendingSheet = target; return }
        guard sheet != target else { return }
        if sheet != nil { pendingSheet = target; sheet = nil; return }
        do {
            switch target {
            case .edit(let id): _ = try store.reminder(id: id)
            case .snooze(let id): _ = try store.incompleteReminder(id: id)
            default: break
            }
            store.errorMessage = nil
            sheet = target
        } catch { store.errorMessage = error.localizedDescription }
    }
}
