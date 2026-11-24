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
    @AppStorage("experimentalSoundAcknowledged") private var experimentalAcknowledged = false
    @State private var speech = SpeechTranscriptionService()
    @State private var creation = VoiceCreation()
    @State private var transcript = ""
    @State private var editingTranscript = false
    @State private var proposal: ReminderDraft?
    @State private var title = ""
    @State private var date = Date.now.addingTimeInterval(300)
    @State private var hasDate = false
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
                    if speech.isBusy { recordingContent }
                    else {
                        reviewContent
                        recognitionSettings
                    }
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
            .onChange(of: speech.text) { _, value in transcript = value }
            .onChange(of: speech.isBusy) { _, busy in
                if busy {
                    interpretationVersion += 1
                    interpreting = false
                    editingTranscript = false
                    errorMessage = nil
                }
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
            .onDisappear { speech.cancel(clearText: true); interpretationVersion += 1; transcript = ""; proposal = nil; title = "" }
        }
    }

    private var recordingContent: some View {
        Section {
            if speech.phase == .recording {
                Label("Recording", systemImage: "mic.fill").foregroundStyle(.red).symbolEffect(.pulse)
            } else {
                ProgressView(speech.phase == .preparing ? String(localized: "Getting ready…") : String(localized: "Finishing recording…"))
            }
            Text(speech.text.isEmpty ? String(localized: "Speak your reminder") : speech.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if speech.phase == .recording {
                Button { speech.stop() } label: {
                    Label("Stop recording", systemImage: "stop.circle.fill").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }

    @ViewBuilder private var reviewContent: some View {
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Section {
                Text("Speak your reminder").foregroundStyle(.secondary)
                Button { Task { await speech.start() } } label: {
                    Label("Record reminder", systemImage: "mic.fill").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!speech.canRecord)
                Button("Type a reminder") { editingTranscript = true }
            }
        }
        if !transcript.isEmpty || editingTranscript {
            Section {
                DisclosureGroup("Edit phrase", isExpanded: $editingTranscript) {
                    TextEditor(text: $transcript).frame(minHeight: 100).accessibilityLabel("Transcript")
                }
            }
        }
        if interpreting { ProgressView("Processing…") }
        if let proposal {
            Section("Check the reminder") {
                TextField("Task title", text: $title, axis: .vertical).font(.headline)
                if !hasDate { Text("Choose when to remind you.").foregroundStyle(.secondary) }
                DatePicker("When", selection: Binding(get: { date }, set: { date = $0; hasDate = true }), displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                if proposal.warnings.contains(.unsupportedRecurrence) {
                    Text("Repeating commands are not supported. Only a one-time reminder can be created here.").font(.footnote).foregroundStyle(.orange)
                } else if proposal.warnings.contains(.ambiguous) {
                    Text("Check the title and time.").font(.footnote).foregroundStyle(.orange)
                }
                if hasDate, date <= .now { Text("Choose a date and time in the future.").foregroundStyle(.orange) }
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
                .disabled(!hasDate || date <= .now || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || interpreting || creation.isSaving || store.isBusy || !proposal.isCurrent(for: transcript))
                Button("Record again") { Task { await speech.start() } }.disabled(!speech.canRecord)
                if (soundOverride ?? defaultSound) == .experimentalVibrationOnly && !experimentalAcknowledged {
                    Text("Experimental silent signal: silence and vibration are not guaranteed.").font(.footnote).foregroundStyle(.secondary)
                    Button("Got it") { experimentalAcknowledged = true }
                }
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

    private var recognitionSettings: some View {
        Section {
            DisclosureGroup("Recognition settings") {
                Text("Audio stays on this device. Raw recordings are not saved.").font(.footnote)
                if !speech.backendName.isEmpty { Text(speech.backendName).font(.caption) }
                if speech.canInstall {
                    Button("Install system language resources") { Task { await speech.installResources() } }
                    Text("Only Apple's system speech resources are downloaded. Voice and transcript are not uploaded.").font(.footnote)
                }
                Button("Check availability again") { Task { await speech.prepare() } }
            }
        }
    }

    private func savedContent(_ id: UUID) -> some View {
        Section {
            Label("Task saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if let task = try? store.reminder(id: id) {
                Text(task.title).font(.headline)
                Text(task.scheduledAt, format: .dateTime.month().day().hour().minute())
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

    private func autoStartIfAllowed() {
        guard !attemptedAutoStart, scenePhase == .active, speech.canRecord else { return }
        attemptedAutoStart = true
        if speech.permissionsGranted { Task { await speech.start() } }
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
            proposal = draft; title = draft.title; hasDate = draft.date != nil
            date = draft.date ?? context.now.addingTimeInterval(300)
            errorMessage = nil
            let elapsed = start.duration(to: .now).components
            logger.info("interpretation_ms=\(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15, privacy: .public)")
        } catch is CancellationError { }
        catch { errorMessage = String(localized: "Could not interpret the phrase. Edit the text or enter the title and time manually.") }
    }

    private func create() async {
        guard proposal?.isCurrent(for: transcript) == true, !interpreting, !speech.isBusy else { return }
        speech.cancel()
        let draft = ReminderDraft(sourceText: transcript, title: title, date: hasDate ? date : nil, warnings: proposal?.warnings ?? [])
        let sound = soundOverride ?? defaultSound
        let enabled = calendarEnabled
        let destination = calendarID.isEmpty ? nil : calendarID
        do {
            let start = ContinuousClock.now
            let id = try await creation.confirm(draft: draft, now: .now) { title, date in
                if await store.create(title: title, date: date, sound: sound, calendarEnabled: enabled, calendarID: destination) {
                    return store.lastCreatedID
                }
                return nil
            }
            if id != nil { speech.cancel(clearText: true); transcript = ""; proposal = nil }
            let elapsed = start.duration(to: .now).components
            logger.info("creation_ms=\(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15, privacy: .public)")
        } catch { errorMessage = String(localized: "Check the task title and choose a future date and time.") }
    }
}
