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
```

```sh
# (d) BASELINE SCOREBOARD — every corpus night, one TSV, and the pinned golden hash
OC_SLEEP_BASELINE_CORPUS=/path/to/corpus \
  swift test --filter SleepBaselineTests 2>&1 | sed -n '/SLEEP BASELINE/,$p'
```

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
