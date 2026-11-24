import AVFoundation
import OSLog
import SwiftUI

struct VoiceCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let store: ReminderStore
    let onOpenTask: (UUID) -> Void
    private let interpreter: any ReminderInterpreter
    @AppStorage(AlarmSound.preferenceKey) private var defaultSound: AlarmSound = .systemDefault
    @AppStorage(CalendarService.defaultKey) private var calendarDefault = false
    @AppStorage(CalendarService.destinationKey) private var calendarID = ""
    @AppStorage("experimentalSoundAcknowledged") private var experimentalAcknowledged = false
    @State private var speech = SpeechTranscriptionService()
    @State private var creation = VoiceCreation()
    @State private var transcript = ""
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
                if let id = creation.createdID {
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
                } else {
                    Section {
                        Text("Speak one reminder in Russian, then check it before creating.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if speech.phase == .recording {
                            Label("Recording", systemImage: "mic.fill")
                                .foregroundStyle(.red).symbolEffect(.pulse)
                            Button("Stop recording", systemImage: "stop.circle.fill") { speech.stop() }
                                .frame(minHeight: 44)
                            Button("Cancel recording", role: .cancel) { speech.cancel(clearText: true) }
                        } else if speech.isBusy || interpreting {
                            ProgressView(speech.phase == .preparing ? String(localized: "Preparing offline recognition…") : String(localized: "Processing…"))
                        } else {
                            Button("Record reminder", systemImage: "mic.circle.fill") { Task { await speech.start() } }
                                .font(.title3).frame(minHeight: 56).disabled(!speech.canRecord)
                        }
                        if let error = speech.errorMessage { Text(error).foregroundStyle(.orange) }
                    }
                    Section("Transcript") {
                        TextEditor(text: $transcript).frame(minHeight: 88)
                            .accessibilityLabel("Transcript")
                            .disabled(speech.isBusy || creation.isSaving)
                        Text("You can type or correct the phrase. Interpretation updates after editing.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let proposal {
                        Section("Check the reminder") {
                            if proposal.warnings.contains(.unsupportedRecurrence) {
                                Text("Repeating commands are not supported. Only a one-time reminder can be created here.").foregroundStyle(.orange)
                            } else if !proposal.warnings.isEmpty {
                                Text("Interpretation is incomplete or ambiguous. Check the title and choose the correct date and time.").foregroundStyle(.orange)
                            }
                            TextField("Task title", text: $title, axis: .vertical)
                            Toggle("Set date and time", isOn: $hasDate)
                            if hasDate { DatePicker("When", selection: $date, displayedComponents: [.date, .hourAndMinute]) }
                            Picker("Reminder sound", selection: $soundOverride) {
                                Text("Use default (\(defaultSound.title))").tag(AlarmSound?.none)
                                ForEach(AlarmSound.allCases) { Text($0.title).tag(Optional($0)) }
                            }
                        }.disabled(speech.isBusy || interpreting)
                        if (soundOverride ?? defaultSound) == .experimentalVibrationOnly && !experimentalAcknowledged {
                            Section {
                                Text(AlarmSound.experimentalWarning).font(.footnote).foregroundStyle(.orange)
                                Button("Got it") { experimentalAcknowledged = true }
                            }
                        }
                        CalendarTaskToggle(enabled: $calendarEnabled, hasExistingLink: false)
                            .disabled(speech.isBusy || creation.isSaving)
                        Button("Create") { Task { await create() } }
                            .frame(minHeight: 44)
                            .disabled(!hasDate || date <= .now || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || speech.isBusy || interpreting || creation.isSaving || store.isBusy || !proposal.isCurrent(for: transcript))
                        Button("Record again") { Task { await speech.start() } }
                            .disabled(speech.isBusy || creation.isSaving || !speech.canRecord)
                    }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
                    DisclosureGroup("Offline Russian recognition") {
                        Text("Audio stays on this device. Raw recordings are not saved.").font(.footnote)
                        if !speech.backendName.isEmpty { Text(speech.backendName).font(.caption) }
                        if speech.canInstall {
                            Button("Install system language resources") { Task { await speech.installResources() } }
                                .disabled(speech.isBusy)
                            Text("Only Apple's system speech resources are downloaded. Voice and transcript are not uploaded.").font(.footnote)
                        }
                        Button("Check availability again") { Task { await speech.prepare() } }.disabled(speech.isBusy)
                    }
                }
            }
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
            .task(id: speech.isBusy ? nil : transcript) { await interpret() }
            .onChange(of: speech.text) { _, value in transcript = value }
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

    private func autoStartIfAllowed() {
        guard !attemptedAutoStart, scenePhase == .active, speech.canRecord else { return }
        attemptedAutoStart = true
        if speech.permissionsGranted { Task { await speech.start() } }
    }

    private func interpret() async {
        interpretationVersion += 1
        let version = interpretationVersion
        guard !speech.isBusy, creation.createdID == nil, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            interpreting = false
            if transcript.isEmpty { proposal = nil }
            return
        }
        let source = transcript
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
            guard !Task.isCancelled, version == interpretationVersion, source == transcript else { return }
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
