# Sleep replay harness — stage any night from raw bytes on the command line

**Purpose.** The sleep-accuracy campaign must be *measured*, not argued about. This harness takes a
corpus of nights (base64 `0x4c` records + a manifest row) and runs the **same staging pipeline the
shipped app runs**, printing the detected window, the stage minutes, and the signed error against
whatever reference the night carries.

- Lives in the Kit **test target** → `swift test`, CLI-only, no Xcode project, no HealthKit, no SwiftData.
- Reads **nothing** from the repo and writes **nothing** to it — except `CorpusGateLoudnessTests`,
  which audits this target's own sources. Corpora live outside the tree because they are real tester
  health data (`CLAUDE.md`: never commit a capture).
- With no environment variable set, every entry point **skips LOUDLY**: `SleepReplay.requireCorpus`
  throws `XCTSkip`, so the run is reported as `skipped`, never as `passed`. `swift test` still stays
  green on a machine that holds no health data.

> ⚠️ **A run with the variable unset proves nothing.** Until 2026-08-19 these entry points opened with
> `guard let dir = … else { print("unset — skipping"); return }`. XCTest scores that early return as a
> **pass**, so the fidelity *proof* printed
> `Test Case '…SleepReplayFidelityTests…' passed (0.001 seconds) / Executed 1 test, with 0 failures`
> having asserted **nothing** — on every machine without a corpus. All four entry points did this, not
> just the fidelity one. Read the run summary for `1 test skipped`; if you see `passed`, the corpus
> was actually opened.

| File | What |
|---|---|
| `ios/OpenCircuitKit/Tests/OpenCircuitKitTests/SleepReplay.swift` | loader, the pipeline transcription, the report formatter, and `requireCorpus` — the one legal way to open a corpus. **Read its header block first** — it is the production-parity contract. |
| `ios/OpenCircuitKit/Tests/OpenCircuitKitTests/SleepReplayTests.swift` | the three command-line entry points |
| `ios/OpenCircuitKit/Tests/OpenCircuitKitTests/CorpusGateLoudnessTests.swift` | the gate on the gate: asserts an unset variable skips rather than passes, and source-audits this test target. A **tripwire, not a proof** — read its header for what it does and does not catch. Needs no corpus. |

> **Adding an entry point?** Name its variable `OC_…CORPUS` and open it through
> `SleepReplay.requireCorpus`. Two audit rules enforce that: any `OC_[A-Z0-9_]*CORPUS` literal
> outside the gate fails, and the whole set of `OC_…` names this target reads is pinned in
> `CorpusGateLoudnessTests`, so a new one is a deliberate one-line declaration. Both exist because a
> variable read any other way ends in `guard let … else { return }`, which XCTest reports as
> **passed** — the original defect, and one a differently-named variable silently reinstated until
> the needle was widened from `OC_SLEEP…_CORPUS` on 2026-08-20.

---

## 1. Run it

```sh
cd ios/OpenCircuitKit

# (a) MEASURE — stage every night in a corpus, print the table
OC_SLEEP_CORPUS=/path/to/corpus \
  swift test --filter SleepReplayMeasureTests 2>&1 | sed -n '/SLEEP REPLAY/,$p'

# (b) FIDELITY PROOF — assert the harness reproduces what the app actually stored
OC_SLEEP_FIDELITY_CORPUS=/path/to/fidelity-corpus \
  swift test --filter SleepReplayFidelityTests

# (c) INPUT SENSITIVITY — how much do the inputs a .b64 cannot carry actually matter?
OC_SLEEP_FIDELITY_CORPUS=/path/to/fidelity-corpus \
  swift test --filter SleepReplayInputSensitivityTests 2>&1 | sed -n '/INPUT SENSITIVITY/,$p'

# (d) COVERAGE — score `SleepConfidence.assess` (acquisition flags) on every staged night
OC_SLEEP_COVERAGE_CORPUS=/path/to/corpus \
  swift test --filter SleepCoverageMeasureTests 2>&1 | sed -n '/SLEEP COVERAGE/,$p'

# (e) BASELINE SCOREBOARD — every corpus night, one TSV, and the pinned golden hash
OC_SLEEP_BASELINE_CORPUS=/path/to/corpus \
  swift test --filter SleepBaselineTests 2>&1 | sed -n '/SLEEP BASELINE/,$p'
```

