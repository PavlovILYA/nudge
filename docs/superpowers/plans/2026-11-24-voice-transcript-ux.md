# Voice transcript and confirmation implementation plan

> Execute inline with the executing-plans workflow; preserve PR #6, version 0.5.0 (6).

**Goal:** Preserve the complete utterance, simplify voice confirmation, and use one opt-in-preserving default sound for new tasks.

**Architecture:** A small value-type transcript stores timed text fragments, replaces overlapping hypotheses, and respects finalization watermarks. Both modern modules request word timestamps; legacy recognition keeps whole-utterance snapshots. SwiftUI interprets only settled text. Existing ReminderStore/VoiceCreation remain the creation path.

**Tech Stack:** Swift 6, CoreMedia, Speech, SwiftUI, UserDefaults; no new dependencies or schema changes.

- [x] Commit 1: deterministic tests for sequential/overlapping/split/retracted results, pauses, finalization without reissue, duplicate updates, punctuation, legacy snapshots. Implement timed assembly and wire both modern result sequences; retain Stop/result-stream drain.
- [x] Commit 2: separate recording/finalization/review UI, visible date selection without toggle, collapsed optional sound/Calendar, debounced interpretation only after recording or manual editing; preserve duplicate-create guard. Centralize new-user sound preference without altering stored values or old task fallback. Test preferences and localization; document device acceptance.
- [x] Validate local pure logic with Swift 6, parse/plist/localization checks and independent review. Push both commits together to trigger the existing CI matrix; CI results remain pending. Do not wait/poll pipelines, merge, or claim physical testing.
