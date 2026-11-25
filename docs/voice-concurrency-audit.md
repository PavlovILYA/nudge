> Исторический документ. Правила Stop, опциональной даты и главного экрана заменены текущей моделью: [Task-first QA](task-first-qa.md).

# Voice callback isolation — 0.5.0 (6)

## Evidence and fix

The user supplied matching stack excerpts from `Nudge-2026-11-24-135438.ips`
and `Nudge-2026-11-24-135439.ips` (iPhone 13, iOS 27.2.1): SIGTRAP in
`dispatch_assert_queue`, Swift executor checking, then the authorization closure
inside `SpeechTranscriptionService.start()`. The complete reports were not attached.

The service is MainActor-isolated. The old Objective-C authorization callback was
created inside that context without a Sendable annotation. Swift 6 could infer actor
isolation for the closure, but Speech called it on a default-QoS queue. The runtime
check failed before its body could resume the continuation.

`SpeechCallbacks.authorization` is now explicitly nonisolated, with a Sendable
callback that only resumes a checked continuation. The caller resumes on its own
actor after `await`. No unsafe isolation assertions, unchecked Sendable conformances,
preconcurrency imports, or disabled Swift concurrency checks were added.

Sources: Apple's [authorization documentation](https://developer.apple.com/documentation/speech/sfspeechrecognizer/requestauthorization(_:))
explicitly disclaims main-queue delivery; the recognizer's [queue property](https://developer.apple.com/documentation/speech/sfspeechrecognizer/queue)
does not apply to authorization callbacks. SDK declarations are archived by CI in
`Apple-SDK-Reference`; local callback probes also compile in Swift 6 mode.

## Targeted audit

| Boundary | Handling |
| --- | --- |
| Speech authorization | Nonisolated async bridge; Sendable callback resumes continuation only. Background, denial, synchronous and repeated authorized replies tested without system prompts. |
| Legacy recognition handler | Created in a nonisolated factory; snapshots text/final/error domain+code on the callback queue. Only a Sendable value reaches a separate MainActor Task. Generation rejects late callbacks. An inner MainActor Task alone would not fix an isolated outer closure. |
| Audio input tap | Nonisolated factory returns Sendable callback; no service/engine state access. Revalidates hardware format after analyzer awaits, before installing tap; copies audio before yielding to bounded stream. Background delivery tested using synthetic PCM without a microphone. |
| Audio converter input | Both ordinary input and EOF callbacks created inside synchronous nonisolated conversion helper. Per-call supply flag/buffers remain local to the synchronous conversion, with no actor state. |
| Audio session notifications | Combine delivers interruption and route-change notifications on the main run loop before SwiftUI accesses the service. Ignore `.categoryChange` from our own configuration so a queued notification cannot immediately cancel the newly started legacy engine; hardware route changes still interrupt recording. Reason filtering is regression-tested. |
| Modern speech results / input / finalization | Structured async Tasks inherit MainActor intentionally; framework results arrive through async sequences, not actor-isolated callbacks. Generation/cancellation fences follow suspensions. |
| UIKit Quick Actions | MainActor UIKit delegate entry points. No widget audio recording; both widgets only open `nudge://voice`. |
| EventKit changes | Existing notification publisher already delivers on the main run loop. No change. |

Capture ownership is isolated to MainActor. Cancel stops the engine, removes its
tap, finishes input, releases the engine/continuation, and deactivates the audio
session. Then tasks and legacy recognition are cancelled; modern analyzer cleanup
is asynchronous. Repeated cancellation is idempotent. A small injected microphone
boundary tests release without accessing hardware. Backgrounding and audio
interruptions cancel instead of silently continuing recording. Stop drains queued
input before EOF, with an 8-second finalization deadline. Each new modern capture
gets a fresh module/analyzer. Missing Russian assets remain an availability error,
with on-device-only legacy fallback; no cloud fallback is introduced.

Structured OSLog stages use category `VoiceTiming`: `speech_prepare_started`,
`speech_backend_selected`, `microphone_permission_granted`, `speech_permission_granted`
(legacy authorization only), `audio_session_configured`, `audio_engine_started`,
`speech_first_result`, `speech_stopped`, `speech_finished`, `speech_failed`.
Only backend, elapsed monotonic time, and error domain/code are logged. No transcript,
audio, localized error description, or server telemetry is logged.

