# OpenCircuit 1.0 (50)

Five defects, all reported by testers over 2026-08-26 → 08-29, all root-caused from real
export bundles rather than guessed at. Two of them are the reason a night could read hours
short; one is the reason a recorded walk could vanish from the app while still appearing in
Apple Health.

⚠️ **NOT device-validated.** Everything below is measured by replay and by the test suite.

---

## Your night stops being cut off at the wake end

**The defect.** Sleep scoping ran a pre-filter that sliced the night's records before staging
ever saw them, and that pre-filter absorbed a morning pause of at most **30 minutes** — while
the stager it feeds bridges **60**. The pre-filter runs first, so its verdict was final: a
pause between 30 and 60 minutes was "same night" to the algorithm and "night over" to the
filter, and every record after it was **deleted before staging ran**.

**How it looked.** Reported wake was literally `last record before the pause + 30 minutes`.
On the two New York tester nights it was exactly that, to the second. One night discarded
152 records spanning 7 h 15 m of textbook sleep.

**The fix is structural, not a tuned number.** The pre-filter is now pinned to the same
constant its consumer bridges on, and a test (`testForwardAbsorbIsNeverStricterThanTheBridgeItFeeds`)
fails if anyone ever tightens one side without the other. This is deliberately a
property, not a fitted threshold: the old value was not *too small*, it was *inconsistent*.

**Blast radius, measured.** Against the pinned 38-file sleep corpus, exactly **one of 73 rows
moved** and the scoreboard is otherwise byte-identical (`58fef4b8…b8c6c5`). The maintainer's
own night moves from a 07:12 wake to 08:54:46 against a reported ~09:00.

## Correcting a night no longer costs you the score, and a truncated night stops bragging

A correction used to withhold the readiness score, and a night we had cut short was still
described as having run long. Both fixed; withheld scores are rebuilt from the stored
hypnogram on launch rather than requiring you to re-edit anything.

## Your workout survives leaving the workout screen

**The defect, in one line.** `WorkoutView` held the **only** copy of the running session in
the sheet's own state, and `.onDisappear` finalized it into Apple Health on teardown.

**How it looked.** From the tester report: *"I tapped the live activity on my lock screen and
it opened the app but with the record a new activity screen open and I don't know where the
currently recording activity went… it still ended up in my Apple Health and Bevel as an
activity but I didn't see it in Open Circuit."* The Live Activity had no deep link anywhere in
the project, so tapping it cold-launched the app, which tore down the sheet, which ended and
saved the workout. Health got it. We didn't.

**Now:**
- Leaving the workout screen keeps the recording running (there's an explicit **Minimize**).
- Tapping the Live Activity or Dynamic Island returns you to the running workout.
- A new **Recent Workouts** list reads back what was actually saved to Health. This asks for
  one new Health read permission the first time.
- If the app is killed mid-workout, the next launch offers to save it — ending at the last
  moment we actually **observed**, never at the time you reopened the app.

**Deliberately not done:** there is no "resume" for a crash-orphaned workout, only save or
discard. The per-reading heart-rate series died with the process, and a resumed timeline would
carry a hole we could not describe honestly.

## Auto-detection re-arms after a workout

Recording a workout by hand left automatic detection switched off until the ring next
reconnected. It now re-arms when the workout ends. This is one real cause; it is not a claim
that walk detection is now solved.

## We stop reporting a sport drain as "empty" when we never counted it

The drain trace never counted `0x4d` sport pages at all, so "the ring returns empty sport
history" was never actually established — we had no counter that *could* have contradicted it.
Both new fields are optional so diagnostics bundles from earlier builds still decode.

## The export stops claiming more than it measured

- `coverageFraction` was **unfalsifiable by construction** — measured over a window whose right
  edge *is* the last record, so it could never look bad. A second, falsifiable measurement now
  ships beside it; the existing key and its CSV column are untouched.
- `measuredAwakeSec` counted a time you typed in as a measurement. It no longer does.
- The sleep-stage bar drew fabricated fill and real measurement in the same solid colour. The
  asserted share is now hatched.
- Gen 2 Air owners stop being shown apnea and blood-pressure results the hardware never earned;
  the screen says "Not offered on this model".

---

## Known-open, stated plainly

- **A night can still come up short behind a long gap.** One tester's night improves by
  2 h 28 m and is still about 4 h 34 m short of what she reported. The remainder sits behind an
  unobserved 60-minute gap, and we cannot yet distinguish a genuine recording hole from a
  charge cycle. Not fixed.
- **Data missing from the middle of a night is not recovered.** One tester lost about 4 hours.
  This build labels that gap honestly in the export; it retrieves nothing. Current belief is
  that those pages never reached us, which would mean they may still be on the ring — that is
  an experiment we have not yet run, not a promise.
- **Bedtime can still read early on a still-but-awake evening.** Unchanged, and still blocked
  on ground-truth labels rather than on ideas.

## Gates

1724 Kit tests / 11 skipped / 0 failures · `RingKitVerify` ALL CHECKS PASSED · device build
clean · sleep corpus scoreboard byte-identical to the pinned golden against the real 38-file
corpus, so **no staged sleep number moved** other than the one row named above.
No SwiftData schema change.
