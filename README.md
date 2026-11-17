# Nudge

Nudge **0.1.0 (2)** is a minimal native iPhone reminder prototype. Create a task, persist it locally with SwiftData, and schedule a real one-time AlarmKit system alarm. **Stopping an alarm does not complete its task.** Only the explicit completion button in Nudge marks it done.

## Use

- Tap **+**, enter a non-empty title and future date/time, then **Save**. The default is five minutes ahead. The task is saved before requesting alarm permission or scheduling.
- Allow AlarmKit access at the first system prompt. Nudge declares `NSAlarmKitUsageDescription`; no Critical Alerts entitlement is used. If denied, allow alarms for Nudge in Settings. Failed tasks remain saved and show an alarm warning. This prototype does not retry or reschedule automatically; recreate a reminder after enabling access.
- The main list shows incomplete tasks, their local schedule date/time, and **Overdue** after that instant passes. Tap the circle beside a task to explicitly complete it and cancel its alarm. Enable **Show completed** to see completed tasks.
- Swipe left and tap **Delete** to cancel an associated alarm and remove the task. Cancellation errors retain the record for retry. Completion retains the task; deletion removes it.
- “Alarm registered at last check” reports the latest successful foreground system query or schedule result. It is not proof an alarm sounded. “No alarm registered” can mean it ended, was stopped, or was removed; none of those completes a task.

## Platform and implementation

Swift 6, SwiftUI, SwiftData, and AlarmKit; no third-party dependencies. iPhone only, minimum **iOS 26.0**, bundle ID **`com.pavlovilya.nudge`**. Target acceptance device: **iPhone 13 / iOS 27.2.1**. CI selects the latest installed stable Xcode 27 on `xcode-27`. The Intel development Mac on macOS Sequoia 15.8.1 does not need Xcode 27; do not upgrade it to build this project.

`Nudge.xcodeproj` and the shared `Nudge` scheme are committed. Open with `open Nudge.xcodeproj`. Xcode generates Info.plist from build settings: `MARKETING_VERSION=0.1.0`, `CURRENT_PROJECT_VERSION=2`. Unlike JVM targets, the simulator and device are separate native binaries.

SwiftData owns the on-device persistent store. The reminder UUID is also its stable AlarmKit UUID, saved before calling the system. The app uses `Alarm.Schedule.fixed(Date)` directly: Foundation's date picker interprets local calendar/time-zone selection; the stored value is an absolute instant. Travelling changes the displayed local time, not the scheduled instant. No calendar-component conversion is needed. No alarm is scheduled on launch or for a completed task.

AlarmKit code follows Apple's [documentation](https://developer.apple.com/documentation/alarmkit) and [official scheduling sample](https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit). Only an alert presentation is configured, with native system stop behavior and the task title; no custom stop intent, countdown, Live Activity extension, or widget. App operations and SwiftData mutations stay on the main actor; system scheduling is awaited without blocking the UI thread.

## CI and tests

GitHub Actions **iOS Build** runs for pull requests to `main`, pushes to `main`, and manual dispatch. It preserves separate unsigned Release builds for `generic/platform=iOS Simulator` and `generic/platform=iOS`. Built Info.plist values are checked for version, build, minimum OS, bundle ID and non-empty alarm usage description. Artifact names derive their version from that generated plist. No signing credentials or secrets are required.

Artifacts (14-day retention):

| Artifact | Contents / use |
| --- | --- |
| `Nudge-0.1.0-iOS-Simulator` | ZIP of the simulator `Nudge.app`; cannot install on an iPhone |
| `Nudge-0.1.0-iOS-Device-Unsigned` | ZIP of the device `Nudge.app`; requires packaging and signing below |
| `Nudge-TestResults` | Simulator `.xcresult` test results, including failures when produced |

The simulator job selects an available iPhone simulator on iOS 26 or later and runs the shared scheme's tests. A missing runtime fails the check explicitly. Tests cover validation, the exact overdue boundary, explicit completion, stable IDs/dates across disk-store reopening, persistence before scheduling, scheduling failures, cancellation failure/retry, and foreground refresh without rescheduling/completion. They substitute only system alarm closures and never request live AlarmKit permission. No pure date conversion helper exists because fixed schedules receive the stored Date unchanged.

With compatible Xcode installed:

```sh
xcodebuild -project Nudge.xcodeproj -scheme Nudge \
  -configuration Debug -destination 'platform=iOS Simulator,name=<installed iPhone>' \
  -derivedDataPath build-tests CODE_SIGNING_ALLOWED=NO test
```