Apple documents [secondary-thread route notification delivery](https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangenotification)
and [category-change reasons](https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangereason/categorychange).
The input format is checked again before installing the tap if hardware changed
while analyzer setup was suspended. Local Swift 6 probes also exercise PCM resampling
and end-of-input conversion from a background queue; this does not prove iOS hardware capture.

## Physical regression checklist (not yet executed)

Install the **new commit's IPA**, 0.5.0 (6), over the existing app with Sideloadly,
using the same Apple ID/signing identity. Do not delete Nudge or reset its data.
Build/version are intentionally unchanged, so identify the download by CI commit.
Verify the new graphite/blue alarm icon and preservation of tasks/calendar/sounds.

1. Open voice capture normally. With permissions already granted, verify one
   recording starts, partial text appears, Stop finalizes, and Repeat starts again.
2. Exercise the first-permission path on a separate test installation/device if
   available; do not delete production data to reset permissions. Test denied access
   via iOS Settings, then grant access again and retry.
3. Start through each widget with a cold app and an already open app; unlock with
   Face ID normally. Repeated taps must not produce two sheets or two engines.
4. Cancel while preparing/recording; reopen and record again. Background/foreground
   and an incoming call must release the microphone and allow retry without crash.
5. In airplane mode, check Russian recognition, first partial result, final text,
   manual correction and one confirmed task creation. Check AlarmKit + Calendar.
6. If assets are unavailable, verify the availability message/install option or
   supported offline fallback, never silent cloud recognition. Record the selected
   backend from diagnostics; unit tests do not prove Russian model availability.
7. Confirm old alarms, snooze, sound preference, existing tasks/deep links and both
   widgets still work. Observe the privacy microphone indicator going away on exit.

If a crash persists: iOS Settings → Privacy & Security → Analytics & Improvements
→ Analytics Data → latest `Nudge-*.ips` → Share. Provide the full report, the CI
commit used, launch method, permission state and the last safe stage logged.
Compilation and tests do not establish physical-device resolution.

## Icon

Original geometry, generated by `scripts/generate-app-icon.py` (Pillow is a
preparation tool, not an application dependency). The 1024×1024 RGB PNG has no alpha
and uses the universal iOS AppIcon slot. iOS supplies the home-screen mask and can
derive appearances; no separate custom dark/tinted variants are required. CI checks
compiled icon metadata, PNGs and Assets.car inside each built app.


## Native PCM / AnalyzerInput precondition follow-up

The device log and the previous CI test `testAudioTapCanDeliverFromBackgroundWithoutMainActor`
reproduce a second failure: `Audio sample data must be 16-bit signed integers`.
The tap previously constructed `AnalyzerInput` from native Float32 microphone PCM
before format conversion, even when the consumer was the legacy recognizer.

The microphone stream now yields exclusively owned `AVAudioPCMBuffer` copies.
The nonisolated tap snapshots source bytes before hardware can reuse the source,
then creates a new PCM buffer and transfers it with a `sending` return. A short-lived
Sendable byte snapshot lets Swift prove separation of the two mutable buffers;
no unchecked Sendable conformance or actor-check suppression is used. The app's
SDK provides immutable AVAudioFormat Sendable support from iOS 26.

`startAnalyzer` converts native PCM with AVAudioConverter and only then constructs
AnalyzerInput, including resampler EOF output. It checks the Int16 destination before
calling the framework initializer and propagates converter errors. Fresh output
buffers are never reused. `startLegacy` appends the copied native PCM directly,
without constructing AnalyzerInput or converting the legacy stream.

Regression tests cover background Float32 delivery and source reuse, Float32 48 kHz
→ Int16 16 kHz conversion and EOF, preserved earlier output, invalid destination
errors, and legacy buffer append without a recognition task or system permissions.
The existing Float32 tap test already crashed on the old code in CI, providing the
before-fix regression. Actual iOS tests must exercise Apple's AnalyzerInput; a local
Swift 6 / macOS AVFoundation probe validates conversion, ownership and legacy append
but uses a small Int16-asserting stand-in for AnalyzerInput and a fixed probe format
because the local SDK predates SpeechAnalyzer and AVAudioFormat Sendable support.

On iPhone, repeat ordinary voice start, partial text, Stop, Repeat, Cancel and both
widget launch paths. Device resolution is not claimed without that retest. Task
storage, AlarmKit, Calendar, widgets, version and build are unchanged by this fix.
