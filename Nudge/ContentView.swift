import AlarmKit
import EventKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Reminder.scheduledAt) private var reminders: [Reminder]
    @State private var store: ReminderStore
    @State private var snoozeRequest = SnoozeRequest.shared
    @State private var launchRequest = AppLaunchRequest.shared
    @State private var confirmingSwitch = false
    @State private var pendingExternal = false
    @State private var showCompleted = false
    @State private var sheet: TaskSheet?
    @State private var pendingSheet: TaskSheet?

    private enum TaskSheet: Identifiable, Equatable {
        case create, settings, voice, edit(UUID), enableAlarm(UUID), snooze(UUID)
        var id: String { String(describing: self) }
    }

    init(context: ModelContext) { _store = State(initialValue: ReminderStore(context: context)) }

    private var visible: [Reminder] {
        reminders.filter { ($0.completedAt != nil) == showCompleted }
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                List {
                    Picker("Tasks", selection: $showCompleted) {
                        Text("Active").tag(false)
                        Text("Completed").tag(true)
                    }.pickerStyle(.segmented)
                    if visible.isEmpty { Text("Nothing here yet").foregroundStyle(.secondary) }
                    ForEach(visible) { reminder in
                        taskRow(reminder, at: timeline.date)
                            .contextMenu {
                                Button("Edit task", systemImage: "pencil") { present(.edit(reminder.id)) }
                                if reminder.completedAt == nil {
                                    Button("Done", systemImage: "checkmark.circle") { completeTask(reminder) }
                                    Button("Change time", systemImage: "calendar") { present(.edit(reminder.id)) }
                                    if store.isAlerting(reminder) {
                                        Button("Actions", systemImage: "ellipsis.circle") { present(.snooze(reminder.id)) }
                                    }
                                    if !hasSignal(reminder) {
                                        Button("Enable alarm", systemImage: "alarm") { toggleAlarm(reminder) }
                                    } else {
                                        Button("Turn off alarm", systemImage: "alarm.slash") { store.disableAlarm(reminder) }
                                    }
                                }
                                Button("Delete", role: .destructive) { store.delete(reminder) }
                            }
                            .swipeActions { Button("Delete", role: .destructive) { store.delete(reminder) } }
                    }
                }
            }
            .navigationTitle(showCompleted ? String(localized: "Completed tasks") : String(localized: "Tasks"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { present(.settings) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Voice reminder", systemImage: "mic") { present(.voice) }
                }
                ToolbarItem(placement: .primaryAction) { Button("Create task", systemImage: "plus") { present(.create) } }
            }
            .disabled(store.isBusy)
            .sheet(item: $sheet, onDismiss: { confirmingSwitch = false; consumePending() }) { destination in
                Group {
                switch destination {
                case .create: CreateReminderView(store: store)
                case .settings: SoundSettingsView()
                case .voice: VoiceCaptureView(store: store) { present(.edit($0)) }
                case .enableAlarm(let id):
                    if let reminder = try? store.incompleteReminder(id: id) {
                        EditReminderView(reminder: reminder, store: store, enableAlarmOnOpen: true) { present(.snooze(id)) }
                    }
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
                .confirmationDialog("Open the requested screen?", isPresented: $confirmingSwitch, titleVisibility: .visible) {
                    Button("Discard input and open", role: .destructive) { sheet = nil }
                    Button("Keep editing", role: .cancel) { pendingSheet = nil; pendingExternal = false }
                } message: { Text("Unsaved input in the current screen will be discarded. Your saved tasks are kept.") }
            }
            .alert("Nudge", isPresented: Binding(get: { store.errorMessage != nil && sheet == nil && pendingSheet == nil },
                set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
            .onOpenURL { handleURL($0) }
            .onChange(of: reminders.filter { $0.completedAt != nil }.map(\.id)) { _, completed in
                if case .snooze(let id) = sheet, completed.contains(id) { sheet = nil }
            }
            .onChange(of: launchRequest.url) { _, _ in consumeLaunchRequest() }
            .onChange(of: snoozeRequest.reminderID) { _, _ in consumeAlarmRequest() }
            .onChange(of: store.isBusy) { _, busy in if !busy { store.refresh(); consumePending() } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { store.refresh(); store.refreshCalendar(); await store.upgradeAlarmActions(); await store.recoverRecurringAlarms(); store.refresh() } } }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged).receive(on: RunLoop.main)) { _ in
                store.refreshCalendar()
            }
            .task {
                store.refresh()
                store.refreshCalendar()
                await store.upgradeAlarmActions()
                await store.recoverRecurringAlarms()
                store.refresh()
                consumeAlarmRequest()
                consumeLaunchRequest()
                for await _ in AlarmManager.shared.alarmUpdates {
                    guard !Task.isCancelled else { return }
                    store.refresh()
                }
            }
        }
    }

    private func taskRow(_ reminder: Reminder, at now: Date) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button { completeTask(reminder) } label: {
                Image(systemName: reminder.completedAt == nil ? "circle" : "checkmark.circle.fill")
                    .font(.title2).frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless).disabled(reminder.completedAt != nil)
            .accessibilityLabel("Done")
            Button { present(.edit(reminder.id)) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reminder.title).font(.headline)
                    if let rule = reminder.recurrence { Text(rule.title).font(.caption).foregroundStyle(.secondary) }
                    if let date = reminder.occurrenceDate {
                        Text(date, format: .dateTime.month().day().hour().minute()).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if reminder.state(at: now) == .overdue {
                        Text("Overdue").font(.caption).foregroundStyle(.orange)
                    }
                    if let date = store.activeAlarmDate(for: reminder, at: now), date != reminder.occurrenceDate {
                        Text("Alarm: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.tint)
                    }
                    if reminder.alarmError != nil || reminder.alarmState == .failed { Text("Alarm needs attention").font(.caption).foregroundStyle(.orange) }
                    if reminder.calendarError != nil { Text("Calendar needs attention").font(.caption).foregroundStyle(.orange) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            if reminder.completedAt == nil {
                Button { toggleAlarm(reminder) } label: {
                    Image(systemName: hasSignal(reminder) ? "alarm" : "alarm.slash")
                        .frame(width: 44, height: 44)
                        .foregroundStyle(reminder.alarmError != nil ? Color.orange : (hasSignal(reminder) ? Color.accentColor : Color.secondary))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(hasSignal(reminder) ? Text("Turn off alarm") : Text("Enable alarm"))
            }
        }
    }

    private func completeTask(_ reminder: Reminder) {
        let token = reminder.occurrenceID
        Task { _ = await store.completeCurrent(id: reminder.id, expectedOccurrence: token) }
    }

    private func hasSignal(_ reminder: Reminder) -> Bool {
        store.activeAlarmDate(for: reminder) != nil || store.isAlerting(reminder)
    }

    private func toggleAlarm(_ reminder: Reminder) {
        if hasSignal(reminder) { store.disableAlarm(reminder) }
        else if let date = reminder.occurrenceDate, date > .now {
            Task { _ = await store.enableAlarm(id: reminder.id) }
        } else { present(.enableAlarm(reminder.id)) }
    }

    private func consumeAlarmRequest() {
        guard let id = snoozeRequest.reminderID else { return }
        snoozeRequest.reminderID = nil
        present(.snooze(id), external: true)
    }
    private func handleURL(_ url: URL) {
        guard let route = AppRoute(url: url) else {
            store.errorMessage = String(localized: "The reminder link is invalid."); return
        }
        switch route {
        case .voice: present(.voice, external: true)
        case .reminder(let id): present(.edit(id), external: true)
        }
    }
    private func consumeLaunchRequest() {
        guard let url = launchRequest.url else { return }
        launchRequest.url = nil
        handleURL(url)
    }
    private func consumePending() {
        guard let target = pendingSheet, !store.isBusy else { return }
        guard sheet == nil || pendingExternal else { return }
        let external = pendingExternal
        pendingSheet = nil; pendingExternal = false
        present(target, external: external)
    }
    private func present(_ target: TaskSheet, external: Bool = false) {
        guard sheet != target else { return }
        guard !store.isBusy else { pendingSheet = target; pendingExternal = external; return }
        if external, let sheet, sheet != .settings {
            pendingSheet = target; pendingExternal = true; confirmingSwitch = true
            return
        }
        if sheet != nil { pendingSheet = target; pendingExternal = external; sheet = nil; return }
        do {
            switch target {
            case .edit(let id): _ = try store.reminder(id: id)
            case .snooze(let id), .enableAlarm(let id): _ = try store.incompleteReminder(id: id)
            default: break
            }
            store.errorMessage = nil
            sheet = target
        } catch { store.errorMessage = error.localizedDescription }
    }
}
