# Nudge

Nudge **0.2.0 (3)** is a native iPhone app for persistent reminders with real AlarmKit system alarms and flexible snooze. **Stopping or snoozing an alarm never completes its task.** Completion is a separate action in the app.

## Use

- Tap **+**, enter a title and future date/time, then **Save**. Allow AlarmKit access when asked. A task stays saved even if permission or scheduling fails.
- When an alarm fires, **Stop** silences it without completing the task. The custom secondary action opens Nudge directly at that task's **Choose Time** sheet. On newer iOS versions the system may label this action **Open**, despite the app supplying localized Choose Time text. Unlock the iPhone when requested.
- Tap **5 / 10 / 15 / 30 minutes / 1 hour** to immediately reschedule. The selected interval highlights while saving. For another time, use the standard **DatePicker** and tap **Schedule alarm**. The sheet shows the task title and proposed next alarm. Cancel or swipe down before saving to leave the schedule unchanged; controls and dismissal are disabled while saving.
- You can also tap **Choose Time** on any incomplete task in the list, including a reminder whose alarm has stopped or failed. Enable alarms for Nudge in Settings before retrying denied access.
- The list retains the **original task date** and shows the **next alarm** separately after snoozing. Overdue describes the original task deadline, even when the next signal is in the future.
- Tap the circle to explicitly complete a task and cancel its alarm. **Show completed** displays completed tasks. Swipe left → **Delete** cancels the alarm and removes the task. Cancellation errors retain the record so you can retry.
- Registration status is a snapshot, not proof of delivery. An absent alarm may have fired, stopped or been removed; this never changes completion.

New snooze controls and app-supplied alarm button text have English and Russian translations; other languages fall back to English. Native system control labels follow iOS localization.

## Platform and implementation

Swift 6, SwiftUI, SwiftData, AlarmKit and App Intents; no dependencies. iPhone only, minimum **iOS 26.0**, bundle ID **`com.pavlovilya.nudge`**. Acceptance device: **iPhone 13 / iOS 27.2.1**. CI uses the latest installed stable Xcode 27 on `xcode-27`. The Intel development Mac with Command Line Tools does not need a modern local Xcode.

`Nudge.xcodeproj` includes a shared `Nudge` scheme. Build settings: `MARKETING_VERSION=0.2.0`, `CURRENT_PROJECT_VERSION=3`. Xcode merges `Nudge/Info.plist`, including `NSAlarmKitUsageDescription`, with generated settings. No Critical Alerts entitlement, notification fallback or Widget Extension is used.

The existing SwiftData model gains only optional `nextAlarmAt` and `pendingSnoozeAt`. `scheduledAt`, ID, alarm ID and completion remain intact. SwiftData infers a lightweight migration; an automated test writes a disk store with a frozen copy of the 0.1.0 model and opens it with 0.2.0, checking both incomplete and completed records. Storage-open errors remain visible; the app never deletes or silently replaces the user's database.

A `Date` is an absolute instant, unlike a local calendar time. DatePicker handles local calendar/time zone entry; fixed AlarmKit schedules receive that instant directly. Travel changes the display, not the intended instant. The original reminder ID is also its stable AlarmKit ID. SwiftData writes and UI routing run on `MainActor`; awaited system work leaves the UI thread available, like suspending a coroutine rather than blocking a Java thread.

## Rescheduling and partial failure

SwiftData and AlarmKit have no shared transaction:

1. Validate the future date and incomplete task. Obtain permission **before** removing any existing registration. Recheck the task and time after authorization suspends.
2. Read actual fixed schedules. If the same ID already has the requested date, reconcile the local record without another cancel/schedule.
3. Persist the requested date in `pendingSnoozeAt` before touching AlarmKit. If this save fails, leave the old alarm intact.
4. Cancel the old alarm by its stable ID. This removes a sounding alarm and its old schedule. A cancellation error is tolerated only when a successful system read confirms the ID is absent. Otherwise stop and show the error.
5. Register one new `.fixed(Date)` alarm with the same ID; only then save `nextAlarmAt`, registration state and clear the pending marker.
6. On foreground entry and AlarmKit updates, compare any pending date with the actual fixed system schedule. A match completes the local save. A mismatch/missing alarm shows an interrupted/failed snooze and offers manual retry through Choose Time. No automatic rescheduling or background polling occurs.

