import ActivityKit
import Foundation

/// Persist identifiers, never translated display names. Existing tasks default safely.
enum AlarmSound: String, CaseIterable, Identifiable, Sendable {
    case systemDefault, soft, prominent, experimentalVibrationOnly

    static let preferenceKey = "defaultAlarmSound"
    static let newReminderDefault: AlarmSound = .experimentalVibrationOnly

    /// Reading a fallback never writes over an explicit saved preference.
    static func preferred(in defaults: UserDefaults = .standard) -> AlarmSound {
        defaults.string(forKey: preferenceKey).flatMap(AlarmSound.init(rawValue:)) ?? newReminderDefault
    }
    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemDefault: String(localized: "System melody")
        case .soft: String(localized: "Soft tone")
        case .prominent: String(localized: "Prominent tone")
        case .experimentalVibrationOnly: String(localized: "Vibration only (experimental)")
        }
    }

    var filename: String? {
        switch self {
        case .systemDefault: nil
        case .soft: "nudge-soft.caf"
        case .prominent: "nudge-prominent.caf"
        case .experimentalVibrationOnly: "nudge-silent.caf"
        }
    }

    var alertSound: AlertConfiguration.AlertSound {
        if let filename { .named(filename) } else { .default }
    }

    var diagnostic: String {
        if let filename { ".named(\"\(filename)\")" } else { ".default" }
    }

    var canPreview: Bool { self == .soft || self == .prominent }

    func resourceURL(in bundle: Bundle = .main) -> URL? {
        guard let filename else { return nil }
        return bundle.url(forResource: filename, withExtension: nil)
    }

    static var experimentalWarning: String {
        String(localized: "Silent CAF worked with vibration on a tested iPhone 13. Other devices and settings may differ; silence and vibration are not guaranteed.")
    }
}
