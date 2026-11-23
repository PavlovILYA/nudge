# 0.3.0 sound and snooze design / research

## Plan

1. Branch from merged PR #3; retain existing AlarmService/ReminderStore and durable snooze ordering.
2. Add tests for stable sound identifiers, safe defaults, snapshotting individual choices, UserDefaults persistence, CAF resources/mapping, snooze/failure preservation and a frozen 0.2.0 disk store. Run feature tests in CI before implementation.
3. Add four enum cases and an optional persisted raw identifier (nil/unknown => systemDefault). Resolve the global default at creation, so later settings changes affect only new tasks. Existing tasks remain systemDefault; no silent re-registration on upgrade.
4. Synthesize two original short mono PCM CAF tones and a zero-sample CAF. Pass their exact filenames including .caf to ActivityKit AlertSound.named. Preview audible custom files with a retained AVAudioPlayer, stopping on background/dismiss. No background audio mode.
5. Add Settings, a per-creation override, English/Russian UI and localized app errors. Keep experimental warnings visible, including when experiment is the global default.
6. Compact snooze into an adaptive native button grid; use one column at accessibility Dynamic Type sizes. Reveal DatePicker only when requested. Preserve one-tap scheduling, next-time preview and busy guard.
7. CI Release builds, tests, CAF verification, SDK declarations, unsigned device IPA; independent review and device checklist. Never merge.

## Apple evidence and limits

- [AlarmKit](https://developer.apple.com/documentation/alarmkit), [AlarmConfiguration](https://developer.apple.com/documentation/alarmkit/alarmmanager/alarmconfiguration), [WWDC25 session 230](https://developer.apple.com/videos/play/wwdc2025/230/): AlarmConfiguration accepts ActivityKit AlertConfiguration.AlertSound. The default is a system sound; custom files reside in the main bundle or Library/Sounds. Alarms break through Silent Mode and Focus; those switches are not a mute API for Nudge.
- [AlertSound.named](https://developer.apple.com/documentation/activitykit/alertconfiguration/alertsound/named(_:)): takes a filename. [Developer Forums 836432](https://developer.apple.com/forums/thread/836432): the original poster reports that `lifeloop_alarm_silent.caf`, including its extension, worked on iOS 26.5 whereas the extensionless name fell back to the system sound. This is a developer report, not an Apple guarantee of iOS 27 behavior or vibration.
- [Sound resource guidance](https://developer.apple.com/documentation/usernotifications/unnotificationsound): system sound resources support linear PCM, IMA4, uLaw, aLaw in CAF/WAV/AIFF, shorter than 30 seconds. This is adjacent system-sound documentation, not a separate guarantee of AlarmKit playback. Use conservative 44.1 kHz, mono signed 16-bit PCM CAF, 1.5–2.4 seconds, and validate with afinfo/AVAudioFile. No UserNotifications replacement is implemented.
- [Core Haptics lifecycle](https://developer.apple.com/documentation/corehaptics/preparing-your-app-to-play-haptics): the engine can stop when the app is suspended/backgrounded. It cannot supply guaranteed vibration for a system-owned alarm while Nudge is closed.
- [System Sound Services](https://developer.apple.com/documentation/audiotoolbox/audio-services) and [AudioServicesPlaySystemSound](https://developer.apple.com/documentation/audiotoolbox/audioservicesplaysystemsound(_:)): local short sound/vibration calls are not a persistent AlarmKit haptic configuration. Do not schedule them as a substitute for AlarmKit.

The inspected AlarmKit SDK exposes a sound parameter but no mute, vibration pattern or haptic-enable parameter. Refresh CI SDK exports for AlarmKit, ActivityKit and related frameworks. No clock-app tone identifiers, entitlements, security bypasses or background audio services are added.

The experimental case supplies an actual silent CAF. Its zero PCM samples establish only file silence. They do not establish system playback, absence of fallback audio, vibration or delivery. Always show that sound may play and vibration is not guaranteed. Keep systemDefault as the initial technical default. A user may opt into the experiment as the persistent default for new reminders.

Diagnostics log the actual scheduling ID, mode raw value, complete `.named` filename or `.default`, and scheduled instant through OSLog (no task title). The picker also shows the selected system parameter for device-test comparison. These describe requested configuration, never observed output. Preview is foreground-only and is not AlarmKit evidence.

Settings apply only at creation; no existing-alarm sound editor is added. Snooze uses the saved task choice and the existing stable ID/journal. Therefore date-based interrupted-operation reconciliation remains sound without adding a sound-change transaction or extra pending fields.
