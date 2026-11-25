# Task-first Nudge implementation plan

**Goal:** One task list; optional deadline/alarm; durable completion from AlarmKit Stop; preserved voice transcript and safe confirmation.

**Model:** Evolve Reminder.scheduledAt to optional without renaming stored fields. Existing IDs/completion/snooze/Calendar/sounds remain. alarmDisabled records explicit off; completedAt records completion; alarmNeedsUpdate on off/completed tasks records pending cancellation. Optional alarmActionsVersion marks registrations that include the new stop intent.

**Persistence:** MainActor app and LiveActivityIntent share one cached default ModelContainer, no new store path/App Groups. Completion is saved before cancellation. All async schedules recheck completion/off state and remove late registrations. Foreground reconciliation retries cancellations. Only actually registered future old alarms receive upgraded actions with the same ID/date.

**Steps:**
1. Evolve model/store and confirmation for optional date/alarm; test new tasks, completion, disabled alarms, migration and scheduling races.
2. Add background completion intent and separate authenticated foreground actions intent; configure supported AlarmKit APIs, reconcile old registrations, test durable/idempotent completion and routing.
3. Replace tabs with task rows/checks/alarm toggles and completed filter; adapt manual/editor/voice screens to optional schedule. Keep transcript assembly, guard manual edits and reuse existing sound preference.
4. RU/EN strings, focused review, local pure checks, migration and intent tests, device QA docs; push existing branch and trigger existing CI matrix. No merge or pipeline polling, no physical success claims.

**Validation outcome:** Local syntax/plist/catalog checks and Swift 6 pure-value tests pass. Full SwiftData/Observation builds cannot run with local Command Line Tools because macro plugins are absent; disk migration/intent tests are in the iOS suite. Focused review findings on migration/schedule races and stale editor toggles were fixed with regressions. CI is triggered by the final push; do not claim its result before completion.
