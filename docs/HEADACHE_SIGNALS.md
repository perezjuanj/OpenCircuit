# Headache Signals — plan of record

Status: **Phase 1 SHIPPED on `feat/headache-signals`** (headache log + Apple Health mirror +
import). Phases 2–4 are DESIGNED, NOT BUILT.

Provenance: produced by a recon + adversarial-design pass over (a) this codebase, (b) a
reconstruction of RingConn's own server-side "Headache Signs Alert" from the decompiled 4.2.1 APK
and the shipping iOS binary, and (c) the published science. Three independent designs were scored by
three adversarial judges on distinct lenses; the evidence-first design won unanimously.

Read §1 first. The honest arithmetic there is the reason this feature is shaped the way it is: at
the realistic ceiling a headache alert is wrong about three times in four, so the alert has to EARN
its way on per-user rather than ship on by default.

Numbers in this document that are not tied to a citation or to our own measurement are marked
🔴 PROVISIONAL and must be calibrated before they can be trusted.

---

# Headache Signals — implementation plan

**Branch:** `feat/headache-signals` · **Target:** OpenCircuit iOS (RingConn Gen2/Gen3)

---

## 0. Confidence-tag convention (project rule: a threshold IS a claim)

| Tag | Meaning |
|---|---|
| 🟢 | Traced to a citation in the dossier, the iOS SDK, or a measurement we have |
| 🟡 | Derived from an already-shipped, already-reviewed OpenCircuit constant |
| 🔴 **PROVISIONAL** | Invented. Named calibration plan in §10/§12. Must carry the `🔴 PROVISIONAL` marker in source. |

---

## 1. The honest arithmetic, stated first

Reproduced verbatim in the header of `HeadacheSignals.swift`. All user-facing copy is written against it.

**Published ceiling for physiology-only headache forecasting:** AUC ≈ 0.62–0.68. HAPRED-II reached 0.66 only after >1 month of that person's own diary. The only nocturnal-wearable study (Empatica, N=10, 315 nights) beat chance for **5 of 9** participants, and **4 of 5 chronic-migraine patients scored BELOW chance**. The one model hitting 0.84 did so on *prior headache intensity and duration* — autocorrelation, not physiology.