Entry point (d) answers a different question from the others: not "where did staging put the edges"
but "**did the recording cover the night at all**". It replays staging exactly as (a) does, then
builds a `SleepConfidence.Coverage` for each night and prints the before/after scoreboard — which
nights flag, with which reason, the labelled TP/FP cross-tab, the shipped card's own hint counts
re-run rather than assumed, and a `materialGapSeconds` sweep. It is the only entry point that
asserts on a *production* type's behaviour rather than on staging, and it is `XCTSkip`-gated, so an
unset variable reports `skipped`.

> ⚠️ **`UNDET` and `XFILE` in its tables are properties of the corpus, not the device.** A corpus
> night is a noon-to-noon slice of ONE capture artifact; the device archive is continuous. Two rules
> follow, and they cut in opposite directions:
> - **`UNDET`** — past a 12 h horizon the harness withholds the "next record" and the classifier
>   answers `.unknown`. Firing rates printed here are therefore **lower bounds**.
> - **`XFILE`** — a neighbouring record that lives in a *different* `.b64` is discarded, not scored.
>   Asking the ring-wide union "did the stream resume?" answers yes whenever the owner happened to
>   export a second file later, which measures the export schedule and not the ring. That produced
>   one measured false positive (`R3_2026-08-04`, back edge, "resumed" 243.2 min later — the first
>   record of `R3_2026-08-05.b64`). Evidence must be bracketed inside one artifact; the withheld
>   cases are printed so you can see what was thrown away.

### The pinned golden

Every honesty/staging change in this area ships with the claim *"no staged sleep number moved."* The
number that backs it is pinned in tracked source — `SleepBaselineGolden` in
`SleepBaselineTests.swift` — and repeated here so `git grep <hash>` answers *which corpus produced
this?* rather than nothing at all:

| what | sha256 |
|---|---|
| corpus `manifest.json` (identity of the corpus) | `63a07be8f28714b2c31a410c950dfb9c6f69b899097dccbc5f92f18b41061c0e` |
| `baseline.tsv` emitted from it on master `f042639` (74 lines: header + 73 rows) | `ef5dc087a16f0461d14d656d2e3461cc479cceb85ef5d30f5e4dd741eaa13e8f` |

The emitter asserts the baseline hash **only** when the manifest it just read matches the first row —
against any other corpus it prints both hashes and asserts nothing, because there is nothing to
compare against. A mismatch on the pinned corpus is a hard failure: re-pin deliberately and say what
moved, never quote "hash unchanged" past it. `CorpusGateLoudnessTests` keeps this table and the Swift
constants in agreement.

