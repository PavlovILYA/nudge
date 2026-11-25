import AVFoundation
import OSLog
import SwiftUI

struct VoiceCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let store: ReminderStore
    let onOpenTask: (UUID) -> Void
    private let interpreter: any ReminderInterpreter
    @AppStorage(AlarmSound.preferenceKey) private var defaultSound: AlarmSound = AlarmSound.newReminderDefault
    @AppStorage(CalendarService.defaultKey) private var calendarDefault = false
    @AppStorage(CalendarService.destinationKey) private var calendarID = ""
    @State private var speech = SpeechTranscriptionService()
    @State private var creation = VoiceCreation()
    @State private var input = VoiceTextBuffer()
    @State private var voiceSession: UUID?
    @State private var confirmingClear = false
    @State private var showingSettings = false
    @State private var proposal: ReminderDraft?
    @State private var fields = VoiceTaskFields()
    @State private var soundOverride: AlarmSound?
    @State private var calendarEnabled = false
    @State private var interpreting = false
    @State private var interpretationVersion = 0
    @State private var attemptedAutoStart = false
    @State private var errorMessage: String?
    private let logger = Logger(subsystem: "com.pavlovilya.nudge", category: "VoiceTiming")

    init(store: ReminderStore, interpreter: any ReminderInterpreter = RuleBasedInterpreter(), onOpenTask: @escaping (UUID) -> Void) {
        self.store = store
        self.interpreter = interpreter
        self.onOpenTask = onOpenTask
    }

    var body: some View {
        NavigationStack {
            Form {
                if let id = creation.createdID { savedContent(id) }
                else {
                    requestEditor
                    if speech.isBusy { recordingContent }
                    else { reviewContent }
                    if let error = speech.errorMessage { Text(error).foregroundStyle(.orange) }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
                }
            }
            .disabled(creation.isSaving)
            .navigationTitle("Voice reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(creation.isSaving) } }
            .interactiveDismissDisabled(creation.isSaving || store.isBusy)
            .task {
                let calendar = CalendarService.live
                calendarEnabled = calendarDefault && calendar.hasAccess() && calendar.destinations().contains { $0.id == calendarID }
                await speech.prepare()
                autoStartIfAllowed()
            }
            // The ID stays nil for every partial result. Only settled speech or a
            // manual edit schedules interpretation; .task cancels the old debounce.
            .task(id: interpretationText) {
                guard let source = interpretationText else { return }
                await interpret(source: source)
            }
            .onChange(of: speech.text) { _, value in
                if let voiceSession { input.update(value, session: voiceSession) }
            }
            .onChange(of: speech.isBusy) { _, busy in
                if busy {
                    interpretationVersion += 1
                    interpreting = false
                    errorMessage = nil
                } else { finishDictation() }
            }
            .onChange(of: transcript) { _, value in
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    interpretationVersion += 1
                    interpreting = false
                    proposal = nil
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { autoStartIfAllowed() }
                else if phase == .background || speech.phase == .recording || speech.phase == .finalizing { speech.interrupt() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { _ in speech.interrupt() }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { notification in
                let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                if speech.phase == .recording, SpeechCallbacks.shouldInterruptRecording(for: reason) { speech.interrupt() }
            }
            .sheet(isPresented: $showingSettings, onDismiss: { Task { await speech.prepare() } }) { SoundSettingsView() }
            .confirmationDialog("Clear the full request?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear text", role: .destructive) {
                    speech.cancel(clearText: true); voiceSession = nil; input.edit("")
                    fields = VoiceTaskFields(); proposal = nil
                }
                Button("Cancel", role: .cancel) {}
            }
            .onDisappear { speech.cancel(clearText: true); voiceSession = nil; interpretationVersion += 1 }
        }
    }

    private var recordingContent: some View {
        Section {
            if speech.phase == .recording {
                Label("Recording", systemImage: "mic.fill").foregroundStyle(.red).symbolEffect(.pulse)
            } else {
                ProgressView(speech.phase == .preparing ? String(localized: "Getting ready…") : String(localized: "Finishing recording…"))
            }
            if speech.phase == .recording {
                Button { speech.stop() } label: {
                    Label("Stop recording", systemImage: "stop.circle.fill").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }

    @ViewBuilder private var reviewContent: some View {
        if interpreting { ProgressView("Processing…") }
        if let proposal {
            Section {
                TextField("Task title", text: Binding(get: { fields.title }, set: { fields.editTitle($0) }), axis: .vertical).font(.headline)
                TaskScheduleFields(date: Binding(get: { fields.date }, set: { fields.editDate($0) }), alarmEnabled: Binding(get: { fields.alarmEnabled }, set: { fields.editAlarm($0) }))
                RecurrencePicker(rule: Binding(get: { fields.recurrence }, set: { fields.editRecurrence($0) }), date: Binding(get: { fields.date }, set: { fields.editDate($0) }))
                if proposal.warnings.contains(.unsupportedRecurrence) {
                    Text("Choose repetition manually; the current parser does not infer repeat rules.").font(.footnote).foregroundStyle(.orange)
                } else if proposal.warnings.contains(.ambiguous) {
                    Text("Check the title and time.").font(.footnote).foregroundStyle(.orange)
                }
            }
            .disabled(interpreting)
            Section {
                Button { Task { await create() } } label: {
                    HStack {
                        if creation.isSaving { ProgressView() }
                        Text("Create").font(.headline)
                    }.frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!ReminderDraft(sourceText: transcript, title: fields.title, date: fields.date, warnings: [], alarmEnabled: fields.alarmEnabled, recurrence: fields.recurrence).canCreate(now: .now, alarmEnabled: fields.alarmEnabled) || interpreting || creation.isSaving || store.isBusy || !proposal.isCurrent(for: transcript))

            }
            Section {
                DisclosureGroup {
                    Picker("Reminder sound", selection: $soundOverride) {
                        Text("Use default (\(defaultSound.title))").tag(AlarmSound?.none)
                        ForEach(AlarmSound.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    CalendarTaskToggle(enabled: $calendarEnabled, hasExistingLink: false, compact: true)
                    if (soundOverride ?? defaultSound) == .experimentalVibrationOnly {
                        Text(AlarmSound.experimentalWarning).font(.footnote).foregroundStyle(.secondary)
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text("Sound and Calendar")
                        Text((soundOverride ?? defaultSound).title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var transcript: String { input.text }

    private var requestEditor: some View {
        Section {
            TextField("Full request", text: Binding(get: { input.text }, set: { input.edit($0); voiceSession = nil }), axis: .vertical)
                .lineLimit(3...12).disabled(speech.isBusy).accessibilityLabel("Transcript")
            HStack {
                Button { Task { await startRecording() } } label: { Label("Continue dictation", systemImage: "mic") }
                    .disabled(speech.isBusy || !speech.canRecord)
                Spacer()
                Button { confirmingClear = true } label: { Label("Clear text", systemImage: "trash") }
                    .disabled(speech.isBusy || input.text.isEmpty)
            }.buttonStyle(.borderless)
            if !speech.canRecord {
                Button("Open recognition settings", systemImage: "gearshape") { showingSettings = true }
            }
        }
    }

    private func finishDictation() {
        guard let voiceSession else { return }
        input.update(speech.text, session: voiceSession)
        input.finish(session: voiceSession)
        self.voiceSession = nil
    }

    private func savedContent(_ id: UUID) -> some View {
        Section {
            Label("Task saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if let task = try? store.reminder(id: id) {
                Text(task.title).font(.headline)
                if let date = task.scheduledAt { Text(date, format: .dateTime.month().day().hour().minute()) }
                if let error = task.calendarError { Text(error).foregroundStyle(.orange) }
            }
            if let error = store.errorMessage { Text(error).foregroundStyle(.orange) }
            Button("Open task") { onOpenTask(id) }
            Button("Close") { dismiss() }
        }
    }

    static func interpretationSource(text: String, isCapturing: Bool, hasCreatedTask: Bool) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isCapturing || hasCreatedTask || text.isEmpty ? nil : text
    }

    private var interpretationText: String? {
        Self.interpretationSource(text: transcript, isCapturing: speech.isBusy, hasCreatedTask: creation.createdID != nil)
    }

    private func startRecording() async {
        guard !speech.isBusy, !creation.isSaving, speech.canRecord else { return }
        voiceSession = input.begin()
        await speech.start()
        if !speech.isBusy { finishDictation() }
    }

    private func autoStartIfAllowed() {
        guard !attemptedAutoStart, scenePhase == .active, speech.canRecord else { return }
        attemptedAutoStart = true
        if speech.permissionsGranted { Task { await startRecording() } }
    }

    private func interpret(source: String) async {
        // Availability checks must not overwrite manual title/date edits for the same phrase.
        guard proposal?.isCurrent(for: source) != true else { return }
        interpretationVersion += 1
        let version = interpretationVersion
        guard !speech.isBusy, creation.createdID == nil, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            interpreting = false
            if transcript.isEmpty { proposal = nil }
            return
        }
        interpreting = true
        defer { if version == interpretationVersion { interpreting = false } }
        do {
            try await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let context = InterpretationContext(now: .now, calendar: calendar, timeZone: .current, locale: Locale(identifier: "ru_RU"),
                defaultSoundID: defaultSound.rawValue, calendarEnabled: calendarEnabled, calendarID: calendarID)
            let start = ContinuousClock.now
            let draft = try await interpreter.interpret(text: source, context: context)
            guard !Task.isCancelled, version == interpretationVersion, source == transcript.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            proposal = draft
            fields.apply(draft)
            errorMessage = nil
            let elapsed = start.duration(to: .now).components
            logger.info("interpretation_ms=\(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15, privacy: .public)")
        } catch is CancellationError { }
        catch { errorMessage = String(localized: "Could not interpret the phrase. Edit the text or enter the title and time manually.") }
    }

    private func create() async {
        guard proposal?.isCurrent(for: transcript) == true, !interpreting, !speech.isBusy else { return }
        speech.cancel()
        let draft = ReminderDraft(sourceText: transcript, title: fields.title, date: fields.date, warnings: proposal?.warnings ?? [], alarmEnabled: fields.alarmEnabled, recurrence: fields.recurrence)
        let sound = soundOverride ?? defaultSound
        let enabled = calendarEnabled
        let destination = calendarID.isEmpty ? nil : calendarID
        do {
            let start = ContinuousClock.now
            let id = try await creation.confirm(draft: draft, now: .now, alarmEnabled: fields.alarmEnabled) { title, date in
                if await store.create(title: title, date: date, sound: sound, calendarEnabled: enabled, calendarID: destination, alarmEnabled: fields.alarmEnabled, recurrence: fields.recurrence) {
                    return store.lastCreatedID
                }
                return nil
            }
            if id != nil { speech.cancel(clearText: true); voiceSession = nil; input.edit(""); proposal = nil }
            let elapsed = start.duration(to: .now).components
            logger.info("creation_ms=\(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15, privacy: .public)")
        } catch { errorMessage = String(localized: "Check the task title and choose a future date and time.") }
    }
}