Permission, scheduling and database errors are visible. A scheduling failure after cancellation can leave **no alarm**; the incomplete task and pending request remain saved for retry. If scheduling succeeded but the final local save failed, the pending marker allows reconciliation on relaunch. Repeated taps are guarded while any store operation is busy. Completion never follows from any of these operations.

## Apple API and Interactive Snippets research

The implementation uses `AlarmPresentation.Alert`, `AlarmButton`, secondary behavior `.custom`, `AlarmManager.AlarmConfiguration(secondaryIntent:)`, `AlarmManager.schedule/cancel`, `alarms`, `alarmUpdates`, authorization and `Alarm.Schedule.fixed`. The action is a `LiveActivityIntent` with a String UUID parameter. It requests `supportedModes = .foreground` and local device authentication, then sets one observable pending presentation request. The sheet consumes that request on cold or warm launch. The intent does not duplicate scheduling logic.

The installed SDK deprecates `openAppWhenRun` at iOS 26 in favor of `supportedModes`; the modern property is used. The stop-button initializer is deprecated at 26.1 and its property is no longer used, so iOS 26.1+ gets the system-provided stop control; only iOS 26.0 uses the older initializer.

[Apple's AlarmKit sample](https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit) documents the custom action as opening the app. [WWDC25 AlarmKit](https://developer.apple.com/videos/play/wwdc2025/230/) demonstrates passing the alarm ID through a LiveActivityIntent. [Interactive Snippets](https://developer.apple.com/documentation/appintents/displaying-static-and-interactive-snippets) support compact follow-up controls in system hosts such as Siri, Spotlight and Shortcuts. **A supported AlarmKit → locked-screen interactive snippet host was not established.** Nudge therefore opens its own native sheet through the documented custom action; it makes no attempt to overlay arbitrary SwiftUI on the system alarm or bypass authentication. Exact button wording and the unlock transition require physical-device acceptance.

See [design, implementation plan and research links](docs/flexible-snooze.md). CI exports the installed SDK declarations as evidence.

## CI and tests

[Pull request #3](https://github.com/PavlovILYA/nudge/pull/3) targets `main` and must remain unmerged until physical acceptance. [GitHub Actions](https://github.com/PavlovILYA/nudge/actions/workflows/ios-build.yml) preserves separate **Release** simulator and unsigned physical-device builds, plus simulator unit tests. Built plist checks require version **0.2.0**, build **3**, bundle ID **com.pavlovilya.nudge**, iOS 26 minimum and a nonempty AlarmKit permission description.

Artifacts (14-day retention):

| Artifact | Contents |
| --- | --- |
| `Nudge-0.2.0-iOS-Simulator` | ZIP of simulator `Nudge.app` |
| `Nudge-0.2.0-iOS-Device-Unsigned` | ZIP of device `Nudge.app`; manual signing required |
| `Nudge-TestResults` | Simulator `.xcresult` test results |
| `Apple-SDK-Reference` | Installed AlarmKit / AppIntents `.swiftinterface` declarations |

Tests cover all five interval calculations, future date validation, persistence, unchanged completion, no duplicate registrations, denied permission, cancellation/scheduling errors and retry, repeated/concurrent requests, deletion/completion, task changes during authorization, interrupted saves, uncertain scheduling outcomes, foreground reconciliation, intent UUID routing and legacy migration. They replace only system alarm closures and inject save errors; they never schedule real alarms or request live permissions.

With compatible Xcode:

```sh
xcodebuild -project Nudge.xcodeproj -scheme Nudge \
  -configuration Debug -destination 'platform=iOS Simulator,name=<installed iPhone>' \
  -derivedDataPath build-tests CODE_SIGNING_ALLOWED=NO test
```

CI does not prove physical alarm delivery, lock-screen routing or signing behavior.

## Install on iPhone 13

AlarmKit delivery in **0.1.0** was confirmed by the user on iPhone 13 / iOS 27.2.1. **0.2.0 physical-device acceptance has not been run.**

1. Download `Nudge-0.2.0-iOS-Device-Unsigned` from the successful PR Actions run. Extract the GitHub artifact and its inner ZIP to obtain `Nudge.app`.
2. In a temporary directory containing `Nudge.app`, package it:

   ```sh
   mkdir -p Payload
   cp -R Nudge.app Payload/
   /usr/bin/zip -r Nudge-0.2.0.ipa Payload
   ```

3. Connect/trust the iPhone and use **Sideloadly** with your free Apple ID to sign/install. Keep credentials/profiles outside this repository. Enable Developer Mode and trust the profile in Settings if required.
4. For upgrade testing, install over 0.1.0 with the **same signing identity and effective bundle ID**. Do not uninstall: uninstalling removes local tasks. Signing tools can change application identifiers; record and preserve the actual identity.

Free Apple ID signing lasts seven days; re-sign when needed. An unsigned app or a ZIP renamed IPA is not installable by itself. CI does not deploy, release, tag or merge.

## Physical acceptance — iPhone 13, iOS 27.2.1 — not yet run for 0.2.0

Record commit, app version/build, device/OS, signing identity, language, expected/actual result and pass/fail. Run in light and dark appearance; check large text and portrait iPhone 13 layout.

1. **Upgrade preparation:** on 0.1.0 create at least one future task, one overdue incomplete task and one completed task. Record titles/dates. Install 0.2.0 over it without uninstalling; verify all records and completion values survived.
2. Create a fresh reminder **two minutes ahead** and allow AlarmKit access. Verify registration and the original task date.
3. **Lock the iPhone** and wait for the real AlarmKit alarm. Record the system title and actual stop/custom-action labels in Russian and English.
4. Tap **Choose Time** (or the system's **Open** label). Verify Nudge opens directly to that task's sheet without searching the list.
5. Record whether Face ID/passcode unlock is required. Repeat with authentication cancelled; no snooze should be saved without a time selection.
6. Tap **5 minutes** once. Verify selected feedback, disabled controls while saving and sheet dismissal on success. Check the new alarm time is about five minutes from the tap.
7. Verify the **original signal stopped** and only one future registration is reported. Check the original deadline remains visible separately.
8. Verify the task **remains incomplete**. Do not tap its completion circle.
9. Lock the phone and **wait for the repeat alarm**. Verify exactly one signal at the new time, with the same task title. Repeat quick selections for **10 / 15 / 30 / 60 minutes** as time permits; verify each chosen time persists after relaunch.
10. Open Choose Time and use **DatePicker** to choose a specific future date/time. Save, reopen the app and verify persistence; wait for a near-future custom selection to confirm delivery. A past time must be rejected. Cancel a separate selection and verify its schedule does not change.
11. On another alarm tap **Stop without snoozing**. Reopen Nudge: the task is still incomplete; no automatic repeat alarm is created.
12. Schedule a snooze, **force-close Nudge**, lock the iPhone and verify system delivery. Reopen before/after firing: task and saved dates persist. Repeat custom-action routing with Nudge terminated and already open (including when the create sheet is open).
13. Check **no duplicates**: tap rapidly, reschedule the same task several times, and verify no signal at superseded times. Complete/delete a snoozed task and verify no later signal. An old action for a completed/deleted task must show an error instead of scheduling.
14. Recheck **upgrade preservation** of future, overdue and completed 0.1.0 tasks. Existing alarms created by 0.1.0 retain their old system buttons until explicitly rescheduled; Choose Time in the list works without re-creating the task.
15. Deny permission in Settings and try snoozing: verify visible failure and retained task. Re-enable permission and retry. Cancel before saving and verify no mutation. Stop/remove the old system alarm before retrying and confirm the missing alarm is handled.
16. Interrupt a snooze by closing the app around saving, then reopen. Expect either the matching new time reconciled or a visible failed/interrupted warning with manual retry. Never assume delivery from a registered badge alone. Simulator tests cover deterministic save-failure boundaries that are difficult to trigger manually.

Known limits: the system owns alarm presentation and authentication; old 0.1.0 alarms are not silently recreated to change buttons. Foreground reconciliation does not resurrect stopped alarms. Permission changes, reboot, Focus/silent mode, signing expiry and termination during system operations need physical checks. No sounds selection, silence/vibration configuration, Siri shortcuts, voice/LLM, Calendar, automatic repeats, widgets, sync or accounts are included.

Develop on feature branches with Conventional Commits. **Do not merge PR #3 before manual device review and explicit authorization.**
