# Alarm-backed reminders implementation plan

**Goal:** Implement the user's Nudge 0.1.0 vertical slice, from persisted creation to native alarm to explicit completion.
**Architecture:** SwiftData Reminder; one main-actor reminder operations component with a small closure boundary for system alarms; SwiftUI list and creation form. Persist the stable alarm ID before scheduling. Cancel before completion/deletion; retain the task on cancellation failure. Never infer completion from system alarm state.
**Stack:** Swift 6, SwiftUI, SwiftData, AlarmKit; iOS 26.0; Xcode 27 CI. Version 0.1.0 (2), com.pavlovilya.nudge. No dependencies or signing credentials.
**Spec:** User's “Nudge 0.1.0 — First Functional Prototype” request, 2026-11-18. Autonomous inline execution authorized; no design approval checkpoint needed.

## Review focus

- Process termination between persistence and scheduling: durable UUID and unconfirmed state, no automatic rescheduling.
- Denial/scheduling error: retain reminder and show failure.
- Cancellation or persistence failure: keep a retryable local record, never delete first.
- Alarm ended or missing: cancellation tolerates absence; no completion side effect.
- Time zone/DST: use an absolute Date and Alarm.Schedule.fixed directly, no manual calendar conversions.

## Tasks

- [ ] Add focused tests first for validation, date boundary/classification, explicit completion, stable identifiers, persistence across containers, and failure paths without live authorization.
- [ ] Add Reminder.swift, AlarmService.swift, ReminderStore.swift; wire SwiftData in NudgeApp. Use an on-disk store; visible failure if opening fails rather than silent in-memory fallback.
- [ ] Replace ContentView; add creation form. Show active/completed, date, overdue, explicit completion, deletion, busy/error and truthful alarm status. Refresh system registration in foreground, without scheduling on launch.
- [ ] Add test target/shared scheme, simulator test execution, preserve Release matrix/artifacts; derive artifact version from built Info.plist (generated from build settings). Update version/usage description.
- [ ] Document installation, limitations and unverified device acceptance checklist. Review diff and run project/static checks.
- [ ] Commit, push, create focused PR; inspect Actions, fix failures and rerun until builds/tests pass. Leave PR unmerged.

## Evidence ledger

- Base: bootstrap PR #1 merged at 2026-11-17T22:02:24Z, origin/main 27c381d. Clean working tree; created feat/alarmkit-reminders from origin/main.
- Apple docs and official SchedulingAnAlarmWithAlarmKit sample inspected. fixed(Date) is the one-time absolute schedule. Native stop works without custom intents; no countdown or widget required.
- Local compatible Xcode is not assumed; simulator and SwiftData tests run on CI.
