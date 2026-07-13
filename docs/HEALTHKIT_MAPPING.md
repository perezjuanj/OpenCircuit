# Metric → Apple HealthKit mapping

Target for Phase 4. Every metric the ring exposes maps to a HealthKit sample type.
The iOS app requests write permission per type, then saves samples with the
device's own timestamps (so historical sync backfills correctly).

| RingConn metric | HealthKit type | Kind | Unit | Notes |
|---|---|---|---|---|
| Heart rate | `HKQuantityType(.heartRate)` | Quantity | count/min | live + history |
| Resting heart rate | `.restingHeartRate` | Quantity | count/min | daily, derived on-device (sleep mean → low-activity floor); see notes |
| HRV (RMSSD) | `.heartRateVariabilitySDNN` | Quantity | ms | ring reports **RMSSD**; written into the SDNN field and **tagged via metadata** (no fake conversion) — see notes |
| Blood oxygen (SpO₂) | `.oxygenSaturation` | Quantity | % (0–1.0) | HealthKit wants a fraction |
| Skin / sleeping-wrist temperature | `.bodyTemperature` | Quantity | °C | general writable temperature type; the ideal `.appleSleepingWristTemperature` is Apple-computed/read-only for third parties, and `.basalBodyTemperature` is hard-wired to Cycle Tracking's BBT chart — see notes |
| Respiratory rate | `.respiratoryRate` | Quantity | count/min | |
| Steps | `.stepCount` | Quantity | count | cumulative; avoid double-counting with phone |
| Active energy | `.activeEnergyBurned` | Quantity | kcal | |
| Sleep stages | `HKCategoryType(.sleepAnalysis)` | Category | — | values: `inBed`, `asleepCore`, `asleepDeep`, `asleepREM`, `awake` |
| Workout / strain | `HKWorkout` | Workout | — | openwhoop "strain" has no native type; store as workout + metadata |

## Implementation notes

- **Sources & dedup.** Use a stable `HKSource`/bundle id so re-syncs update rather
  than duplicate. Track a per-metric sync cursor (last record timestamp) in the
  local store; only write newer records.
- **Authorization.** HealthKit requires explicit per-type write permission and an
  `NSHealthShareUsageDescription` / `NSHealthUpdateUsageDescription` in Info.plist.
  You cannot detect denial vs absence of data, so design for partial grants.
- **Sleep modeling.** HealthKit represents a night as many contiguous
  `sleepAnalysis` category samples (one per stage segment), not one summary record.
- **Derived vs raw.** Metrics openwhoop *computes* (sleep detection, strain, stress)
  are written from the Swift-ported analytics; raw device metrics are written as-is.
  Decide per-metric whether the ring already reports it or we derive it.
- **No HealthKit on desktop/macOS.** This mapping is only realized in the iOS app;
  the desktop workbench just dumps to SQLite/CSV for validation.

### Temperature → `.bodyTemperature` (#29)

OpenCircuit only captures skin temperature during the nightly sleep window
(`RingSession` gates temp frames to the detected/scheduled night).

The *ideal* home is `.appleSleepingWristTemperature` (what Apple's own sleep apps and
Bevel's wrist-temp baseline read), but that type is **Apple-computed and read-only for
third-party apps**: a `save()` of it would fail, and — worse — listing it in the
`toShare` set of `requestAuthorization` raises an Obj-C `NSInvalidArgumentException`
("Authorization to share the following types is disallowed"), which crashes the auth
flow or, once swallowed by the call site's `try?`, silently disables writeback for *every*
metric.

The next candidate, `.basalBodyTemperature`, is a writable third-party type — but Apple
Health hard-wires it to **Cycle Tracking's basal body temperature (BBT) chart**, a
specific fertility signal read at wake before rising. Writing nightly wrist skin
readings there would corrupt users' BBT/ovulation reporting.

So we write the writable, general **`.bodyTemperature`** type instead
(`HealthKitWriter.quantityType(for: .temperature)`), and `requestAuthorization` is
hardened to drop the temperature type rather than poison the whole share request if it is
ever refused. Trade-offs: values do not land in the sleeping-wrist chart (that type is
third-party read-only), and `.bodyTemperature`'s chart is normally oral/core — a wrist
skin reading (~5 °C below core) will look low there. Values stay in °C.

### HRV: RMSSD stored in the SDNN field, labeled via metadata (#37)

The ring reports HRV as **RMSSD** (`BulkSleep` / `HRV.rmssd`), but HealthKit only has a
single HRV field, `.heartRateVariabilitySDNN`. RMSSD and SDNN are **not** related by a
fixed constant (their ratio depends on the RR spectrum), so we do **not** apply a made-up
conversion. Instead each HRV sample is written to the SDNN field with metadata
`OpenCircuitHRVStatistic = "RMSSD"` (`HealthKitWriter.metadata(for:)`), so the value is
honest and a reader can tell which statistic it actually is. If a future capture shows the
ring also reports true SDNN, switch to writing that directly and drop the tag.

### Resting HR: derived daily, idempotent (#18, #37)

The ring does not transmit resting HR; `OpenCircuitKit.RestingHR` derives a daily value:
preferred = mean HR across the night's `asleep*` segments; fallback = the lowest sustained
(5-min rolling-mean) HR, the same basis Apple Health uses, so the values sit side by side.
`HealthKitWriter.flushRestingHR` writes one `.restingHeartRate` sample per day, anchored at
start-of-day, finalizing a day only once it's ~12 h old (so a pre-dawn sync can't freeze a
partial-night value while last night's RHR still lands by midday).

### Calories: passive (BMR) + active (TRIMP), idempotent (#37)

`flushToHealth` also writes energy: **passive** = hourly BMR (`Calories.bmrKcalPerHour`) to
`.basalEnergyBurned`, one sample per completed hour; **active** = the day's Edwards-TRIMP
kcal (`Calories.activeKcal`) to `.activeEnergyBurned`, written as the delta over what was
already written today (HealthKit SUMS energy, so deltas land the running total). Active
energy needs dense HR (Edwards TRIMP requires ≥10 min of readings), so it's ~0 on sparse
auto-measure days and meaningful during live monitoring. Body inputs (age/weight/height/sex)
come from the user profile; the ring transmits none of them.

### Idempotency for derived writes

Raw samples and sleep dedupe through the LocalStore sync cursor. The **derived** writes
above are not stored samples, so each carries its own high-water mark in `UserDefaults`
(resting-HR day, basal next-hour, active-energy day + written-kcal). Marks advance only after
a confirmed save and are shared across the foreground + background writer instances, so
repeated foreground/background syncs never double-write.
