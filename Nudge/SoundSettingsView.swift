import SwiftUI

struct SoundSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AlarmSound.preferenceKey) private var defaultSound: AlarmSound = .systemDefault

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
    @AppStorage("experimentalSoundAcknowledged") private var acknowledged = false
    @State private var preview = SoundPreview()

    var body: some View {
        Section {
            if sound == .experimentalVibrationOnly && (alwaysWarn || !acknowledged) {
                Label(AlarmSound.experimentalWarning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                if !acknowledged { Button("Got it") { acknowledged = true } }
            }
            if sound.canPreview {
                Button("Preview", systemImage: "play.circle") { preview.play(sound) }
                    .frame(minHeight: 44)
            }
            if let error = preview.errorMessage { Text(error).foregroundStyle(.red) }
        } footer: {
            if sound.canPreview {
                Text("Preview plays only here, respects Silent Mode and volume, and does not test AlarmKit playback.")
            }
        }
        .onChange(of: sound) { _, _ in preview.stop(); preview.errorMessage = nil }
        .onChange(of: scenePhase) { _, phase in if phase != .active { preview.stop() } }
        .onDisappear { preview.stop() }
    }
}
