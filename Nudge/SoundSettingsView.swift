import SwiftUI

struct SoundSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AlarmSound.preferenceKey) private var defaultSound: AlarmSound = AlarmSound.newReminderDefault

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Default sound", selection: $defaultSound) {
                        ForEach(AlarmSound.allCases) { sound in
                            Text(sound.title).tag(sound)
                        }
                    }
                    .pickerStyle(.inline)
                } footer: {
                    Text("Applies only to new reminders. Existing reminders keep their saved sound.")
                }
                SoundDetails(sound: defaultSound, alwaysWarn: true)
                CalendarSettingsSection()
                DictationResourcesSection()
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

/// Shared by Settings and reminder creation; it never schedules a system alarm.
struct SoundDetails: View {
    @Environment(\.scenePhase) private var scenePhase
    let sound: AlarmSound
    var alwaysWarn = false
    var compact = false
    @AppStorage("experimentalSoundAcknowledged") private var acknowledged = false
    @State private var preview = SoundPreview()

    var body: some View {
        Group {
            if compact { fields }
            else {
                Section { fields } footer: {
                    if sound.canPreview {
                        Text("Preview plays only here, respects Silent Mode and volume, and does not test AlarmKit playback.")
                    }
                }
            }
        }
        .onChange(of: sound) { _, _ in preview.stop(); preview.errorMessage = nil }
        .onChange(of: scenePhase) { _, phase in if phase != .active { preview.stop() } }
        .onDisappear { preview.stop() }
    }

    @ViewBuilder private var fields: some View {
        if sound == .experimentalVibrationOnly && (compact || alwaysWarn || !acknowledged) {
            Text(AlarmSound.experimentalWarning).font(.footnote).foregroundStyle(.secondary)
            if !compact && !acknowledged { Button("Got it") { acknowledged = true } }
        }
        if sound.canPreview {
            Button("Preview", systemImage: "play.circle") { preview.play(sound) }.frame(minHeight: 44)
        }
        if let error = preview.errorMessage { Text(error).foregroundStyle(.red) }
    }
}


struct DictationResourcesSection: View {
    @State private var speech = SpeechTranscriptionService()
    private var working: Bool { speech.resourceStatus == .checking || speech.resourceStatus == .installing }
    private var status: String {
        switch speech.resourceStatus {
        case .checking: String(localized: "Checking Apple dictation…")
        case .available: String(localized: "Russian dictation resources are installed")
        case .notInstalled: String(localized: "Apple dictation resources are not installed")
        case .installing: String(localized: "Installing Apple dictation resources…")
        case .unavailable: String(localized: "Russian dictation is unavailable on this device")
        case .failed: String(localized: "Dictation resource installation failed")
        }
    }
    var body: some View {
        Section("Recognition settings") {
            Text(status).font(.subheadline)
            if working { ProgressView() }
            if let error = speech.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
            if speech.canInstall {
                Button("Install system language resources") { Task { await speech.installResources() } }.disabled(working)
            }
            Button("Check availability again") { Task { await speech.prepare() } }.disabled(working)
            Text("These are Apple's speech recognition resources, not an LLM. Audio stays on this device.").font(.footnote).foregroundStyle(.secondary)
        }
        .task { await speech.prepare() }
    }
}
