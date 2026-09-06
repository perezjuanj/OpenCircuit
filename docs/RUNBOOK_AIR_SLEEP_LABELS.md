# Runbook — self-reported sleep labels from the Gen 2 Air testers

Goal: turn the Gen 2 Air staging question from **unmeasurable** into **decidable**, by collecting
~5 nights of self-reported bed/wake times from each Air tester alongside a Diagnostics export.

> This is the cheap path. The RingConn-hypnogram capture in `RUNBOOK_SLEEP_GROUNDTRUTH.md` is
> **dead** (the ring has one resume pointer — a night we drained is a night RingConn cannot have
> staged), and a Helio strap on a tester's finger is not something we can arrange remotely.
> Self-report is what is actually obtainable from these two people.

## Why this specific ask unblocks a specific decision

Every Air capture we hold is **unlabelled**, so nothing can adjudicate an Air staging change — only
show that it moved. Concretely, on `NYair-2026-08-16` the candidate FR04 motion fix moves detected
wake **09:13 → 10:31**, and we cannot say which is closer to the truth.

`dEndVsStored` cannot answer it. That night's stored value is **06:04** — a 2 h 20 m night on data
that runs flat-still (primary pinned 36–37, tail all-zero, HR 67–79) through 09:46. It is our own
truncated output, so scoring against it is the echo-label trap (`sleep-corpus-echo-labels`): moving
away from a known-bad number is not evidence of anything.

**A self-report resolves exactly this.** The disagreement is 78 minutes at the wake edge. A person
knows within ~15 minutes when they woke up. Approximate labels are more than precise enough for
the in-bed/wake EDGES, which is the entire blast radius of the change.

> ⚠️ They do **not** license anything else. Self-report cannot fit Deep/REM placement or per-epoch
> staging — for that the campaign still needs an independent device. Land these as
> `confidence: "approximate"` and never quote them at a precision they do not have.

## What makes or breaks the batch: they must write it down BEFORE opening the app

If a tester checks Open Circuit and then "remembers" their wake time, we have manufactured another
echo label and the batch is worthless — worse than worthless, because it will look like ground
truth. The instruction to record first and look second is the single load-bearing part of the ask.

---

## The message to send

> Hey — I'm working on a bug that mostly hits your model of ring (the Air), where it sometimes
> gets your wake-up time badly wrong. I have two possible fixes and no way to tell which one is
> right, because I don't know when you actually woke up. That's where you come in.
>
> For the next **5 nights or so**, could you jot down four things each morning?
>
> 1. Roughly when you got into bed
> 2. Roughly when you think you fell asleep
> 3. When you finally woke up for the day
> 4. When you actually got out of bed
>
> Plus, if either applies: any long wake-up in the middle of the night (roughly when, roughly how
> long), and whether the ring was off your finger or charging at any point overnight.
>
> **The one thing that matters: write it down before you open Open Circuit.** If you check the app
> first, your memory will drift toward whatever it showed you, and then I'm just measuring the app
> against itself — which is exactly the problem I'm trying to get out of. Rough is completely fine.
> "Bed around 11:30, asleep maybe midnight, up at 7:15, out of bed 7:40" is perfect. Guessing is
> fine too — just mark the ones you're unsure about.
>
> A note on your phone, or a text to me each morning, whichever is easier.
>
> At the end, go to **Profile → Device Info → Diagnostics**, export it, and send me that file
> along with your notes. It has your overnight heart-rate and sleep data in it, so send it only to
> me. That's what lets me line your notes up against what the ring actually recorded.
>
> This genuinely does unblock the fix — thank you.

## Landing the results

1. Keep the notes and the export **out of the repo**. `desktop/captures/` is gitignored precisely
   because these are real health data (`CLAUDE.md`); commit decoded findings only.
2. Get the raw records into the corpus the usual way — the export's
   `historySyncEvidence[].rawRecordBlobBase64` / `epochArchive[].recordsBase64` become
   `desktop/captures/corpus-harness-v1/nights/<id>.b64`.
3. Add the label to that night's manifest row, in the shape already in use:

   ```json
   "label": {
     "onset": "2026-09-14T00:05:00-04:00",
     "wake":  "2026-09-14T07:15:00-04:00",
     "confidence": "approximate",
     "source": "self-report (Air tester batch 2026-09-14)"
   }
   ```

   Use the **wake-up** time for `wake`, not out-of-bed — `detWake` is the asleep→awake edge. Note
   out-of-bed separately if you captured it; it bounds `inBedEnd`, which is a different column.
4. Mark a night the tester flagged as ring-off/charging as unusable rather than labelling it. A
   hole caused by the ring being off the finger is not a staging error, and scoring it as one will
   push the fit in the wrong direction.
5. Re-run the baseline emitter and re-score the candidate change:

   ```sh
   cd ios/OpenCircuitKit && \
     OC_SLEEP_BASELINE_CORPUS=<corpus-dir> OC_SLEEP_BASELINE_OUT=<corpus-dir>/baseline.tsv \
     swift test --filter SleepBaselineTests
   ```

   With labels present the night stops being scored against `dEndVsStored` alone, and the FR04
   motion flag can be promoted (or dropped) on evidence instead of on argument.

## How many nights is enough

Five per tester is the ask; the decision needs less. The two candidates differ by 78 minutes at the
wake edge, which is far larger than self-report error (~15 min), so **3 clean labelled nights per
tester already separates them** — the extra two are insurance against nights lost to ring-off,
charging, or a recorder stall (and on Air, recorder stalls ate 16 %, 32 % and 88 % of the span in
the three captures we hold, so budget for losing some).
