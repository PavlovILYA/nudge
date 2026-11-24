import Foundation
import Observation
import UIKit

enum AppRoute: Equatable {
    case voice, reminder(UUID)
    static let voiceURL = URL(string: "nudge://voice")!
    init?(url: URL) {
        if url.scheme?.lowercased() == "nudge", url.host?.lowercased() == "voice",
           url.path.isEmpty || url.path == "/", url.user == nil, url.password == nil,
           url.port == nil, url.query == nil, url.fragment == nil { self = .voice }
        else if let id = ReminderLink.id(from: url) { self = .reminder(id) }
        else { return nil }
    }
}

@MainActor @Observable
final class AppLaunchRequest {
    static let shared = AppLaunchRequest()
    static let shortcutType = "com.pavlovilya.nudge.voice"
    var url: URL?
}

/// UIKit only supplies the Quick Action bridge; SwiftUI still owns the window and UI.
@MainActor
final class NudgeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if options.shortcutItem?.type == AppLaunchRequest.shortcutType { AppLaunchRequest.shared.url = AppRoute.voiceURL }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowApplication { configuration.delegateClass = QuickActionSceneDelegate.self }
        return configuration
    }
}

@MainActor
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard shortcutItem.type == AppLaunchRequest.shortcutType else { completionHandler(false); return }
        AppLaunchRequest.shared.url = AppRoute.voiceURL
        completionHandler(true)
    }
}
