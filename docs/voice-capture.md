# 0.5.0 design and API evidence

Keep SwiftData unchanged. Audio capture, offline transcription, semantic interpretation, validation and confirmed creation are separate. Use a single Sendable ReminderInterpreter protocol and RuleBasedInterpreter returning a value-only ReminderDraft. The context supplies a fixed now, Calendar/TimeZone/Locale and the current minimal sound/Calendar defaults. No interpreter can access persistence or system scheduling. Future LocalLLMInterpreter replaces only this boundary; no LLM code, dependencies, weights or network transcription now.

Prefer SpeechAnalyzer + SpeechTranscriber when the device supports Russian and required system assets are installed. DictationTranscriber is the documented older-device/on-device alternative, followed by ru-RU SFSpeechRecognizer only with supportsOnDeviceRecognition AND requiresOnDeviceRecognition. Runtime checks are necessary: a supported locale list is not proof of installed/available Russian on iPhone 13. System asset installation is a separate explicit UI action; Apple manages those resources. Cloud recognition is never a fallback. Modern analyzers do not require SFSpeech authorization; the legacy path does, in addition to microphone permission.

Microphone capture uses AVAudioEngine/AVAudioSession, a bounded in-memory stream of copied buffers, no raw files or background modes. Stop ends input and finalizes; cancel/background/interruption tears down tap/engine/session/tasks. A capture generation rejects late callbacks. The voice screen attempts auto-start only once, only when active and required permissions are already granted; first-time users press the large button for contextual permissions. Processing/capture have bounded timeouts. No permanent audio/transcript storage or phrase logging.

Rules support today/tomorrow/day-after, minute/hour offsets, weekday, numeric day + Russian month, 24-hour numeric time and common spoken hours with day parts. Normalize spacing/punctuation/introductions without converting task numbers or proper names indiscriminately. Missing, invalid, past, repeated or conflicting times require explicit correction. Calendar constructs dates in the supplied zone and validates round trips/DST; no default time is silently invented. Interpretation is not general natural-language understanding or recurring-task support.

Use the existing ReminderStore.create and expose its last durable created UUID so the confirmation can open the exact task. A per-screen creation guard remains closed after success, including partial alarm/calendar failures. No second scheduling path. Keep the original transcript editable in memory; explicit reinterpretation replaces the proposal, while title/date can be edited directly.

Home/systemSmall and Lock/accessoryCircular widgets contain only nudge://voice links. A single static WidgetKit extension, no App Groups/entitlements/database/microphone. A minimal UIKit app/scene delegate bridge handles both cold and warm Home Screen Quick Actions and feeds the same voice route. Existing reminder UUID links and AlarmKit intents remain. Incoming requests while a form is open require an explicit discard decision; staying keeps the current form intact. No stacked capture sheets, background widget microphone or lock-screen overlay.

Research / exact SDK evidence:
- https://developer.apple.com/documentation/speech
- https://developer.apple.com/documentation/speech/speechtranscriber (hardware availability, supported/installed locale checks)
- https://developer.apple.com/documentation/speech/dictationtranscriber (system dictation models; excludes network-only locales)
- https://developer.apple.com/documentation/speech/speechanalyzer/setmodules(_:) (modules cannot be reused by different analyzers; construct a fresh module per capture)
- https://developer.apple.com/documentation/speech/assetinventory (status, installation requests, reservations)
- https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition (SFSpeech authorization versus on-device analyzer)
- https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition
- https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition
- https://developer.apple.com/documentation/avfaudio/avaudioengine
- https://developer.apple.com/documentation/widgetkit/linking-to-specific-app-scenes-from-your-widget-or-live-activity
- https://developer.apple.com/documentation/uikit/add-home-screen-quick-actions

The installed Xcode 27.2 SDK exports SpeechAnalyzer, SpeechTranscriber, DictationTranscriber and AssetInventory at iOS 26. SpeechAnalyzer is an actor, module results are Sendable async sequences, installed/supported locales and asset status are asynchronous. AnalyzerInputConverter is iOS 27-only; use the standard AVAudioConverter for the iOS 26-compatible streaming path. Audio input retains copied PCM ownership rather than leaking tap-owned mutable buffers into tasks.

Quick Actions and widgets foreground the app, subject to standard unlock/microphone restrictions. Calendar's event links remain unchanged. Extension version/build and embedded .appex identity are checked in CI. Sideloadly must sign the app and embedded widget with compatible identities; unsigned CI does not prove installation/widgets with a free Apple ID.

Implementation: deterministic interpreter tests and local Foundation-only checks; transcription/voice UI; routing/Quick Action/widget target; privacy/localization; CI builds/tests via workflow_dispatch before opening PR; independent review, documentation and final PR. Per user preference, do not wait/poll CI after opening the PR. No merge or claims of physical recognition/installation acceptance.