**Our operating point:** flag the top 10% of the user's own frozen daily scores. Binormal: `d' = √2·Φ⁻¹(AUC)`, `TPR = Φ(Φ⁻¹(FPR) + d')`.

| AUC | d' | TPR @ FPR 0.10 | Headache days/mo | TP/mo | FP/mo | **PPV** | Alerts/wk | Recall |
|---|---|---|---|---|---|---|---|---|
| 0.60 | 0.358 | 0.178 | 4 | 0.71 | 2.60 | **21%** | 0.77 | 18% |
| 0.65 | 0.545 | 0.231 | 2 | 0.46 | 2.80 | **14%** | 0.76 | 23% |
| 0.65 | 0.545 | 0.231 | 4 | 0.92 | 2.60 | **26%** | 0.82 | 23% |
| 0.65 | 0.545 | 0.231 | 8 | 1.85 | 2.20 | **46%** | 0.94 | 23% |
| 0.70 | 0.742 | 0.295 | 4 | 1.18 | 2.60 | **31%** | 0.88 | 29% |

**Plain reading at the realistic centre (AUC 0.65, 4 headache days/month): about 3 in 4 alerts will be wrong, and about 3 in 4 attacks will be missed, at roughly 0.8 alerts per week.**

### 1.1 How long until the gate can even pass — computed, not guessed

At AUC 0.65, 4 headache days/month, flagging the top 10%:

- **180 days:** 24 positives, 18 flagged, expected TP ≈ 5. Null hypergeometric mean `18 × 24/180 = 2.4`. `P(TP ≥ 5) ≈ 0.081`. **Fails α = 0.05.**
- **365 days:** 48.7 positives, 36.5 flagged, expected TP ≈ 10, null mean 4.87, sd ≈ 1.95 → `z ≈ 2.37`, `p ≈ 0.009`. **Passes α = 0.01.**

**Therefore: a typical episodic user needs roughly a year of complete logging before notifications can unlock, and many users will never unlock because the detector genuinely does not work for them.** `evaluationWindowDays = 365` (not 180) is chosen for exactly this reason. This expectation goes in the release notes, the settings copy and the detail screen — not discovered by a tester six months in.

---

## 2. Architecture

```
OpenCircuitKit (Foundation ONLY — `swift test` on the CLI)
├ Analytics/RobustBaseline.swift      median/MAD z, circular median      [P2]
├ Analytics/HeadacheSignals.swift     the index: features → score → band [P2]
├ Analytics/HeadacheEvaluation.swift  permutation + Hanley–McNeil + gate [P3]
├ Analytics/BarometricTrend.swift     night-anchored pressure delta      [P4]
└ HealthAlerts.swift                  +1 enum case, +HeadacheNotifications[P3]

app target (Apple frameworks)
├ Store/HeadacheStore.swift           2 @Models + LocalStore extension    [P1]
├ Headache/HeadacheDefaults.swift     shared @AppStorage key constants    [P1]
├ Headache/HeadacheLogSheet.swift     Form-based log                      [P1]
├ Headache/HeadacheCardView.swift     Today card                          [P1/P2]
├ Headache/HeadacheSignalsView.swift  detail + evaluation panel           [P2/P3]
├ Headache/HeadacheEngine.swift       snapshot → Task.detached → freeze   [P2]
├ Headache/BarometerSampler.swift     CMAltimeter glue                    [P4]
└ Health/HealthKitWriter.swift        +.headache write/read               [P1]
```

**Invariant:** every constant, threshold and statistical test lives in the Kit. The app target only fetches, snapshots to `Sendable` values, calls the Kit off the main actor, and persists. This is the only shape that unit-tests without HealthKit or CoreBluetooth.

---

## 3. The detector spec

### 3.1 Baselines — a NEW namespace, not a `VitalsBaseline.Config` parameter

`OpenCircuitKit/Sources/OpenCircuitKit/Analytics/RobustBaseline.swift`

```swift
public enum RobustBaseline {
    public struct Stats: Equatable, Sendable { public let median: Double; public let mad: Double; public let n: Int }

    public static let minBaselineDays = 7          // 🟡 = VitalsBaseline.Config().minBaselineDays
    public static let maxBaselineDays = 60         // 🟡 see below
    public static let madConsistency  = 1.4826     // 🟢 Gaussian consistency constant
    public static let zClamp: Double  = 4.0        // 🔴 PROVISIONAL

    public static func stats(_ prior: [Double],
                             minDays: Int = minBaselineDays,
                             maxDays: Int = maxBaselineDays) -> Stats?

    /// clamp((today - median) / max(1.4826*mad, noiseFloor), ±clamp). Zero MAD does NOT explode.
    public static func z(today: Double, stats: Stats, noiseFloor: Double, clamp: Double = zClamp) -> Double

    public static func circularMedianMinutes(_ minutesSinceMidnight: [Int]) -> Int?
}
```

**Why a separate namespace, not median/MAD bolted onto `VitalsBaseline`:** the byte-identical discipline. `VitalsBaselineTests`, `SkinTempBaselineTests` and `HealthAlertsTests` must pass **unmodified** and remain the proof that nothing shifted. Grafted from *signal*, whose reason is exactly right: *"so no existing caller's output can shift by a single bit."*

**Why median/MAD instead of mean/SD:** the days we want to detect are themselves the outliers that inflate an SD, and the archive contains real artifact nights (the documented 86 °F cold-object-held-while-asleep night, `SkinTempBaseline.swift:35-44`).

**`maxBaselineDays = 60` 🟡 — signal's justification corrected.** ARE(MAD, SD) ≈ 0.368, so 60 MAD-days ≈ **22** SD-equivalent days, not 30. Matching `VitalsBaseline`'s 30-day SD precision would need ~81 days. 60 is a deliberate trade of precision for outlier immunity, sized to real coverage. **The corrected number goes in the source comment** — signal's `≈ 30` was wrong.

### 3.2 Features and noise floors

The noise floor is the absolute deviation below which a feature contributes exactly 0 regardless of z, so a person with a very tight baseline is not flagged on a 1-LSB wobble.

| Feature | Source | Noise floor | Tag |
|---|---|---|---|
| `restingHRDeviation` | `RestingHR.dailyValues(hr:sleep:)` | 5 bpm | 🟡 `VitalsBaseline.Config().minDeltaRestingHR` |
| `hrvDeviation` | mean `.hrvSDNN` in the in-bed window | 8 ms | 🟡 `.minDeltaHRV` |
| `skinTempDeviation` | `SkinTempBaseline.offset` (canonical, never re-derived) | 0.3 °C | 🟡 `SkinTempBaseline.fluctuationBaselineGateC` |
| `sleepEfficiencyDrop` | `StoredSleepSummary.efficiency` | 5 %-pt | 🟢 Bertisch's day-1 signal was efficiency ≤90 % vs a ~95 % norm |
| `sleepFragmentation` | `StoredSleepSummary.awakeMin` | 15 min | 🔴 PROVISIONAL |
| `sleepDurationDeviation` | `StoredSleepSummary.asleepMin` | 30 min | 🔴 PROVISIONAL |
| `scheduleShift` | circular \|Δ\| of in-bed-start vs 14-night circular median | 30 min | 🟡 half the 60-min SD `TrendsEngine.sleepRegularity` maps to score 0 |
| `arousalLetdown` | `dayHRAvg` z(D−2) − z(D−1) | 0.5 z | 🔴 PROVISIONAL |
| `perimenstrual` | `CyclePredictor` + `isLoggedPeriodDay` | n/a (binary) | 🟢 MacGregor menses −2…+3 |

**Every feature contributes `|z|`, unsigned, except `arousalLetdown` (signed: a FALL in arousal is risk) and `perimenstrual` (binary).**

**The cost of unsigned scoring — stated, because no proposal stated it.** Scoring departure-from-normal in *both* directions is the correct response to the documented per-person sign inversion (Empatica: participant 1041's migraines followed SHORT sleep, 1054's followed LONG; *higher* minimum PRV predicted headache). But it roughly halves usable information and it fires on the **protective** tail — an unusually restorative night with unusually high HRV scores identically to a bad one. The file header and the detail-screen copy both say so: *"we score how unusual today is for you, in either direction — not how bad it is."* Per-user sign learning is deferred (§9).

### 3.3 Contribution ramp

```
contribution(f) = clamp01( (|z(f)| - onsetZ) / (saturationZ - onsetZ) )

onsetZ      = 1.0   🔴 PROVISIONAL — below 1 MAD-unit contributes exactly 0, so an ordinary
                     day scores 0 rather than a fabricated "low risk 23%". Set below
                     VitalsBaseline.minorZ (1.5) because a soft composite should start
                     counting before the vitals engine calls it Minor.
saturationZ = 2.5   🟡 numerically equal to VitalsBaseline.Config().significantZ, but COPIED
                     AS A LOCAL LITERAL with a provenance comment — NOT read from
                     VitalsBaseline.Config(). Reading it would let a future vitals retune
                     silently move the headache scale and invalidate every already-frozen
                     index, while the freeze guarantees old rows are never recomputed —
                     mixing two scales inside one evaluation.
```

Skin temp uses `tempOnsetC = 0.5` / `tempSaturationC = 1.0` (🟡 both copied as literals from `VitalsBaseline.Config().tempMinorC` / `.tempSignificantC`, the latter = `SkinTempBaseline.normalDeviationC`, itself from the APK copy).

### 3.4 Weights — re-ordered to match the cited evidence

The winning proposal's weights contradicted the paper it cited. Bertisch 2020 (98 adults, 4406 days, 870 headaches) concluded *"short sleep duration and low sleep quality were **not** temporally associated with migraine"* and found actigraphic fragmentation associated in the **wrong** direction on day 0 (WASO >53 min, OR 0.64). The **only** sleep measure reaching day-1 significance was diary sleep **efficiency** (OR 1.39, 1.07–1.81). Efficiency is split out and promoted; duration and fragmentation are demoted.

| Feature | Weight | Justification |
|---|---|---|
| `sleepEfficiencyDrop` | **0.18** | 🟢 Bertisch day-1 OR 1.39 — the only sleep term with prospective support |
| `arousalLetdown` | **0.18** | 🟢 Lipton 2014, OR 1.5–1.9 for a stress DECLINE — the strongest prospective mechanism with an unambiguous direction |
| `hrvDeviation` | **0.14** | 🟡 Koenig g = −0.63 is a **between-person trait**; within-person RMSSD is ~flat ictally (31.44 / 31.22 / 31.44 ms). Demoted from parity's 0.30 for exactly this reason |
| `restingHRDeviation` | **0.14** | 🟢 JHP 2026 ranked heart-rate features third |
| `sleepFragmentation` | **0.10** | 🟢 demoted — Bertisch's day-0 association ran the wrong way |
| `sleepDurationDeviation` | **0.10** | 🟢 demoted — "not temporally associated" |
| `scheduleShift` | **0.08** | 🔴 PROVISIONAL — plausible, no prospective wearable evidence |
| `skinTempDeviation` | **0.08** | 🟢 kept low: the only strong temp result is an N=2 study; temperature did not appear in the Empatica top SHAP features. Machinery is free |
| **Σ (ring-derived)** | **1.00** | |
| `perimenstrual` | **+0.20** | 🟢 MacGregor perimenstrual estrogen withdrawal. Added to the pool only when applicable. **Ring-fenced** |

### 3.5 Renormalisation, and the two guards that ring-fence cycle phase

```
present = weights of features whose input is non-nil (ABSENT ≠ zero — never imputed)
index   = round(100 · Σ wᵢ·cᵢ / Σ wᵢ)
```

**Guard 1 — cycle does not count toward the minimum.** `minRingFeaturesForScore = 4` 🔴 PROVISIONAL counts only the eight ring-derived features; `perimenstrual` is excluded from the count.

**Guard 2 — no single feature may exceed 35 % of the renormalised pool.** `maxSingleFeatureShare = 0.35` 🔴 PROVISIONAL, enforced by an iterative cap (max 3 passes): if `max(wᵢ)/Σw > 0.35`, scale that weight so its share is exactly 0.35 and renormalise the remainder.

Both exist because the science judge found the fatal flaw: with `perimenstrual` at 0.20–0.30 and a 4-feature day of `{perimenstrual, scheduleShift 0.08, skinTemp 0.08, sleepDuration 0.10}` the pool is 0.46 and cycle phase alone is **43 %** — a top-band day produced by a calendar lookup with no ring measurement contributing. The winning proposal's own protective test was scoped to *"the eight NON-CYCLE features"*, i.e. written around the defect. **`testNoSingleFeatureExceedsCapAtMinimumFeatureCount` enumerates every 4-subset INCLUDING perimenstrual.**

### 3.6 Quality multipliers (grafted from *signal*)

`SleepCaptureCoverage.classify(capturedOnset:capturedInBed:scheduledBedtime:)` — verified at `SleepCaptureCoverage.swift:53`, pure Foundation, already shipped. Returns `.likelyTruncated` when the span fits inside the ring's ~4.75 h buffer **and** the captured onset trails scheduled bedtime by ≥90 min.

```
quality(sleepDurationDeviation) = quality(sleepFragmentation) = truncated ? 0.5 : 1.0   🔴 PROVISIONAL
effectiveWeight = weight × quality
```

Without this, a ring-buffer-truncated night — the most common bad night in this app — scores as a large *genuine* sleep deviation on the two features most prone to that false positive. Neither *evidence* nor *parity* found this API.

### 3.7 Banding — a per-user false-alarm budget, not a fixed score

```
prior = trailing bandWindowDays (60) 🔴 PROVISIONAL frozen indices, excluding today
< p75             → .typical
p75 … < p90       → .elevated
≥ p90             → .flagged   (the only band that may ever notify)
```

`elevatedPercentile = 0.75`, `flaggedPercentile = 0.90` 🔴 PROVISIONAL — chosen to hit the §1 alert budget (~10 % of days ⇒ ~0.8 alerts/week), not an accuracy target. A fixed score threshold fires constantly for a noisy person and never for a stable one; a percentile budget bounds annoyance regardless of individual noise and re-calibrates after a life change inside 60 days.

`minDaysForBanding = 21` 🔴 PROVISIONAL — the 90th percentile of n = 21 interpolates near the 3rd-highest point. Below this: `.buildingBaseline`, no band, ever.

**Multi-signal rule (grafted from *signal*):** `.flagged` additionally requires `minContributingFeatures = 3` 🔴 PROVISIONAL features each at contribution ≥ 0.5. This encodes the thesis as an enforceable invariant: *the top band can never be reached by thresholding one input.*

### 3.8 The freeze — the anti-leakage invariant

A day-D index is computed **once**, on the first evaluation pass where a `StoredSleepSummary` exists for the night ending on D **and** `now ≥ inBedEnd + settleMarginMinutes`, and written via `insertRiskDayIfAbsent`. It is **never** recomputed.

`settleMarginMinutes = 180` 🔴 PROVISIONAL — nights are known to re-stage 1–22 h after wake (project memory: *sleep-health-mirror-restage*); the daytime drain cadence is 1 h, so 3 h makes a complete-data verdict likely. **3 h does not cover 22 h**, so on any later pass where `StoredSleepSummary.updatedAt` has changed, the row sets `sleepRestaged = true` **and that row is excluded from the promotion denominator entirely** (architecture judge's fix — a Diagnostics-only flag was not enough; the gate must not be evaluated on scores the app itself considers stale).

Without the freeze, every self-reported precision is retro-fitted with today's fuller baseline and the unlock gate is meaningless. Regression-locked by `testRiskRowNeverRecomputed`.

### 3.9 Gates, in order (each returns early)

1. **Data gap** (grafted from *parity*, RingConn's one confirmed threshold): `now − UserDefaults[ReminderDefaults.lastRingDataAt] ≥ 24 h` 🟢 → `.interrupted(since:)`. No score. The named, legible way to say *"we stopped looking because you took the ring off"* instead of emitting a normal-looking day.
2. **Cold start:** `< RobustBaseline.minBaselineDays (7)` prior values → `.buildingBaseline(daysRemaining:)`.
3. **Coverage:** `< minRingFeaturesForScore (4)` ring features → `.insufficientData(reason)`, `index == nil`. Never 0.
4. **Anchor** (grafted from *signal*): at least one of `{sleepEfficiencyDrop, sleepFragmentation, sleepDurationDeviation, hrvDeviation, restingHRDeviation}` must be present. A day of only cycle + schedule + temp never synthesises a verdict.
5. **Fever suppression** (grafted from *parity*): if `VitalsBaseline.suspectedFever(restingHRToday:restingHRPrior:skinTempOffsetC:)` is true, the score is still computed and shown but `suppressedBy = .fever` and no notification candidate is produced. HRV↓ + RHR↑ + temp↑ **is** the fever signature; the existing `.fever` alert is the correct and more actionable one, and two interrupts for one physiological event devalues both.
6. **In-progress suppression:** if a `StoredHeadacheEntry` already exists whose onset is today, no candidate. Also an *evaluation* exclusion (§5.1).

### 3.10 Output

```swift
public enum Verdict: Equatable, Sendable {
    case notEnabled
    case buildingBaseline(daysRemaining: Int)
    case interrupted(since: Date?)
    case insufficientData(missing: [Feature: AbsentReason])
    case scored(Assessment)
}
public struct Assessment: Equatable, Sendable {
    public let day: Date
    public let index: Int                       // 0…100, a RELATIVE index on the user's own scale
    public let band: Band                       // .typical | .elevated | .flagged
    public let contributions: [Contribution]    // includes ABSENT features with their reason
    public let ringFeatureCount: Int
    public let coverageFraction: Double
    public let suppressedBy: Suppression?       // .fever | .headacheAlreadyLogged
}
public enum AbsentReason: String, Sendable {
    case noBaseline, noDataThisDay, featureDisabled, lowCoverage, notApplicable
}
```

`index` is **never** rendered as a probability, a percentage chance, or a risk. The detector writes **nothing** to Apple Health.

### 3.11 Failure modes and what suppresses them

| Failure | Suppressed by | Residual |
|---|---|---|
| Ring not worn / drain failed | `.interrupted` at 24 h; day excluded from BOTH evaluation terms | none |
| Buffer-truncated night reads as short sleep | `SleepCaptureCoverage` quality 0.5 | partial |
| Fever masquerading as prodrome | `suppressedBy: .fever` | none |
| Per-person sign inversion | unsigned \|z\| | **halves information; fires on the protective tail — stated in copy** |
| Artifact night (cold object, slipped ring) | median/MAD baseline + `zClamp = 4.0` + truncation gate | a single spectacular artifact can still reach `.elevated`, which never notifies |
| **Hangover / late night out** | **nothing — the signals are identical** | **accepted, named in the shipped copy** |
| Hard training day | nothing in v1 (§9 residualisation deferred) | accepted, named |
| Cycle phase alone driving a band | 35 % cap + excluded from the ring-feature minimum | none |
| Silent `.typical` from thin data | coverage line on EVERY `.typical` card, per-feature `AbsentReason` | none |
| Same-verdict re-fire every 2 h | per-DAY `yyyymmdd` ledger, not the 2 h backoff | none |
| Two concurrent `evaluate()` double-posting | inherited: `store.markFired` runs synchronously before `ensureAuthorized()` | none |
| Alert reaching someone already having the headache | `UNNotificationAction` reply + in-progress exclusion | reduced, not eliminated |

---

## 4. Data model

Two `@Model` types, **one** `SchemaV4` stage. Every non-optional column defaulted — the #21 rule: a new non-optional attribute with no default fails lightweight migration and traps at `ModelContainer` init on launch (black screen), and the foreground fallback **wipes 30 days of raw samples**.

### 4.1 `StoredHeadacheEntry` — the label (`ios/OpenCircuit/Store/HeadacheStore.swift`)

Column-for-column on `StoredPeriodEntry` (verified `CycleStore.swift:14-54`).

```swift
@Model final class StoredHeadacheEntry {
    @Attribute(.unique) var onset: Date = Date.distantPast
    var end: Date? = nil
    var severityRaw: Int = 0        // HKCategoryValueSeverity raw. 0 = .unspecified — NEVER default to .moderate
    var symptoms: [String] = []
    var customSymptoms: [String] = []
    var factors: [String] = []
    var notes: String = ""
    var sourceRaw: String = "user"  // "user" | "healthImport" | "periodLogImport"
    var importedHKUUID: String = "" // idempotency key for healthImport rows
    var healthWritten: Bool = false
    var hkSampleUUIDs: [String] = []
    var updatedAt: Date = Date()
}
```

### 4.2 `StoredHeadacheRisk` — the frozen daily verdict

```swift
@Model final class StoredHeadacheRisk {
    @Attribute(.unique) var day: Date = Date.distantPast   // startOfDay
    var index: Int = 0
    var bandRaw: String = "buildingBaseline"
    var ringFeatureCount: Int = 0
    var coverageFraction: Double = 0
    var contributionsJSON: String = "{}"   // [Feature.rawValue: contribution]
    var absentJSON: String = "{}"          // [Feature.rawValue: AbsentReason.rawValue]
    var computedAt: Date = Date()
    var sleepUpdatedAt: Date? = nil
    var sleepRestaged: Bool = false        // EXCLUDED from the promotion denominator
    var alerted: Bool = false
    var postUnlock: Bool = false           // promotion reads only postUnlock == false rows
    var updatedAt: Date = Date()
}
```

Kept forever — **not** added to `pruneExpiredSamples`. It is not re-derivable: raw `StoredSample` history prunes at 30 days (verified `LocalStore.swift:644,651`), so a score computed today could never be recomputed in 60. Both the 60-day percentile budget and the 365-day evaluation depend on the full series. Two flat JSON string columns instead of relationships so the feature set can evolve without another migration (unknown keys decode away).

### 4.3 Migration — four coupled edits, all in `App.swift`

1. `enum SchemaV4: VersionedSchema`, `versionIdentifier = Schema.Version(4, 0, 0)`, listing all **10** models (the 8 in `SchemaV3` at `App.swift:77-84` plus both new).
2. `MigrationPlan.schemas` += `SchemaV4.self` (line 85).
3. `MigrationPlan.stages` += `.lightweight(fromVersion: SchemaV3.self, toVersion: SchemaV4.self)`.
4. `makeSchemaAndConfig()`'s `Schema([...])` (lines 124-127) += both models. **Missing this one opens the container on a schema that does not contain the models.**

### 4.4 Wipe survival

`RollupBackup` gains `struct Headache: Codable` and `struct RiskDay: Codable`, plus `var headaches` / `var riskDays`. Both models join `exportBeforeWipe`'s limited `Schema([StoredSleepSummary, StoredDaily, StoredPeriodEntry, StoredNap])` (verified `App.swift:392`) and `restore(into:)`.

- `StoredHeadacheEntry` is user-ENTERED; HealthKit is not read back as truth. It is the most irreplaceable data in the app — the exact reason `StoredPeriodEntry` is already in that backup (`App.swift:352-355`).
- `StoredHeadacheRisk` losing itself silently resets the percentile budget **and the earned-trust evidence** to zero, which reads to the user as the feature breaking.
- `healthWritten` + `hkSampleUUIDs` round-trip so a restored entry isn't re-written and stays deletable in Health.

### 4.5 `LocalStore` extension (HealthKit-agnostic, exactly like `CycleStore`)

```swift
func saveHeadacheEntry(onset:end:severityRaw:symptoms:customSymptoms:factors:notes:originalOnset:) throws
@discardableResult func deleteHeadacheEntry(onset: Date) throws -> [String]  // returns stale HK UUIDs
func headacheEntries(from: Date, to: Date) throws -> [StoredHeadacheEntry]
func allHeadacheEntries() throws -> [StoredHeadacheEntry]
func pendingHeadacheEntries() throws -> [StoredHeadacheEntry]  // !healthWritten && sourceRaw != "healthImport"
func recordHeadacheEntryHK(onset: Date, hkSampleUUIDs: [String], finalized: Bool) throws
func insertRiskDayIfAbsent(_ row: RiskRow) throws -> Bool      // false when the day is already frozen
func markRiskRestaged(day: Date, sleepUpdatedAt: Date) throws
func markRiskAlerted(day: Date) throws
func riskDays(from: Date, to: Date) throws -> [StoredHeadacheRisk]
```

`healthWritten = false` is reset **only** on a clinically-relevant edit (`severityRaw` / `onset` / `end` / `symptoms`), never on a notes-or-factors-only edit — the `CycleStore.swift:111-123` rule. Delete returns UUIDs for the **view** to hand to HealthKit; the store layer stays HK-agnostic.

---

## 5. Evaluation and the unlock gate

`OpenCircuitKit/Sources/OpenCircuitKit/Analytics/HeadacheEvaluation.swift`

### 5.1 The outcome window — pinned before any claim, and genuinely prospective

The winning proposal credited *"a headache whose ONSET falls in calendar day D"* while scoring at `inBedEnd + 180 min`. That credits a 07:30 onset to a score that did not exist until ~10:00 — **retrodiction**, and it is the metric that opens the notification path. Fixed:

```
A frozen day-D row PREDICTS a headache iff that headache's onset ∈ (row.computedAt, row.computedAt + 24h].

A day is EXCLUDED from both the numerator and the denominator when:
  · no frozen row exists (ring not worn / drain failed / no sleep summary), OR
  · row.sleepRestaged == true (score computed on staging the app now considers stale), OR
  · a headache onset falls at or before row.computedAt ("already in progress" — unclassifiable;
    we did not predict it, and counting it either way is dishonest).
```

The in-progress exclusion directly closes the product judge's fatal flaw: those days are suppressed for notification **and** removed from the statistics. Pinned by `testInProgressHeadacheExcludedFromBothTerms` and `testOnsetBeforeComputedAtIsNeverCredited`. Changing this definition after seeing data is a change-control event, not a tweak.

### 5.2 Metrics

```swift
public struct Metrics: Equatable, Sendable {
    public let scoredDays, labelledDays, flaggedDays, truePositives: Int
    public let baseRate, precision, recall, lift: Double
    public let auc, aucCILow, aucCIHigh: Double
    public let pValue: Double
    public let alertsPerWeek: Double
    public let excludedInProgress, excludedRestaged, excludedUnscored: Int
}
```

- **AUC** — Mann-Whitney U over frozen indices, ties credited 0.5. `AUC = U / (nPos·nNeg)`.
- **CI** — Hanley–McNeil: `Q1 = A/(2−A)`, `Q2 = 2A²/(1+A)`, `SE = √([A(1−A) + (nPos−1)(Q1−A²) + (nNeg−1)(Q2−A²)] / (nPos·nNeg))`, `CI = A ± 1.96·SE` clamped to [0,1].
- **p** — deterministic permutation: shuffle labels `permutationCount = 2000` times with SplitMix64 seeded by `permutationSeed = 0x9E3779B97F4A7C15`, recompute TP, `p = (1 + #{permTP ≥ observedTP}) / (1 + 2000)`. Fixed seed ⇒ reproducible and unit-testable. Permutation ⇒ base-rate-free by construction (the null preserves the base rate), which is exactly why it works for chronic sufferers.

### 5.3 The unlock gate

```
Readiness.ready requires ALL of:
  scoredDays   >= 120                              🔴 PROVISIONAL (see §1.1 power calc)
  labelledDays >= 8                                🟢 the floor at which p <= 0.01 is reachable at all
  aucCILow     >  0.50                             🟢 grafted from signal — gate on the BOUND, not the estimate
  pValue       <= 0.01                             🟢 tightened from 0.05 for multiplicity (§5.4)
  median ringFeatureCount >= 4 over the window     🔴 PROVISIONAL
```

**Deleted: `promotePrecision = 0.30` and `promoteLift = 2.0` as gates.** They stay as *displayed* quantities. Reasons, both verified:
- The precision floor is **non-binding**: at the gate minimum, the permutation already demands precision ≈ 0.50.
- The lift floor is **arithmetically broken at high base rates**: at a 0.5 base rate, `lift ≥ 2.0` demands precision ≥ 1.0 (unattainable) while `precision ≥ 0.30` is *worse than chance* yet passes its own floor. A chronic-migraine user — the person with most to gain — could never unlock, and the UI would never explain why.

**Why the CI bound matters (the fatal flaw in *signal*):** gating on the AUC point estimate at ≥0.60 with 12 positives / 78 negatives gives SE = 0.090 under the null, so 0.60 is `z = 1.11`, `p = 0.133` — roughly **13 % of users with a worthless detector unlock on a single look**, and *signal* recomputes continuously. Its own worked UI string (`AUC 0.62 (95% CI 0.48–0.76) … close to chance`) **unlocks** under its own gate. Gating on `aucCILow > 0.50` turns the same computation into an actual test.

### 5.4 Multiple testing — quantified, not merely acknowledged

All three proposals re-test on an accumulating window at every sync, forever. Run daily for a year and a false unlock is near-certain. Fix:

- `Metrics` are recomputed on every refresh **for display**.
- The **unlock decision** is taken at most once per `decisionIntervalDays = 28` 🔴 PROVISIONAL.
- Unlock requires the full conjunction on **two consecutive** decisions (`requiredConsecutivePasses = 2` 🔴 PROVISIONAL).
- `α = 0.01` per decision.
- `lookCount` is **persisted and displayed** in the detail screen.

Family size over a year is ~13 decisions. Two consecutive passes at α = 0.01, plus the independent `aucCILow > 0.50` requirement (~2.5 % one-tailed under the null), gives a defensible family-wise rate. **Residual, stated in the source comment:** the windows overlap so consecutive decisions are correlated; this is a large improvement, not a proof.

### 5.5 Demotion, with hysteresis and an auto-relock

```
At any decision point after unlock, if aucCILow <= 0.50 OR precision < 0.20 over the trailing
365 days, notifications AUTO-RELOCK and the card says why:
  "We've stopped sending headache alerts — over your last N logged headaches, flagged mornings
   stopped beating your normal rate."
```

`demoteConsecutiveDecisions = 1` — relock is fast, unlock is slow. The asymmetry is deliberate. Framing grafted from *parity*: *"a detector that silently degrades is worse than one that never fired."*

### 5.6 Anti-nocebo split

Promotion reads **only** rows with `postUnlock == false`, frozen at `promotedOnDayKey`. Post-unlock rows feed demotion and are displayed as a separate "since alerts" column. Without this, an alert that makes the user anticipate and log a headache inflates the precision that justified it.

---

## 6. UI

### 6.1 The card never says "headache risk" before unlock

**Ruling (product judge's mustFix, adopted).** A passive card is not safe just because the push is locked. From day 21 all three proposals render a headache-framed band to a user for whom nothing has been validated and who may never get headaches — a permanent ~10 %-of-days anxiety generator with a 100 % false-positive rate.

The Today card is titled **"Overnight signals"**:

| Verdict | Copy |
|---|---|
| `.buildingBaseline(n)` | "Building your baseline — n more nights." + "Log a headache" |
| `.interrupted` | "No ring data for over 24 hours, so last night wasn't assessed." |
| `.insufficientData` | "No sleep data for last night, so today's signals can't be assessed." — never a number |
| `.typical` | "Nothing unusual for you last night." **+ a coverage line: "Measured 6 of 8 signals."** (grafted from *signal* — bare reassurance is the dangerous failure) |
| `.elevated` / `.flagged` | "Last night was unusual for you" + top two contributions with **real numbers and units**: "Sleep efficiency 82 % — 2.1 below your usual", "Resting HR 61 bpm — +6" |

Band chips use **shape-distinct glyphs** (● ▲ ◆) as well as colour, with explicit `.accessibilityLabel` — the `CycleCalendarView.dayState` house standard so states read in greyscale and under colour filters. No score, no percentage, no "chance" on the card, ever.

The word *headache* appears on the card **only** on the "Log a headache" button, and in the band label **only after unlock**.

**0x8BADF00D-safe pattern is mandatory** (`VitalsStatusCardView.swift:101-134`): bounded `FetchDescriptor` in `init()`, `.task(id:)` snapshots SwiftData rows to `Sendable` tuples on the main actor, then `await Task.detached { HeadacheSignals.assess(...) }.value` into `@State`. Doing this inline in `body` has already caused a shipped watchdog crash.

### 6.2 Detail screen — `HeadacheSignalsView`

1. **Today's signals** — all nine features as rows: name, today's real value, deviation vs baseline, weight; or an explicit reason for absence: *"Skin temperature — no reading last night, the ring was disconnected."* (grafted from *signal*). The relative index appears **here only**, labelled *"a relative index on your own scale (0–100) — not a probability."*
2. **"Is this working for you?"** — the panel no vendor ships:
   - `.insufficientDays` → "38 of 120 days scored. Keep wearing the ring."
   - `.insufficientLabels` → "3 of 8 headaches logged. Log every headache, including mild ones — that's what makes this measurable."
   - `.notBetterThanChance` → *"Measured on your last 365 days: 4 of your 22 flagged mornings (18 %) were followed by a headache within 24 hours. An average day for you is 13 %. AUC 0.56 (95 % CI 0.47–0.65) — that includes chance, so alerts stay off. (Checked 5 times.)"*
   - `.ready` → the same numbers plus one **"Turn on morning alerts"** button. Never auto-enabled.
   - Post-unlock: two columns, **Before alerts** / **Since alerts**.
3. **History** — logged headaches grouped by month, each row showing that day's frozen index and band so the user can audit the correlation themselves.
4. **Disclaimer footer**, `.caption2`/`.tertiary`, in the `CycleCalendarView.swift:452-457` house style:
   > "Headache signals are a statistical estimate computed on your device from your own 7–60 day baseline. We measure how *unusual* a night was for you, in either direction — not how bad it was. OpenCircuit is not a medical device and this is not a diagnosis or a prediction. Most flagged days do not become headaches. A hangover, a hard workout and a headache prodrome look the same to a ring. If your headaches are new, worsening, or severe, consult a qualified healthcare professional."

That hangover sentence is deliberate, grafted from *signal*'s honesty about a false-positive class nothing can suppress.

### 6.3 Log sheet — `HeadacheLogSheet`

`NavigationStack` + `Form` on the `PeriodLogSheet` template (`CycleCalendarView.swift:462-577`): **When** (DatePicker onset, optional end) / **Severity** (segmented `Picker`: Unspecified / Mild / Moderate / Severe, **defaulting to Unspecified** — a real choice, not a placeholder) / **Symptoms** (multi-select + custom entry) / **Possible triggers** (multi-select) / **Notes**, `.cancellationAction` + `.confirmationAction`, save-error `Section`.

Symptom catalog 🟡 (inferred from APK i18n keys — the Dart string pool is hash-ordered so key↔English pairing cannot be proven mechanically; tagged 🟡 in source, user-facing labels only, no protocol claim): Nausea, Vomiting, Dizziness, Blurred vision, Light or sound sensitivity, Tinnitus, Neck pain, Nasal congestion, Weakness, Fatigue, Anxiety, Insomnia, + custom.

Trigger catalog 🟡: Alcohol, Caffeine, Lack of sleep, Insomnia, Sleep interruption, Intense exercise, Excessive fatigue, Stress or anxiety, Emotional tension, Loud noise, Strong odours, Hot bath or shower, Weather changes, Skipped meal.

### 6.4 Reducing the logging burden — the thesis depends on it

The design needs ≥8 labels then complete logging for a year. A Form buried behind a card tap will not get it; paid diary studies manage 70–85 % adherence.

- **`UNNotificationAction`s on the headache notification** (Phase 3): *"I have a headache"* / *"No headache"*. `UNNotificationCategory(identifier: "alerts.health.headache", ...)` registered in `AppDelegate` beside the existing delegate assignment (line 16), handled in a new `userNotificationCenter(_:didReceive:)`. Highest-yield fix available, and it simultaneously defuses the mid-attack case in one tap.
- **"Log yesterday" row** on the card the morning after any `.flagged` day.
- **AppIntent + Lock Screen control** for one-tap logging.
- **Never** a daily push asking "did you have a headache?" — a nocebo vector and an alert-budget spend.

### 6.5 Settings — `UserProfile.swift`, new `Section("Headache signals")` after "Women's health"

- `Toggle("Show headache signals", isOn: $headacheEnabled)` — key via `HeadacheDefaults.enabled`, default **false**.
- **Read-only** status row showing PROGRESS, never a dead toggle (grafted from *parity*): *"Morning alerts: off — 38 of 120 days scored, 3 of 8 headaches logged."* Once `.ready` it becomes a live disable-only `Toggle`; the only route to **on** is the evaluated unlock in the detail screen.
- The verbatim shipped disclaimer paragraph already in `Section("Health alerts")` (`UserProfile.swift:414-418`).
- Every toggle calls `escalateNotifAuth(enabled:)` on change, matching the four existing alert toggles.

**Key-drift fix:** `HeadacheDefaults` holds every `@AppStorage` key as a shared constant referenced by both `ContentView` and `UserProfile`. `userProfile.womensHealthEnabled` is currently hardcoded verbatim in **two** files (`ContentView.swift:41`, `UserProfile.swift:89`) — that hazard is not repeated.

### 6.6 Graceful exit

After 90 days enabled with **zero** logged headaches, the card says so once and offers *"Turn this off"* — and stops showing bands. A user who never gets headaches must have an off-ramp.

---

## 7. HealthKit — the exact auth-set change and the #129 handling

### 7.1 The one line

In `HealthKitWriter.allTypes` (verified `HealthKitWriter.swift:78-106`), immediately after the `.menstrualFlow` insert at line 94:

```swift
// Headache log: a plain third-party-WRITABLE category type (SDK HKTypeIdentifiers.h:235,
// iOS 13.6+, valued by HKCategoryValueSeverity) — the same class as .menstrualFlow above.
// It is NOT a correlation type and NOT an Apple-computed type, so it does not reproduce the
// #121/#128 uncatchable NSInvalidArgumentException described below.
set.insert(HKCategoryType(.headache))
```

**Why safe by the codebase's own rule (N10):** the crash class is specific to (a) `HKCorrelationType`, not authorizable, and (b) Apple-COMPUTED types (`.appleExerciseTime`, `.appleSleepingWristTemperature`). `.headache` is neither. `testAuthTypeSetContainsNoCorrelationTypes` keeps passing and gains a positive assertion that `.headache` **is** present.

**Do NOT add a `MetricKind` case.** `quantityType(for:)` is exhaustively switched over `MetricKind` and returns `HKQuantityType`; a category type has no home there. Accepted cost: headache cannot appear in the `MetricKind`-keyed `hk.failures.byMetric` map — the identical blind spot `.menstrualFlow` already has. Mitigated by a dedicated `FlushResult.headacheEntries` counter and a Diagnostics line.

### 7.2 `friendlyName` — NOT optional

`friendlyName(for:)` ends with `return type.identifier` (verified, line 168). Without a case, the #132 partial-grant banner and the #135 write-failure copy render **"HKCategoryTypeIdentifierHeadache"** to users:

```swift
if type.isEqual(HKCategoryType(.headache)) { return "Headache" }
```

### 7.3 The `.partial` share-state regression — named and planned

`resolveShareState` (verified lines 147-152) filters `allTypes` for `.sharingDenied`. So **any existing user who declines the new headache type flips from `.authorized` to `.partial`** and newly sees the #132 banner on an install that has never shown one. Correct behaviour, but a visible change that must be eyeballed on a real decline before merge.

### 7.4 #129 — the re-prompt is automatic; do NOT invent a version counter

`authorizationPromptAvailable()` calls `statusForAuthorizationRequest(toShare: allTypes, read:)`, which flips to `.shouldRequest` the moment the set grows. `ContentView.reconcileNewlyAuthorizableShareTypes()` (verified `ContentView.swift:654`, called from the foreground `.task` at `:187`) then re-runs `requestAuthorization()` so iOS prompts for **just the new type**, and is self-limiting because answering determines the type. The change-control skill's note that #129 is "still OPEN" is **stale** — commit `b881858` is in tree.

A hand-rolled `healthTypesVersion` key would double-prompt. **Do not add one.**

**BLOCKING device gate:** that path has **no recorded device validation anywhere in the repo**, and adding `.headache` is precisely the change that exercises it on every existing install. An over-the-top upgrade install onto an existing Health grant, confirming the sheet appears for the new type only and that revoke-Health-then-relaunch does not crash, is a **merge gate**. This is the same auth path that produced #110, #121 and #128.

### 7.5 Write path

```swift
// PURE static seam — internal for the app-target test. HealthKitWriter builds a live
// HKHealthStore, so anything that saves cannot be unit-tested; the simulator reports every
// type .notDetermined.
static func headacheSamples(onset: Date, end: Date?, severityRaw: Int) -> [HKCategorySample]
```

Exactly one sample: `start: onset`, `end: max(end ?? onset, onset)` clamped to `now`, `value: HKCategoryValueSeverity(rawValue: severityRaw)?.rawValue ?? HKCategoryValueSeverity.unspecified.rawValue`. Returns `[]` on invalid input rather than throwing.

Severity mapping (verified against the installed SDK, `HKCategoryValues.h:206-215` — note `unspecified` is **0**, not `notPresent`): `0 .unspecified · 1 .notPresent · 2 .mild · 3 .moderate · 4 .severe`. Out-of-range clamps to `.unspecified`. **Never** default to `.moderate` — `menstrualFlowSamples` defaults flow to medium, acceptable for flow and **fabricating a clinical grade** for pain.

**Metadata: `[HKMetadataKeyWasUserEntered: true]` only.** Unlike `.menstrualFlow` there is no *required* key. If one is ever added it must go on **every** sample — a key present on sample 1 and missing on sample 2 raises an uncatchable Obj-C exception during construction, which caused the build 17–22 TestFlight crash loop.

`flushHeadacheLog(localStore:)`, called from `flushToHealth` beside `flushMenstrualFlow`, inside the existing static `isFlushing` guard:
1. `guard store.authorizationStatus(for: HKCategoryType(.headache)) != .sharingDenied else { return 0 }` — explicit denial is terminal for the pass (no forever churn); `.notDetermined` falls through and retries so the log backfills on the first flush after granting. **Never** gate on `isShareAuthorized` — it probes heart rate only (lines 112-115) and returns true while headache is denied.
2. **WRITE FIRST, then delete prior UUIDs** — the sleep path's documented no-data-loss ordering (lines 1381-1383). Deliberately diverges from `flushMenstrualFlow`'s delete-first: a single-sample entry deleted-then-failed-to-write leaves a real hole.
3. `recordHeadacheEntryHK(onset:hkSampleUUIDs: samples.map { $0.uuid.uuidString }, finalized: true)`; `catch { break }` so unwritten rows retry.

`FlushResult` gains `var headacheEntries = 0` **and it must be added to `wroteAnything`** (verified: that property enumerates every counter explicitly at lines 218-222, so a headache-only flush would otherwise read as idle).

`deleteHeadacheSamples(uuidStrings:)` — UUID- and type-scoped, best-effort; called from the **view** after `deleteHeadacheEntry` returns the stale UUIDs.

### 7.6 Read path — the cold-start accelerator (grafted from *parity*, in *signal*'s form)

`readHeadacheSamples(since:)` via `HKSampleQuery` on `HKCategoryType(.headache)`. No new permission needed: `requestAuthorization()` already builds `read` as every non-workout/non-series member of `allTypes` (lines 578-601).

- Skips samples whose `sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier` (no write/read loop).
- Skips UUIDs already in `importedHKUUID` or `hkSampleUUIDs`.
- Imported rows land `sourceRaw = "healthImport"`, `healthWritten = true`.
- **Re-read on every evaluation, never cached as truth** (*signal*'s formulation), so a sample deleted in Health immediately un-learns.
- **The imported count is shown**: *"Imported 43 headaches from Apple Health"* / *"Found none."* This defeats the winning proposal's objection (an empty import being indistinguishable from no headaches) and is the best cold-start accelerator available — a Migraine Buddy or official-RingConn user can reach `.ready` in months instead of a year.

**Imported-label provenance guard:** batch-entered retrospective logs destroy day alignment. Exclude samples whose creation time is implausibly distant from the stated onset, and report `Metrics` separately for native vs imported labels.

### 7.7 The `PeriodSymptom.headache` collision — resolved explicitly

`PeriodSymptom.headache = "Headache"` already exists as a free-text tag in `StoredPeriodEntry.symptoms` (verified `CycleCalendarView.swift:19`) and is **not** mirrored to Health. It stays as it is. It is **never** auto-converted — doing both would double-write a headache to Health on days carrying a period tag and a log entry. Instead a one-time prompt offers *"You've tagged headaches on N period logs. Import them as headache entries?"* creating real editable rows with `sourceRaw = "periodLogImport"`. Regression test: `testMenstrualFlowSamplesNeverEmitHeadacheType`.

---

## 8. Background — nothing new is declared

**No new background mode. No new BGTask identifier. No timer. No scheduled notification.** `UIBackgroundModes` stays `[bluetooth-central, location, fetch, processing]`, and `location` is **not** touched — `docs/BACKGROUND_SYNC.md` B.2 fences it to workout GPS and repurposing it as a residency trick is forbidden.

`HeadacheEngine.refreshToday(store:)` runs **immediately before** the existing `HealthNotificationCenter().evaluate(store:session:)` at all five sites, so the alert pass reads today's fresh frozen row instead of lagging a sync:

| Site | File:line |
|---|---|
| 0x11-wake / primary all-day delivery | `RingSession.swift:2764` |
| BGTask handler (both ids) | `AppDelegate.swift:146` |
| Scene-active | `ContentView.swift:717` |
| Sync-completion edge | `ContentView.swift:226-236` |
| Sleep Focus-off falling edge | `SleepFocusSyncFilter.swift:118` |

**Idempotence is structural, not aspirational.** `insertRiskDayIfAbsent` is a no-op once the day is frozen; the per-day notification ledger is a no-op once the day is alerted. The evaluator is polled with a 12 h lookback several times an hour and must tolerate it.

**Do NOT add a device-timestamp "freshness" window.** That mistake is documented at `HealthAlerts.swift:166-170` as permanently silencing the older half of every background drain.

**Cost control:** the expensive input is the 30-day heart-rate fetch feeding `RestingHR.dailyValues`. `HealthNotificationCenter.suspectedFever` **already** performs exactly that fetch on every pass. Grafted from *parity*: refactor it into `restingHRDailySeries(store:) -> [RestingHR.DailyValue]` with the fever and headache paths as two consumers of **one** fetch. `StoredSample` has no index on `start`, so this is not a nicety.

**Timing.** The verdict is gated on `inBedEnd + 180 min`. Overnight the drain is deliberately suppressed (`HistoryDrainCadence.shouldDrain`), so nothing evaluates between bedtime and the morning drain — correct, and it means a headache alert can never wake someone at 03:00. After wake, drains land every ~6–10 min while worn and connected, so the verdict reaches the user within minutes of the settle margin.

**Quiet hours cannot be relied on as overnight protection.** (As of build 42 `HealthAlertDefaults` registers `quietEnabled: true`, 22:00–07:00 — but that is a user PREFERENCE they may switch off, and `QuietHours.init(enabled: false)` still defaults off for any caller constructing one directly. Through build 41 it was registered `false`, so there was no overnight protection at all.) All three proposals leaned on quiet hours as overnight protection and none noticed. So `.headacheSigns` gets a **hard never-fire window independent of the user's toggle**: `headacheEarliestMinutes = 7*60`, `headacheLatestMinutes = 21*60` 🔴 PROVISIONAL, enforced in the pure layer.

---

## 9. Notification wiring

`HealthAlerts.swift`:

```swift
// APPEND at the very END of HealthNotification, after .chargingComplete.
// NotificationGate.filter returns survivors in allCases DECLARATION ORDER (line 93), so
// appending leaves the relative order of every existing pair byte-identical; inserting would
// silently reorder shipped notification delivery. The String rawValue keeps the persisted
// alerts.health.lastFired / lastNight dictionaries valid.
case headacheSigns = "headache.signs"

public enum HeadacheSignsNotifications {
    public static let notificationSet: Set<HealthNotification> = [.headacheSigns]
    /// Forwards to TempFeverNotifications.dayKey — ONE source of truth for the timezone-stable
    /// yyyymmdd math, a SEPARATE set for membership so the temp night ledger and the temp
    /// disclaimer branch cannot be widened by accident.
    public static func dayKey(for day: Date, calendar: Calendar = .current) -> Int
    public static func freshForDay(_ candidates: [HealthNotification], day: Int,
                                   lastNotifiedDay: [HealthNotification: Int]) -> [HealthNotification]
}
```

`HealthNotificationCenter.swift`:
- **The persistence API is `store.lastNotifiedNight()` and `store.markNight(_:night:)`** (verified lines 145-164, backed by `alerts.health.lastNight`, keyed by `rawValue`, so there is no collision with the temp family and no second map is needed). *The winning proposal invented `store.lastNotifiedDay()`, which does not exist.*
- Candidate produced only when `enabled && unlocked && band == .flagged && suppressedBy == nil` and the never-fire window allows it.
- `store.markNight(fire.filter(Self.isHeadache), night: headacheDayKey)` after `ensureAuthorized()` — the day ledger has no time-based self-heal, so it must be claimed only after a successful post.
- `appendsDisclaimer` gains `case .headacheSigns: return true`. `copy(for:hit:)` gains the body. **Both switches are exhaustive with no `default`** (lines 498-499), so the compiler forces both decisions.

**Copy** (quotes the user's own measured numbers, leads with the base rate):
> **title:** "Unusual pattern this morning"
> **body:** "Several of your signals are outside your usual range — mainly {top1} and {top2}. On your own log, mornings like this were followed by a headache {precision}% of the time, versus {baseRate}% on an average day. Most flagged mornings do not become headaches (estimate)."
> + `"\n\n"` + the verbatim shipped `HealthNotificationCenter.disclaimer`.

Pinned by `testNotificationCopyContainsNoPredictionLanguage`: body must contain "estimate", must **not** contain "will", "predict", or "diagnos".

**Deferred to a post-validation phase:** per-user sign learning and weight shrinkage. *signal*'s version is a fatal flaw — point-biserial at `n ≥ 10, |r| ≥ 0.25` across 8 domains, uncorrected, gives ~42 % chance of at least one spurious flip per user (at n = 56 the null SE of r is ~0.135, so |r| = 0.25 is p ≈ 0.063 per domain), and an inverted sign makes the detector *worse* than the prior it replaced. If added later it needs family-wise correction: |r| ≳ 0.37 at n = 56, ≳ 0.29 at n = 90. Load-residualisation of the autonomic features on prior-day activity is the other deferred item.

---

## 10. Phasing — each phase independently shippable and independently valuable

### Phase 1 — "Headache log" (~900 lines). **Ships honestly with zero ground-truth data.**

`StoredHeadacheEntry` + `StoredHeadacheRisk` + SchemaV4 (both models in one migration — additive, defaulted, one device gate) + rollup backup; `HKCategoryType(.headache)` in `allTypes` + `friendlyName` + flush + pure sample builder + the Apple Health import; the log sheet; a card that is only "Log a headache" + this month's count; the settings toggle; HealthKit tests.

**Makes zero predictive claim.** If the detector never earns its way on, Phase 1 is still a good feature — HealthKit-backed headache tracking with import from any other app, on a local-first ring client.

**Device gates (blocking):** (a) over-the-top upgrade install confirming the #129 sheet appears for the new type only; (b) revoke-Health-then-relaunch does not crash; (c) declining `.headache` shows the #132 banner reading "Headache", not the raw identifier; (d) one written sample visible in Health ▸ Browse ▸ Symptoms ▸ Headache with OpenCircuit as source, both zero-length and interval forms accepted.

### Phase 2 — "Signals" (~1,100 lines). No alert case exists yet.

`RobustBaseline`, `HeadacheSignals`, `HeadacheEngine` wired into all five evaluate sites, the frozen-row invariant, the neutral "Overnight signals" card, the detail screen's signals + history sections, the Diagnostics section, Kit tests.

**Blocking pre-ship measurement (this is what makes Phase 2 shippable rather than speculative):** replay the scorer over the maintainer's existing `default.store` / Diagnostics archive and measure **per-feature presence rates** over the last 60 days. This settles three open questions with data:
- How many nights actually have `StoredSleepSummary.skinTempC > 0`? The repo contradicts itself — `HistoryDrainCadence.swift` says the `0xD0` statusQuery keepalive eliminates overnight temp; `RingSession.swift:3615` says descriptors arrive unsolicited every ~2.5 min.
- How often does all-day-channel starvation kill `arousalLetdown`? One tester's 0x03 channel `noAck`'d 27 of 32 attempts.
- What fraction of days clear `minRingFeaturesForScore`?

**If <50 % of days clear the minimum, the weight set is wrong and must be re-scoped before shipping, not after.**

### Phase 3 — "Earn the alert" (~800 lines).

`HeadacheEvaluation` + the permutation test + Hanley–McNeil, the self-evaluation panel and unlock flow, `HealthNotification.headacheSigns` + `HeadacheSignsNotifications` + the two exhaustive-switch cases + the per-day ledger, the decision cadence / consecutive-pass / relock machinery, the notification actions and AppIntent logging, the falsification test suite, `desktop/headache_backtest.py`.

**Blocking gate:** `testRandomLabelsNeverPromote` must show that under simulated daily re-evaluation with labels shuffled independently of the index, the realised false-promotion rate over a simulated year is ≤ 5 %. *If noise can pass the gate, the gate is worthless and Phase 3 does not ship.*

### Phase 4 — Barometer, conditional. **Cut from v1.**

All three proposals weight pressure 0.04–0.10 and all three concede it cannot change a verdict (pooled OR 1.07 across 31 studies; "generally null" in the best individual-level prospective study, Li 2019, 4406 days). Against that it costs: a new framework, a **new Motion & Fitness system prompt on a privacy-positioned app** (usage-description surface 4 → 5 keys), a `project.yml` entry (XcodeGen regenerates `Info.plist`, so a hand edit is stripped, and without the key the first `CMAltimeter` call **crashes**), elevation de-contamination maths, a new archive, and a watchdog papering over an **unverified** CoreMotion suspend/resume behaviour.

If built, the design is *signal*'s (the only genuinely correct novel physics in the set) and it ships **weight-0 first**:
1. `BarometerSampler` ships contributing nothing, sampling on `RingSession.maybeDrainOnBackgroundWake` — one line, as the **first statement before** the `guard UIApplication.shared.applicationState != .active` at `RingSession.swift:1079` (verified: that single site is reached from both the `0x10/0x87` descriptor branch and the `0x11` branch, and covers foreground too). Read **only** `CMAltitudeData.pressure` (kPa ×10 = hPa); `relativeAltitude` is zero on the first event after each start and is meaningless across short wakes.
2. Persist to a UserDefaults archive on the `EpochArchive` / `EpochArchiveStore` precedent — **never** SwiftData (highest write rate in the feature; SwiftData is the one store the foreground migration-failure path wipes, and *parity*'s `pressureRetentionDays = 35` would additionally change the shipped `pruneExpiredSamples(olderThan:)` signature, verified `LocalStore.swift:651`).
3. 48-hour device soak; read the samples-per-hour histogram and the watchdog restart count out of Diagnostics.
4. **Gate:** promote to weight 0.08 only if ≥8 in-bed samples land on ≥70 % of nights. Otherwise delete the feature.

Elevation defence if promoted: night-median anchor (the user is stationary at one elevation for hours, so a night-over-night delta cancels elevation exactly) **plus** 30-min bucket rejection at `elevationSuspectRangeHPa = 1.5` 🟢 (≈12.5 m at 0.120 hPa/m), volatility as **IQR of surviving bucket medians**, never min−max.

---

## 11. Test plan

**CLI-testable without HealthKit or CoreBluetooth (the Kit suite, `swift test`):** everything statistical. Header on every new file: `SYNTHETIC-ONLY — no real health values`. Float asserts at `accuracy: 1e-9`.

### No-regression / byte-identical
- `testHealthNotificationAllCasesPrefixUnchanged` — `Array(HealthNotification.allCases.prefix(12)).map(\.rawValue)` equals the exact existing twelve, in order. Appending is safe; inserting fails.
- `testExistingAlertFamiliesUnchanged` — rebuild the current `HealthAlertsTests` fixtures; `NotificationGate.filter` returns identical arrays in identical order.
- `testTempFeverLedgerUnaffected` — mark a headache day in `alerts.health.lastNight`; `TempFeverNotifications.freshForNight` returns exactly what it did before.
- `testTempFeverNotificationSetUnwidened` — still exactly the five temp/fever cases.
- **Structural guarantee:** no parameter is added to `VitalsBaseline.Config`, `SkinTempBaseline`, `SleepStaging.Tuning`, `TrendsEngine` or `HealthAlertThresholds`. `VitalsBaselineTests`, `SkinTempBaselineTests` and `SleepStagingTests` must pass **unmodified** — they ARE the byte-identical proof.
- `testHeadacheDisabledLeavesEvaluateByteIdentical` — with the default-off flag, `evaluate` produces the same candidates and the same `lastFired`/`lastNight` writes.

### The detector
- `testOrdinaryDayScoresZero` — every feature within 1 MAD-unit ⇒ index exactly 0.
- `testMissingInputsAreAbsentNotZero` — nil HRV reduces the **denominator**: assert `index({eff=1.0, hrv=nil}) == 100·0.18/0.86`, not `/1.00`.
- `testBelowMinRingFeaturesReturnsNil`.
- **`testNoSingleFeatureExceedsCapAtMinimumFeatureCount`** — every 4-subset **including perimenstrual**; `max(w)/Σw ≤ 0.35` after the cap.
- `testPerimenstrualDoesNotCountTowardRingMinimum`.
- `testUnsignedDeviationIsSymmetric`; `testSaturationClamps`; `testZeroMADIsAbsentNotInfinite`.
- `testArtifactDayShiftsBaselineLessThanOneNoiseFloor` — makes the MAD-vs-SD justification falsifiable rather than asserted.
- `testTruncatedNightHalvesSleepWeight`; `testBandingRequires21PriorDays`.
- `testHighBandRateIsBoundedByPercentile` — 365 synthetic days ⇒ `.flagged` ≤ 11 % ⇒ ≤ 0.8 alerts/week (the false-alarm-budget contract).
- `testFlaggedRequiresThreeContributingFeatures` — one feature at 1.0 and all others at 0 can never reach `.flagged`.
- `testLetdownUsesOnlyDMinus1AndDMinus2` (no look-ahead); `testFeverSuppressesCandidateNotScore`; `test25HourGapYieldsInterrupted`; `testAnchorRuleRejectsCycleOnlyDay`; `testIdempotent`.

### The gate (the most important file)
- **`testRandomLabelsNeverPromote`** — 200 seeded trials, 365 days, labels shuffled independently of the index, **simulated daily re-evaluation with the 28-day decision cadence**; realised false-promotion rate ≤ 5 %. If noise passes, the feature does not ship.
- `testPerfectlyCorrelatedLabelsPromote` — positive control, so the gate isn't merely impossible.
- `testPValueIsDeterministic`; `testAUCKnownAnswers` (1.0 / 0.5 / 0.0 / all-ties / one hand-computed 5×5); `testHanleyMcNeilCIWidthShrinksWithN` and stays in [0,1].
- `testGateUsesCILowerBoundNotPointEstimate` — AUC 0.62 with CI [0.48, 0.76] does **not** promote.
- `testEachCriterionAloneBlocks`.
- **`testOnsetBeforeComputedAtIsNeverCredited`** and **`testInProgressHeadacheExcludedFromBothTerms`**.
- `testUnscoredAndRestagedDaysExcludedFromBothTerms`; `testPromotionUsesPreUnlockRowsOnly`; `testTwoConsecutiveDecisionsRequired`; `testRelockOnDegradation`; `testChronicUserAtHalfBaseRateCanStillPromote`.

### App target (`ios/OpenCircuitTests/`) — runs only under the OpenCircuit scheme's test action; **not in preflight**, so a device build plus adversarial review remains the real gate
- `testHeadacheIsInAuthSetAndNoCorrelationTypes`; `testFriendlyNameForHeadache` returns "Headache".
- `testHeadacheSeverityMapping` (all five raws + out-of-range clamping to `.unspecified`, **never** `.moderate`).
- `testHeadacheSampleZeroLengthAndInterval`; invalid input yields `[]`.
- `testFlushResultCountsHeadacheAsWroteAnything`; `testMenstrualFlowSamplesNeverEmitHeadacheType`.
- `testNotesOnlyEditDoesNotResetHealthWritten` / `testSeverityEditDoes`; `testOnsetMoveCarriesHKUUIDs`.
- **`testRiskRowNeverRecomputed`** — score a day, mutate the underlying `StoredSleepSummary`, refresh; `index` and `computedAt` unchanged, `sleepRestaged == true`. Without this the whole evaluation is leaky.
- `testV3StoreOpensUnderV4Lightweight` — guards the black-screen `ModelContainer` trap.
- `testRollupBackupRoundTripsHeadacheRows` and decodes an older backup written without the new arrays.

### Diagnostics (privacy-constrained)
New `# Headache signals` section in `DiagnosticsReport.build`: enabled/unlocked/`promotedOnDayKey`/`lookCount`; the last 14 frozen rows (day, index, band, `ringFeatureCount`, absent-feature reasons, restaged, alerted); **per-feature presence rate** over the window; current `Metrics` + `Readiness`; **headache-log COUNT ONLY — never notes, symptoms, or severities** (the export is a file testers send to the maintainer; the winning proposal is the only one that noticed, and it is right); `nights with skinTempC > 0 / 14`.

The export is hand-assembled, so a detector whose inputs are absent from it is undebuggable remotely — and this one section settles three of the design's open empirical questions from a single tester export.

---

## 12. Validation and ground truth

**Tier 0 — the prior is documented in code.** The §1 arithmetic is reproduced in the `HeadacheSignals.swift` header. Every UI string is written to those numbers.

**Tier 1 — synthetic tests** prove the machine does what it says. They prove **correctness, not skill**, and the test-file headers say so.

**Tier 2 — real-data replay (blocking before Phase 2 ships).** Per-feature presence rates over the maintainer's existing archive (§10, Phase 2).

**Tier 3 — per-user on-device self-validation.** The gate ships and is visible. A user for whom the detector performs at chance can never be interrupted by it, and is told so in plain numbers. A feature able to openly report its own failure is the only honest form this can take.

**Tier 4 — external claims bar (grafted from *signal*, adopted as a rule).** No accuracy number, no "predicts", and no headache claim in the README, App Store copy, or release notes until **≥3 testers each with ≥50 labelled days AND a pooled leave-one-subject-out AUC > 0.60 with a CI excluding 0.50**. Until then the external description is *"surfaces unusual patterns in your own data"* — a claim about our arithmetic, not about headaches. Even RingConn's own marketing on this exact feature refuses to state an accuracy number; we will not be less careful than the vendor we are replicating.

**Tier 5 — cross-user evaluation without a cloud.** `desktop/headache_backtest.py` (mirroring `desktop/ringconn_sleep_fit.py`, `--synthetic` for a runnable demo) replays a Diagnostics export plus an exported log and emits an ROC, per-feature point-biserial correlations, and a calibration table. Testers who choose to send an export let us compute the distribution of `Readiness` outcomes across users with zero network and zero health-content disclosure.

**Retiring the 🔴 PROVISIONALs.** `onsetZ`, `zClamp`, `minRingFeaturesForScore`, `maxSingleFeatureShare`, `minDaysForBanding`, `bandWindowDays`, the two percentiles and `settleMarginMinutes` are all calibrated by the same artefact: the Tier-2 replay plus the per-feature presence rates in Diagnostics. `sleepFragmentation` / `sleepDurationDeviation` / `arousalLetdown` noise floors and the `scheduleShift` weight are calibrated by the Tier-5 point-biserial table once ≥3 testers have ≥50 labels. `minScoredDays`, `decisionIntervalDays` and `requiredConsecutivePasses` are calibrated by `testRandomLabelsNeverPromote`'s measured false-promotion rate. Until each measurement lands, the marker stays in source.

---

## 13. Risks

1. **Most users will correctly never unlock, and the app will say so.** That is the design working, and it is a product risk. The **log** must carry the value on its own — it does, which is why it is Phase 1.
2. **~1 year to unlock for a typical user** (§1.1). Stated up front rather than discovered.
3. **Chronic-migraine users are the least likely to have a working model** (4 of 5 below chance in the literature) and have most to gain. The removed lift/precision floors at least stop us excluding them *arithmetically*.
4. **SchemaV4 is the sharpest technical risk.** Four coupled edits; missing one traps at `ModelContainer` init and the foreground fallback wipes 30 days of raw samples.
5. **The auth-set change touches a path that has crashed us twice** (#110, #121/#128) and the #129 re-prompt it triggers has never been device-validated. Blocking device gate.
6. **Adding `.headache` newly surfaces the #132 partial-grant banner** for every existing user who declines it.
7. **Overnight skin temp may not exist**; **daytime HR starvation may kill `arousalLetdown`** — the one theory-motivated feature most likely to add information. Both measured in Phase 2 before anything depends on them.
8. **Hangovers and hard training days are indistinguishable from a prodrome on this hardware.** Nothing suppresses them; named in the shipped copy.
9. **Unsigned scoring halves usable information and fires on the protective tail.** Named in the header and the copy.
10. **Multiple testing is improved, not solved.** Overlapping windows make consecutive decisions correlated; the residual is documented in source.
11. **Under-logging biases precision DOWN** (we under-promote — the safe direction), so we may tell a user "this doesn't work" when the truth is "you didn't log". The UI says this.
12. **Nocebo cannot be eliminated, only bounded**: no headache framing pre-unlock, promotion on pre-unlock data only, the before/since split visible, and the notification leads with the base rate.

---

## 14. What we will never do

- Write an auto-detected headache — or an auto-derived severity — to Apple Health. Ever.
- Default severity to anything other than `.unspecified`.
- Claim an accuracy number, a sensitivity, or a comparison to RingConn's detector.
- Use `HKCorrelationType` or an Apple-computed type in `allTypes`.
- Add a `healthTypesVersion` counter.
- Ship weather/WeatherKit/network or any location use. (For the record: WeatherKit's `pressure` is sea-level-reduced and would solve the elevation problem — usable as a `#if DEBUG` validation oracle during development only, never in the shipped path.)
- Ship RingConn's clinical lifecycle vocabulary ("Abnormality Resolved", "Monitored for…").
- Ship ML, a probability output, or a calibration curve. A transparent additive score over per-user robust z-scores reaches the same realistic AUC as every published black box in this space, is explainable in the UI factor list, is unit-testable, and cannot silently overfit.
- Ship an ambient-light card. The 58-entry `IBle*Rsp` inventory has no light channel; it belongs to RingConn's Sun/Hydration alert.
- Repurpose the `location` background mode.
