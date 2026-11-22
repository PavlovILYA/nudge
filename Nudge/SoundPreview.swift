import AVFoundation
import Observation
import OSLog

/// Foreground audition only; no AlarmKit scheduling and no background audio mode.
@MainActor @Observable
final class SoundPreview {
    private var player: AVAudioPlayer?
    var errorMessage: String?

    func play(_ sound: AlarmSound) {
        stop()
        errorMessage = nil
        guard sound.canPreview else { return }
        do {
            guard let url = sound.resourceURL() else { throw PreviewError.unavailable }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            self.player = player
            guard player.prepareToPlay(), player.play() else { throw PreviewError.unavailable }
        } catch {
            stop()
            Logger(subsystem: "com.pavlovilya.nudge", category: "SoundPreview")
                .error("Preview failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = String(localized: "Could not preview the sound. Try again.")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private enum PreviewError: Error { case unavailable }
}
