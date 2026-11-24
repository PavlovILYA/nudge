# Nudge 0.4.0 design and implementation plan

Keep ReminderStore and closure-based system boundaries. SwiftData remains authoritative. Add optional Calendar fields, alarmDisabled and alarmNeedsUpdate. A successful system snapshot, never a saved nextAlarmAt, drives the Alarms section; Tasks includes every incomplete record and History only completed records.

Edit a record in place. Changing its original date explicitly moves the task, clears snooze, reschedules the alarm and updates Calendar. Metadata edits update an existing future alarm but never resurrect an absent/disabled alarm. Completed records never schedule. Persist desired edits plus alarmNeedsUpdate before replacing a registration; after interruption a matching date alone cannot prove title/sound were updated, so require explicit alarm retry. Snooze retains the original deadline and never writes Calendar.

Calendar: full access is requested only by Connect Calendar. Save a default destination and new-task preference in UserDefaults, initially off. Offer existing writable calendars and an explicit Create Nudge action using the default account (or a suitable local/CalDAV source); reuse a single writable calendar named Nudge, reject ambiguous duplicates, and surface source restrictions. iCloud synchronization is provided by the chosen account, not by Nudge.

Events last 15 minutes, have no EKAlarm, and carry nudge://reminder/UUID plus a stable UUID marker line in notes. Find by eventIdentifier, external identifier, and narrow date queries around the original/last-written date. Require both URL and marker before any mutation. Deduplicate candidate IDs; refuse ambiguity, recurrence, foreign or read-only events. All objects belong to one retained EKEventStore on MainActor.

Save desired local data before EventKit. Persist the last event date before the first potentially ambiguous save, then identifiers after success. On retry/foreground reconcile find existing metadata; never blindly insert after an uncertain write or missing previously linked event. A deleted/unfindable event is a visible recoverable lookup error, not permission to create another copy. If no write has been attempted (for example, permission was denied), retry may create the first event. This conservative rule can require manual investigation when a failed first write left no event; it avoids duplicates after process death/provider sync. Disabled per-task links retain prior events and identifiers; completion retains events; deletion removes only verified owned events and retains the task on Calendar errors, including an unfindable event. The editor separately offers explicit local-only deletion that cancels the alarm but leaves Calendar untouched. Changing the global default affects only new tasks.

Listen to EKEventStoreChanged and foreground entry, not background polling. Avoid rewriting identical event content to stop notification feedback; tolerate provider subsecond rounding (<1 second) and CRLF normalization. External edits never schedule alarms; when linked, explicit retry/foreground reconciliation restores Nudge's title and original time. Resolve links across calendars when possible; refuse unsafe guesses when providers change all IDs or remove ownership metadata.

URL handling opens the existing task editor, including completed records; stale/invalid links show a localized error. Calendar's rendering/tappability of event.url remains physical-device acceptance work.

Implementation order: tests for edit/move/snooze/disable/filtering, fake Calendar writes/failures/identity, URL parsing and frozen 0.3.0 disk migration; SDK export; model and store; EventKit adapter/settings; editor/main sections/deep links; localization, CI 0.4.0 (5), artifacts/IPA, review, device checklist. No merge.

Sources checked:
- https://developer.apple.com/documentation/eventkit
- https://developer.apple.com/documentation/eventkit/accessing-calendar-using-eventkit-and-eventkitui (full versus write-only access; requestFullAccessToEvents and EKEventStoreChanged)
- https://developer.apple.com/documentation/eventkit/ekeventstore (same-store objects, event lookup, sources, calendars and writes)
- https://developer.apple.com/documentation/eventkit/ekevent/eventidentifier (identifier may change)
- https://developer.apple.com/documentation/eventkit/ekcalendaritem/calendaritemexternalidentifier (provider identifier, not a universal immutable primary key)
- https://developer.apple.com/documentation/eventkit/ekcalendaritem/url (event URL metadata)
- https://developer.apple.com/documentation/bundleresources/information-property-list/nscalendarsfullaccessusagedescription

Inspect installed EventKit headers in the CI SDK artifact; compile against the same SDK. Existing AlarmKit actions remain the two system-supported controls. The user's iPhone 13 experiment confirmed silent CAF plus vibration in 0.3.0 under their tested conditions, not a public vibration guarantee for all devices.
