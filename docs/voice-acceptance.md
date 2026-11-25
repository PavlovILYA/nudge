> Исторический документ. Правила Stop, опциональной даты и главного экрана заменены текущей моделью: [Task-first QA](task-first-qa.md).

# Voice capture — physical acceptance, not yet performed

Target: iPhone 13 / iOS 27.2.1. Record version 0.5.0 (6), commit, signing method/effective app and extension IDs, language/time zone, network state, recognizer name, installed resources and actual outcomes. Simulator/CI and a supported locale list do not prove offline Russian recognition. Keep a copy of your 0.4.0 task dates/IDs/sound/Calendar links before upgrading without uninstalling.

## Install and launch

Install the device IPA over 0.4.0 using the same application identity. Preserve and sign `PlugIns/NudgeWidgets.appex` too. The embedded widget ID must remain a child of the effective main app ID and both must use compatible team/profiles. No App Groups or special microphone entitlements are requested by the widget. Free Apple ID/Sideloadly limits and extension preservation must be tested; an unsigned CI artifact is not installation evidence. If Sideloadly removes extensions, the app may install while the widget is missing. Verify the widget gallery separately. Do not uninstall the previous app to work around signing without first accepting the resulting data loss.

## Checklist

1. Launch via the microphone button inside Nudge. Check idle/preparing/recording/processing/result states in Russian and English, light/dark, Dynamic Type and VoiceOver.
2. Add the **New reminder** systemSmall widget to Home Screen. Tap: Nudge opens VoiceCaptureView directly. Widgets do not record themselves.
3. Add the circular microphone accessory to Lock Screen. Lock the phone and tap it. Nudge should open subject to normal unlock rules, without a custom overlay.
4. Repeat after Face ID/passcode unlock; verify recording starts at most once and only while the app is active and permissions are granted.
5. Long-press Nudge's icon → **Voice reminder**. Check cold launch and an already-running app.
6. On first use press Record and inspect the microphone permission purpose text. No AVAudioEngine recording starts before permission. First permission transitions may require pressing Record again once active.
7. Record which backend is selected. If legacy SFSpeechRecognizer is selected, inspect the separate Speech Recognition request. Modern analyzer modules do not need that legacy permission. The app never enables cloud fallback.
8. Deny microphone and/or required Speech access. Confirm a localized message and working manual text entry; no recording or automatic task creation.
9. Re-enable access in iOS Settings. Return, check availability and record again. The microphone must not start invisibly while opening Settings.
10. Speak Russian: «Слушай, напомни мне завтра в восемь вечера забрать посылку». Compare transcript, proposed title and local tomorrow 20:00. Do not infer quality from a single phrase.
11. Watch intermediate text. Check final fragments do not duplicate, disappear or lose the final words when Stop is pressed.
12. Disable Wi-Fi and mobile data after required system resources are installed. Test with airplane mode and verify Russian recognition, not just text interpretation. Record success/failure per backend.
13. Check installed versus missing resources. Use the explicit Install system language resources action if offered, including connectivity/storage failure and cancellation. No audio is recorded or uploaded during installation. If no supported offline RU backend exists, manual text input must remain available.
14. Cancel while recording and dismiss the voice screen. Check iOS microphone indicator disappears, no hidden continuation and no task is created.
15. Record again after cancellation and after a completed result. Confirm old callbacks cannot overwrite the new transcript.
16. Try hesitations and corrections, e.g. «завтра… нет, послезавтра…». The rule interpreter is not a natural-language model; conflicting times must be corrected manually. Do not accept an unintended interpretation.
17. «Напомни через десять минут позвонить маме». Verify approximately +10 minutes from interpretation, title, selected sound and confirmation before creation.
18. «Завтра часов в семь вечера нужно забрать посылку». Verify tomorrow 19:00 and proper title. Relative dates are anchored at interpretation time; reinterpreting later recalculates them visibly.
19. «25 ноября в 14:30 оплатить счёт». Verify day/month/year and zone. Also test invalid 31 November, malformed 10:5/15:30:45, a past explicit time, missing time and a repeating command. No silently invented exact schedule.
20. Correct date/time directly in the result. Missing dates require explicitly enabling and reviewing the DatePicker. Create must stay disabled for no date or a past time.
21. Correct title directly. Then edit the transcript and observe re-interpretation. During debounce/processing, Create must not confirm the old proposal. Verify proper names and non-time numbers are retained.
22. Tap Create once, then rapidly several times. One UUID/task and one AlarmKit signal should be created through the existing store. Wait for a near-future real alarm, verify Stop/Snooze/task completion remain separate and saved sound persists.
23. With Calendar default enabled and permission/destination valid, create from voice. Verify original event title/start, 15-minute duration, no Calendar alert and no duplicates. Calendar/AlarmKit failures must keep the task and display their status rather than offering a duplicate creation.
24. Close the success screen, open the created task and complete it. Start again via each entry point. Check existing reminder URLs still open their records and stale URLs show an error.
25. Interrupt by a call, route change, screen lock or backgrounding, including while awaiting a permission. Recording must stop; it must not resume automatically on every lifecycle event. An 8-second finalization timeout must release the microphone; partial text can be edited. Normal recordings are capped at 30 seconds.
26. Open a widget/Quick Action while a manual-create form, task editor, settings, snooze picker or another voice screen is open. Unsaved forms require Keep editing or Discard input and open. Keep preserves the form. Repeated voice links must not stack sheets/restart active recording. Recheck that prior 0.4.0 records, alarm IDs, Calendar IDs, sounds, history and defaults survived the update.

## Diagnostics

In macOS Console, select the device and filter subsystem `com.pavlovilya.nudge`, category `VoiceTiming`. Logs contain a recording-start event/backend, monotonic milliseconds to first text and transcription completion, interpretation duration and creation duration. Full voice phrases/audio/transcripts are not logged or uploaded. Record latency with installed assets separately from initial installation/permission setup.

## Parser contract and limits

Supported: today/tomorrow/day-after at numeric time; minute/hour offsets (digits or common Russian number words); weekdays; numeric day plus Russian month with optional year; common day parts; introductory phrases. Numeric hours use 24-hour interpretation. Spoken hours 1–12 without a day part are ambiguous. Omitted year selects the next valid occurrence; an already-passed weekday selects next week. Explicit today/past times require correction. DST gaps/folds are not silently normalized.

No general conversational understanding, multi-reminder splitting, complex relative dates, recurring tasks or LLM. Different Speech availability and model state are runtime facts. The rules can return editable original text when a title cannot be extracted. Every result is a proposal, not a command to schedule.

## 0.6.0 Local LLM boundary

Implement one Sendable `LocalLLMInterpreter: ReminderInterpreter`, returning the existing ReminderDraft from text/context without accessing SwiftData, AlarmKit or EventKit. Keep validation and explicit confirmation, cancellation and stale-result checks. Swap the injected interpreter in the voice screen, add deterministic contract/ambiguity tests and measure interpretation latency with existing local OSLog timings. Model/runtime choice, resource limits, offline storage and prompt-injection/data validation need their own implementation review; no model is included in 0.5.0.
