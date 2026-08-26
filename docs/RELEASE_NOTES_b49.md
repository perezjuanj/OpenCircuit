# OpenCircuit 1.0 (49) — correcting a night shouldn't cost you anything

Build 48 asked you to keep correcting the nights we get wrong. Then it charged you for
doing it. This build is the apology, and it comes from one tester's report.

## Sleep

**Correcting a night no longer deletes your readiness score.** If you edited your sleep
and the readiness card switched to "sync last night's sleep" — and then syncing didn't
help, no matter how many times you tried — that was us, not you. We were withholding the
score whenever a corrected night covered time the ring hadn't recorded, and the way we
withheld it was indistinguishable from "no data", so the app told you to go do the one
thing that could never fix it. Your corrected nights are scored again.

That rule could only ever fire on a night you had *corrected*. A night the ring recorded
badly and we never touched kept a confident score. That asymmetry is gone.

**"Sync last night's sleep" now only appears when syncing is actually the answer.** When
a night is there but has no score, the card says so plainly instead of sending you to a
button that won't help.

**A correction you made on an older build now reaches Apple Health.** Build 47 wrote your
edited night to Health but quietly dropped the part covering hours the ring hadn't
recorded — so Health, and anything reading from it, kept showing less sleep than the app
did. Build 48 fixed that going forward, but nothing went back for nights you had already
corrected. This build makes one pass over those nights and republishes them. It runs
once, it only touches nights you edited yourself, and it rebuilds them from what is
already stored rather than re-reading the ring — so your stage breakdown is preserved.

**We stopped telling you the ring wasn't recording when it was.** The Sleep card, the
diagnostics bundle and the data export each judged "did the ring record before you went
to bed?" by looking only at what had been filed away in the app's own database. That
database is filled in strictly forwards, so one late-arriving reading could hide hours of
perfectly good recording behind it. On the night that prompted this, the export announced
that nothing was recorded for the 111 minutes before bedtime — across minutes the ring
had recorded without a single gap. All three now check the ring's own stored history too.

## What we still get wrong

**Some rings stop recording mid-night.** On some Gen 2 Air rings the recorder stops a few
hours in while the ring is on your finger and connected — four hours, on the night behind
this build. Those hours are not stored anywhere, so no sync recovers them and no fix here
can invent them. You can still enter your real wake time by hand.

**Sleep after a long recording hole is still dropped.** If your ring stops overnight and
starts again in the morning, we record that morning sleep but don't yet count it toward
the night. On this tester's night that is about 90 minutes we can see and don't credit.
We know where the gate is; we don't yet have enough labelled nights to change it without
guessing, and guessing here would quietly change everyone's numbers.

**Bedtime can still read hours early on some nights.** Unchanged from build 48. Lying
still but awake still looks like sleep to the ring's motion summary. Keep correcting
these — that now costs you nothing.

---

Gates: Kit suite 1674 tests / 0 failures (baseline 1664 + 10 new coverage-witness tests),
`RingKitVerify` ALL CHECKS PASSED, device-configuration Release build clean, no SwiftData
schema change, sleep-staging files byte-identical to build 48. Both lanes passed a fresh
adversarial review with zero blocking findings.

⚠️ Not device-validated, and the sleep-staging corpus gates did not run on this machine
(the corpus is gitignored and absent) — no staging file was touched, which is why that is
acceptable here and would not be for a staging change.