Table columns: `inBedStart · inBedEnd · onset · wake · inBed/aslp/awk/deep/rem/light` (whole minutes
from `SleepStaging.Summary.minutes`) · `eff` · `dStart`/`dEnd` (detected in-bed edge **minus** the
app's stored recorded edge) · `dOnset`/`dWake` (detected **minus** the ground-truth label). All
deltas are signed minutes; `+` means the harness placed it later.

To measure a **change**, pass a `SleepStaging.Tuning` to `SleepReplay.stage(records:…:tuning:)` and
diff the two tables. Every staging change ships behind a kill switch whose default reproduces master
byte-identically — the harness is how you prove that claim instead of asserting it.

---

## 2. Production parity — why the numbers mean anything

`SleepReplay.stage` is a line-for-line transcription of the app's path, checked against master
`f042639`. The file header carries the full annotated mapping; the short form is:

```
temps        = wearTemperatureSamples()                                  RingSession:3618
union        = EpochArchive.merge(existing:incoming:)                    RingSession:3619
nightRecords = BulkSleep.latestNightRecords(from: union, temperatures:)  RingSession:3620
segs         = SleepStaging.classify(from: nightRecords,
                                     temperatures:, baseline:)           RingSession:1580-1582
             + the overnight-envelope gate, judged on the UNION          RingSession:1588-1614
summary      = SleepStaging.summary(segs)                                RingSession:1876
inBedStart   = segs.map(\.start).min()                                   RingSession:1887
inBedEnd     = segs.map(\.end).max()                                     RingSession:1888
onset/wake   = SleepStaging.sleepWindow(segs)                            RingSession:1892
```

`BulkSleep.swift:966-969` derives `heartRateSamples:` and `sleepVitalTimes:` from the same records it
is handed, so the HR gate and the sleep-vitals rescue need no extra input.

### The four inputs a `.b64` file cannot carry

| # | Input | How the harness handles it |
|---|---|---|
| 1 | **Local time zone.** `SleepWindow.isOvernightBlock` (`:123`) defaults to `Calendar.current` and `latestNightRecords` cannot inject a calendar, so the 21:00/09:00 midpoint cliff is decided by the **process** zone. | `withTimeZone` sets `NSTimeZone.default` **and asserts the switch took** before measuring. A silently wrong zone would corrupt every number. |
| 2 | **`wearTemperatureSamples()`** = `nightTemperatureLog`: in-memory, session-scoped, night-window only, stamped with frame *arrival* time (`RingSession:4404`). Unreconstructable — a session replaced at 04:00 starts it empty. | Manifest `temperatures`; `[]` is the honest default and is what a post-relaunch re-stage really sees. **Swept** by entry point (c). |
| 3 | **`personalSleepBaseline`** (`RingSession:1631-1643`): median `hrDeep` of up to 7 prior stored nights, nil below 3. | Manifest `deepHRBaselineBPM`. **Swept** by entry point (c). |
| 4 | **The archive snapshot.** Production staged from the archive *as it stood at that instant*; a row frozen by `.keptManualEdit` never absorbs later drains. | Manifest `inputTruncateAfter` + `inputTruncateReason`. Rows whose input provably differs declare an empty `fidelity` list and are measured, never asserted. |

Deliberately **not** reproduced (none of it feeds the stored window or the stage minutes):
`BulkSleep.sleepSegments`, `computeSleepExtras`, `SleepScore`, naps, the HealthKit mirror.
`SleepEdit.recompute` *is* reproduced, but only as an explicit overlay — see §4.

---

## 3. Corpus schema

Two dialects are accepted. Rows are distinguished by the presence of `ringId`.

### 3a. "harness" dialect — carries fidelity assertions

```
<corpus>/manifest.json
<corpus>/nights/<id>.b64      base64 of concatenated 23-byte 0x4c records, ascending counter
```

```jsonc
{
  "schema": 1,
  "nights": [{
    "id": "juan-2026-08-19",
    "timeZone": "America/New_York",        // IANA id — REQUIRED, decides the overnight cliff
    "records": "nights/juan-2026-08-19.b64",
    "recordCount": 396,
    "recordSpan": ["…", "…"],
    "appBuild": 45,
    "ring": { "generation": "Gen 2", "firmware": "FR02.018" },
    "source": "opencircuit-diagnostics-….txt",
    "inputProvenance": "frameCapture",     // frameCapture | epochArchive | evidenceBlobs
    "inputCaveat": "how this input differs from what staging saw, if at all",
    "codeParity":  "how the producing build's staging differs from master, if at all",
    "inputTruncateAfter": "2026-08-19T09:02:00-04:00",   // optional archive-snapshot replay
    "inputTruncateReason": "why, and how it was measured",
    "deepHRBaselineBPM": null,             // PersonalBaseline input; null = not recoverable
    "deepHRBaselineNote": "…",
    "temperatures": [ { "t": "ISO-8601", "c": 34.5 } ],  // wearTemperatureSamples()
    "stored": {                            // what the app actually persisted
      "isManuallyEdited": true,
      "inBedStart": "…", "inBedEnd": "…", "sleepOnset": null, "sleepWake": null,
      "windowPrecisionSec": 60,            // a diagnostics .txt prints HH:mm ⇒ 60
      "asleepMin": null, "awakeMin": null, "deepMin": null, "remMin": null, "lightMin": null,
      "minutesNote": "why these are / are not a staging output",
      "fidelity": ["inBedStart", "inBedEnd"],           // ONLY these are asserted
      "edit": {                            // optional: the post-edit overlay, see §4
        "inBedStart": "…", "sleepOnset": "…", "sleepWake": "…",
        "onsetProvenance": "read from an artifact, or recovered by search — say which",
        "asleepMin": 389, "awakeMin": 251, "deepMin": 95, "remMin": 87, "lightMin": 207,
        "fidelity": ["asleepMin","awakeMin","deepMin","remMin","lightMin"]
      }
    },
    "label": { "onset": "…", "wake": "…", "source": "self-report", "confidence": "approximate" }
  }]
}
```

**`fidelity` is the whole discipline.** A field is asserted *only* if the row names it. A night whose
input or producing code provably differs from master declares `"fidelity": []` and is reported with
its reason. Never add a field to the list to make a test pass — explain the divergence instead.

### 3b. "shared" dialect — measured, never asserted

The multi-ring campaign corpus, keyed `ringId` + `night`, with `recordsFile` at the corpus root and
`recordedInBedStart/End/Onset/Wake`, `editedInBedStart/…`, `isManuallyEdited`, `isLabelled`,
`edgePrecision`, and the stored minutes at the top level. The harness normalises it, prints its
recorded window as the `dStart`/`dEnd` reference, and uses `edited*` as the ground-truth label when
`isLabelled` is true. It is **never** asserted on: those rows carry neither the temperature log nor
the personal baseline, and their record window is a fixed 24 h slice rather than the app's own
archive — asserting on them would be asserting on a different input.

Rows with no `recordsFile` are summary-only and are counted and skipped, not failed.

---

## 4. The edit trap — read this before believing any stored minutes

A night the user **edited** stores minutes that came out of `SleepEdit.recompute`, **not** out of
staging. Comparing staging output to them is a category error, and it is easy to walk into:

> Before build 44, `DiagnosticsReport` had no `[edited]` marker (that is `e56d709`). A pre-44
> diagnostics bundle therefore prints the **recorded window beside post-edit minutes** with nothing
> to distinguish it from an unedited night — exactly the reading error `e56d709` fixed. **A stored
> row is not evidence of "unedited" unless the artifact that carries it can say so.**

Where the edit's anchors are known (or recoverable), the harness still checks those minutes
end-to-end — base segments → `SleepEdit.recompute` → stored minutes — via `stored.edit`. When an
anchor is *recovered by search* rather than read from an artifact, say so in `onsetProvenance` and
state what is then left unconstrained.

---

## 5. Fidelity proof (measured 2026-08-19, master `f042639`, 5 nights, 3 rings, 2 time zones)

`swift test --filter SleepReplayFidelityTests` → **16 asserted fields, 0 failures.**

| night | build | code parity | inBedStart | inBedEnd | minutes |
|---|---|---|---|---|---|
| `juan-2026-08-19` | 45 | **exact** | `20:24:34` vs stored `20:24` ✓ | `09:03:41` vs stored `09:03` ✓ | via `SleepEdit`: **389 / 251 / D95 / R87 / L207 — all exact** ✓ |
| `testerB-2026-08-18` | 45 | **exact** | `22:24:25` vs stored `22:24:25` ✓ **to the second** | `02:37:02` vs stored `02:37:02` ✓ **to the second** | no unedited minutes stored |
| `juan-2026-08-15` | 43 (+`a29400f`) | near | `22:43:31` vs stored `22:43` ✓ | `08:01:35` vs stored `08:01` ✓ | via `SleepEdit`: **405 / 161 / D60 / R77 / L268 — all exact** ✓ |
| `juan-2026-08-13` | 41 (+`a29400f`) | near | `22:36:54` vs stored `22:36` ✓ | `08:33:11` vs stored `08:33` ✓ | **not a target** — +53 min against a 50 min archive hole the replay input fills |
| `NYair-2026-08-16` | 43 (+`a29400f`) | near | `03:44:21` vs stored `03:44:21` ✓ **to the second** | `09:13:23` vs `06:04:21` — **not a target**, later archive snapshot | post-edit |

**9 of the 10 stored window edges reproduce.** Broken out honestly by the precision the artifact
actually recorded: 4 edges are stored to the **second** (both `testerB-2026-08-18` edges, both
`NYair-2026-08-16` edges) and **3 of those 4 match to the second** — the fourth is the documented
snapshot mismatch. The other 6 edges are stored only to the **minute** (the three `juan-*` nights, a
diagnostics `.txt` limitation) and **all 6 match at that precision**. **Every stored minute that
could be reproduced at all was reproduced exactly**, on two nights, through staging *and* the edit
overlay.

> A `dStart` of `+1` in the measure table on a minute-precision row is rounding, not error:
> `22:43:31 − 22:43:00 = 31 s` rounds to 1 min. The fidelity test compares at the row's own
> `windowPrecisionSec` and is not fooled by it.

Two further cross-checks, both measured:

- **Independent corpora agree.** The five nights also appear in the separately-built shared corpus,
  assembled by a different tool with a different record window. `R3_2026-08-19`, `R3_2026-08-15`,
  `R3_2026-08-13`, `R2_2026-08-18` and `R1_2026-08-16` reproduce this harness's numbers **exactly** —
  same window to the second, same stage minutes.
- **The two unreconstructable inputs are inert here.** Temperatures: identical window *and* minutes
  with the manifest's samples vs `[]` on **5/5** nights. Deep-HR baseline swept over
  `nil/45/50/55/60/65/70`: window and asleep total invariant on **5/5**; only `NYair-2026-08-16`
  moved at all, and only in the Deep↔Light split (`D38/L159` → `D0/L197` at 45–50 bpm).
  So on this corpus their absence carries no error bar for the window or the asleep total. **This is
  a property of these five nights, not a general result** — re-run the sweep on any new night.

---

## 6. Known limits — state these whenever you quote a number from this harness

1. **A stored row is a snapshot.** It was written by one drain and may have been frozen by an edit.
   Use `inputTruncateAfter` and say which snapshot you replayed.
2. **A diagnostics frame capture is not the archive.** It is capped at 1500 frames and can be both
   poorer *and* richer than the archive staging actually read (`juan-2026-08-13` fills a hole the
   archive had). Prefer `epochArchive` provenance where the export carries it.
3. **The shared corpus is measured, never asserted** — §3b.
4. **Labels are a biased sample.** They exist because someone thought the night was wrong. Aggregates
   over labelled nights are "how wrong when wrong", never overall accuracy (`SleepEditLabel.swift`).
5. **Builds ≤ 43 are not master.** `a29400f` (build 44) changed `BulkSleep.latestNightRecords`; it can
   only move the cluster **end** later. Everything from `7f4e664` on is byte-identical to master
   across `SleepStaging.swift`, `SleepDetection.swift`, `BulkSleep.swift`, `SleepWindow.swift`.

---

## 7. A/B'ing a candidate: `observedGapAbsorbCoverageCut` (candidate 1 — **now ON at 0.95**)

The harness can score a staging candidate against master **in one process, on the same bytes, with
nothing else different**. The first knob wired this way is the observed-gap guard on the backward
cluster chain (`BulkSleep.observedGapAbsorbCoverageCut`). **It now ships ENABLED at `0.95`; `0` is
the one-constant revert and is byte-identical to the pre-guard code.**

```sh
cd ios/OpenCircuitKit
# SHIPPED DEFAULT — omit the variable
OC_SLEEP_BASELINE_CORPUS=<corpus> OC_SLEEP_BASELINE_OUT=/tmp/after.tsv \
  swift test --filter SleepBaselineTests
# MASTER / OFF — the TSV is byte-identical to the pre-guard baseline (sha256 ef5dc087…a13e8f)
OC_SLEEP_BASELINE_CORPUS=<corpus> OC_SLEEP_ABSORB_CUT=0 OC_SLEEP_BASELINE_OUT=/tmp/before.tsv \
  swift test --filter SleepBaselineTests
# and, to see WHAT the chain actually bridges on every night (this probe models the UNGUARDED
# chain deliberately — that is how the bridge coverages below were measured):
OC_SLEEP_CORPUS=<corpus> swift test --filter SleepAbsorbProbeTests
# the coverage GEOMETRY the 0.95 choice rests on (no corpus needed):
swift test --filter ObservedGapCeilingProbeTests
```

**Measured result on the 2026-08-19 corpus (73 rows, 27 replayable, 21 staged).** Every cut in
`(0, 0.894]` changes exactly the same two nights; `(0.894, 0.988]` changes one; `> 0.988` changes
nothing. The labelled scoreboard is IDENTICAL across the whole range — which is why the value is
argued from semantics, not fitted.

| cut | nights changed | median \|in-bed edge err\| on labelled nights | mean |
|---|---|---|---|
| `0` (off) | 0 — TSV sha256 `ef5dc087…a13e8f` | 89.5 | 96.2 |
| 0.05 – 0.890 | 2 (`R3_2026-08-19`, `R3_2026-08-12`) | 35.0 | 84.8 |
| **0.95 (shipped)** | **1** (`R3_2026-08-19` only) | **35.0** | **84.8** |
| 0.990 + | 0 | 89.5 | 96.2 |

**Why 0.95.** The cut is a COMPLETENESS threshold, and the two corpus bridges differ in
completeness — measured from the bytes, not modelled:

| bridge | gap | L = gap/150 s | interior records | inter-record deltas | coverage | a FULL gap of this length reads |
|---|---|---|---|---|---|---|
| `R3_2026-08-19` | 2580 s (43.0 min) | 17.200 | 17 | **all exactly 150 s** | **0.988** | 0.988 – 1.047 → **complete** |
| `R3_2026-08-12` | 2350 s (39.2 min) | 15.667 | 14 | incl. **215 s and 275 s** | **0.894** | 0.957 – 1.021 → **an epoch is missing** |

0.95 fires on the complete gap and declines the holed one. That is the single discrimination the
guard is asked to make: a gap missing epochs is a *hole*, which is precisely what the backward chain
exists to stitch.

> ⚠️ **A superseded argument, recorded so it is not re-derived.** An earlier revision justified 0.65
> as "the highest reachable value", on the model that a fully observed gap tops out at
> `(⌊L⌋−1)/L` — 0.667 at the 7.5-min floor, 0.930 at 43 min. That model assumes both gap endpoints
> sit on the 150 s record grid. They do not: the endpoints are `ActivityPeriod` block boundaries. With
> off-grid endpoints a full gap reaches `⌈L⌉/L`, which **exceeds 1.0** at non-integer `L` (1.047 at
> L=17.2, 1.250 at L=3.2) — and the corpus proves it, since the real 43-min bridge reads 0.988 above
> the model's own 0.930 "ceiling". There is **no reachability bound**: every cut ≤ 1.0 is reachable
> at every gap length, so reachability cannot choose the value. The same correction retires the claim
> that "both bridges are completely observed" — they are not, as the delta column above shows.
>
> The measured cost of going lower: at 0.65 the guard fires on a gap only two thirds recovered, and a
> drain hole partially refilled with epochs that read NON-sleep (the motion-blind Gen 2 Air case) is
> TRUNCATED once recovery reaches ~67 %. That is the #193 failure class the chain exists to prevent.

- `R3_2026-08-19` (labelled): in-bed start `20:24:34 → 22:18:36`, error vs the wearer's own corrected
  22:24 goes **−119 → −5 min**. In-bed end unchanged (+10). Asleep 713 → 648 (his true ~395 is a
  separate, unfixed problem — the signal ceiling, not this scoping bug). Efficiency 0.928 → 0.990.
- `R3_2026-08-12` (**no label**): **NOT changed at the shipped 0.95** — its bridged gap is missing an
  epoch (0.894, below its own fully-observed floor of 0.957). At any cut ≤ 0.894 it moves its in-bed
  start `22:51:56 → 01:17:50` (+145 min) with no label to adjudicate it, and its deep sleep collapses
  60 → 15 min. That is the main reason the cut is high.
- The other 20 staged nights, and all 5 fidelity nights except Juan's, are **bit-for-bit unchanged** —
  including `R1_2026-08-02`, the corpus's only `.intensityTail` night (#197's regression guard). Every
  other corpus night stages through `.primary`; `motionIntensityActiveCut` is untouched by this diff.