CI compilation and these tests do **not** establish physical alarm delivery or permission/signing behavior.

## Install on iPhone 13

The following path was manually verified for **0.0.1**, installed and launched on iPhone 13 / iOS 27.2.1. AlarmKit functionality in **0.1.0 needs separate physical-device acceptance**.

1. Open the PR's successful **iOS Build** Actions run. Download `Nudge-0.1.0-iOS-Device-Unsigned` from **Artifacts** (GitHub sign-in may be required).
2. Extract the GitHub artifact and its inner application ZIP to obtain `Nudge.app`.
3. Package the unsigned device app as an IPA. In a temporary directory containing `Nudge.app`:

   ```sh
   mkdir -p Payload
   cp -R Nudge.app Payload/
   /usr/bin/zip -r Nudge-0.1.0.ipa Payload
   ```

4. Connect the iPhone to the Mac, trust the computer, and use **Sideloadly** to sign/install the IPA with your **free Apple ID**. Enter account credentials only into the signing tool; keep credentials and profiles outside this repository.
5. Enable **Developer Mode** on the iPhone (Settings → Privacy & Security; restart if prompted). Trust the developer profile under Settings → General → VPN & Device Management when required, then launch Nudge.

Free Apple ID signing lasts **seven days**; re-sign/reinstall when it expires. The unsigned artifact is not directly installable, and simply renaming a ZIP to IPA does not sign it. Preserve the same application identity when reinstalling; uninstalling removes local reminders. Do not rely on prototype alarms after signing expiry. Installation/signing is manual; CI does not deploy, release, tag, or merge.

## Known limits and consistency

- System alarms and SwiftData are separate stores with no shared transaction. A process kill after persisting but before scheduling can leave a task with no alarm. Its durable ID remains available; foreground checks can identify registration without creating duplicates. There is deliberately no automatic retry.
- Nudge checks system registrations on foreground entry and listens for AlarmKit updates while the view is alive. It does not poll in the background or assume stop actions execute app code. A missing registration cannot reliably distinguish stopping, firing, or other removal. Task completion never depends on these observations.
- If cancellation fails and the system cannot confirm absence, completion/deletion is refused so the reminder remains retryable. An already-missing alarm is tolerated. If a database save fails after a system operation, Nudge rolls back local changes and displays that the system action may already have occurred. Reopen/check and retry. Storage-open failure is visible; data is never silently replaced with an in-memory store.
- Registration status is a last-check snapshot, including if a later read fails. It cannot guarantee future delivery, current authorization, or device behavior. Permission changes, process termination, reboot and signing expiry require device testing.
- No editing, repeats, re-alarm-until-completed, custom sounds, snooze configuration, widgets, accounts, sync, calendar, Siri, voice, LLM, notifications fallback, or background execution policy.

## Physical-device acceptance — not yet run for 0.1.0

Record device/OS, commit, signing method, expected/actual result and pass/fail for each scenario. These unchecked items are manual acceptance work, not claims of success.

- [ ] Fresh install: create a reminder and observe the first AlarmKit permission prompt; allow it.
- [ ] Create a reminder 2–3 minutes ahead. Confirm the saved task and registered status.
- [ ] Lock the iPhone; wait for the real system alarm and check its task title.
- [ ] Stop the alarm. Reopen Nudge: the task is incomplete and overdue, never automatically completed.
- [ ] Explicitly mark it completed; confirm it moves to completed and survives relaunch.
- [ ] Create another reminder, delete it before firing, lock the phone and confirm no alarm fires.
- [ ] Complete a future reminder before firing and confirm its alarm is cancelled too.
- [ ] Deny AlarmKit permission (reset/reinstall or change Settings as appropriate). Save a task; verify it persists, shows a warning, and the app remains usable. Enable permission and create a new task.
- [ ] Create and register an alarm, kill Nudge, lock the phone, and confirm the alarm still fires. Reopen and confirm the task persists incomplete.
- [ ] Relaunch around a reminder's due time and verify pending/overdue changes without changing completion.
- [ ] Exploratory: repeat delivery in silent mode and Focus; record actual results.
- [ ] Exploratory: reboot between scheduling and firing, unlock after reboot as needed; record delivery and retained task.
- [ ] Exploratory: change time zone / cross a DST boundary and confirm the chosen absolute instant and local display.

Develop on feature branches, use focused Conventional Commits/PRs, and validate Actions before review. Never merge without explicit authorization.