> The median moves 89.5 → 35.0 because **one** edge moves from 119 to 5 in a 10-value list — at n=10
> the median is a step function. The honest effect size is the **mean**, −11.4 min, i.e. 114 min of
> error removed across 10 edges. Quote both.
>
> ⚠️ That n=10 is the **in-bed edges only**. Over all four labelled error columns (n=16, adding 3
> onset + 3 wake labels, none of which move) the mean is **103.7 → 96.6**. State which denominator
> you are quoting.

### 7a. What it COSTS — report these alongside the wins

- **`R3_2026-08-19` awake-in-bed error 195 → 244 min worse**, efficiency error 0.320 → 0.382 worse
  (0.928 → **0.990** against the wearer's own reference 0.608). This is the documented
  `inbed-equals-asleep` signal ceiling being EXPOSED by a correct bedtime, not created by the guard —
  the same night's *asleep* error simultaneously improves, 324 → 259 min. It is **disclosed, not
  silent**: efficiency crossing 0.95 trips `SleepConfidence.durationLikelyHigh` and
  `SleepCardView.confidenceHint` renders "Very still night — duration may read a little high…"
  (pinned by `ObservedGapAbsorbDisclosureTests`; the night said nothing before the change).
- **Staging is re-fitted inside the smaller window — this is not a pure prefix trim.** On
  `R3_2026-08-19` deep goes 125 → 95 min while REM goes 180 → **185** min, i.e. REM RISES inside a
  strictly smaller window, because the percentile-based stage thresholds see a different
  distribution once the evening is removed. Report stage minutes, not only the in-bed edge.
- **The sleep-score badge goes UP**, 87 → 99 on `R3_2026-08-19` (both "excellent"). A night the wearer
  knows was rough now badges higher. The badge is far more prominent than the efficiency footnote.
- **The card stops reporting a sleep latency** on this night: in-bed start and onset land 30 s apart,
  under the 60 s floor in `SleepCardView.sleepWindowText`, so the "17m to fall asleep" clause
  disappears. Do not describe the change as bedtime DETECTION — it is the removal of a wrong bedtime.
- Only **one labelled night** moves, against `SleepEditLabel.minimumNightsToFit = 10`, and it is a
  single ring (R3, Gen 2). Gen 3 and Gen 2 Air contribute **zero** moving nights, so the guard is
  unmeasured on those generations.
- The known false positive is now live: a real sleep → get-up-and-move → sleep-again night has a
  COMPLETELY observed gap and loses its first bout (`testEnabledCutAlsoDropsARealMidNightBout`).
  **Raising the cut does not mitigate this** — that gap reads ≈1.0 by construction and fires at every
  cut. It is inherent to enabling the guard at all. `NapDetection.swift:70` rejects any candidate
  whose midpoint is overnight, so the dropped bout is **not re-filed as a nap** — those minutes leave
  the daily total outright.
- **A declined bridge `continue`s rather than `break`s.** Measured on a synthetic 3-block night: a
  third block behind an unobserved hole leapfrogs the declined bridge and the guard goes inert
  (ON == OFF). Not a regression versus master — the guard is monotone, it can only move in-bed start
  LATER — but the fix silently does nothing on multi-block nights. Max `nightBlocks` in the corpus
  is 2, so this is unrepresented in real data.
- **Nothing has validated the guard against a device.** Every fidelity fixture predates it, so
  `SleepReplayFidelityTests` and `SleepAbsorbProbeTests.testProbeAgreesWithProduction` are both
  pinned at cut 0 and prove only that the harness matches the PRE-GUARD path. Closing this needs one
  morning Diagnostics bundle, raw frames ON, from a build with the guard enabled.

### 7b. It does NOT rewrite stored history

Verified in source and pinned by `ObservedGapAbsorbHistorySafetyTests`:
`SleepNightKey` anchors on **`inBedEnd`**, which this guard never moves, so a re-drain lands on the
SAME row — no duplicate night, even when the corrected start crosses midnight. That row is then kept:
`LocalStore.swift:1498-1500` sets `sameCoverage` only when BOTH edges are within one 150 s epoch (the
start moves 114–145 min, so it is false), and `SleepSummaryMerge.shouldReplace` therefore judges on
time asleep, which the guard only ever reduces → `.keptFullerStoredNight`. A manually-edited row
returns `.keptManualEdit` even earlier, and `SleepEdit.widenRecorded` is outward-only so a narrower
incoming start cannot shrink the clamp. **The fix improves nights staged from now on; existing
history is untouched.** The load-bearing precondition — that the guard only ever reduces asleep — is
asserted, because if it ever added sleep those rows WOULD be overwritten.
