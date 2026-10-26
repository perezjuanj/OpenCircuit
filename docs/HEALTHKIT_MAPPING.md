# Metric → Apple HealthKit mapping

Target for Phase 4. Every metric the ring exposes maps to a HealthKit sample type.
The iOS app requests write permission per type, then saves samples with the
device's own timestamps (so historical sync backfills correctly).

| RingConn metric | HealthKit type | Kind | Unit | Notes |
|---|---|---|---|---|
| Heart rate | `HKQuantityType(.heartRate)` | Quantity | count/min | live + history |
| Resting heart rate | `.restingHeartRate` | Quantity | count/min | daily, derived on-device (sleep mean → low-activity floor); see notes |
| HRV (RMSSD) | `.heartRateVariabilitySDNN`; on iOS 27+ also `HKQuantityTypeIdentifierHeartRateVariabilityRMSSD` (Health's Recovery HRV) | Quantity | ms | ring reports **RMSSD**; written into the SDNN field and **tagged via metadata** (no fake conversion), and where the OS has the RMSSD type, ALSO written there untagged (decision 59) — see notes. Sourced from **any worn epoch**, not sleep-vitals only (#185) — see below |
| Blood oxygen (SpO₂) | `.oxygenSaturation` | Quantity | % (0–1.0) | HealthKit wants a fraction |
| Skin / sleeping-wrist temperature | `.bodyTemperature` | Quantity | °C | general writable temperature type; the ideal `.appleSleepingWristTemperature` is Apple-computed/read-only for third parties, and `.basalBodyTemperature` is hard-wired to Cycle Tracking's BBT chart — see notes |
| Respiratory rate | `.respiratoryRate` | Quantity | count/min | sourced from **any worn epoch**, not sleep-vitals only (#185) — see below |
| Steps | `.stepCount` | Quantity | count | the wire field is a **quarter-hour bucket, not a running day total** (#192) — see notes; avoid double-counting with phone |
| Active energy | `.activeEnergyBurned` | Quantity | kcal | |
| Sleep stages | `HKCategoryType(.sleepAnalysis)` | Category | — | values: `inBed`, `asleepCore`, `asleepDeep`, `asleepREM`, `awake` |
| Workout / strain | `HKWorkout` | Workout | — | openwhoop "strain" has no native type; store as workout + metadata |

## Amazfit Helio Strap (Zepp OS) (#215)

The strap's metrics land on the **same `MetricKind`s and HealthKit types as the ring**. Wire
layouts are in `ZEPP_PROTOCOL.md` §6.5. The table below was the proposal; what the app does
(phase 3, the decisions of record) is in "What the app writes" right after it. Wire claims keep
their spec tags until checked on a real strap.

| Helio fetch type | `MetricKind` → HealthKit type | Conversion | Gap / decision needed |
|---|---|---|---|
| `0x01` activity: per-minute HR byte | `.heartRate` → `.heartRate` | bpm as-is; drop `0x00`/`0xFF` (no reading) | none |
| `0x01` activity: per-minute steps | `.steps` → `.stepCount` | one sample per minute (or folded per quarter-hour), count as-is | the strap reports **true per-minute counts with a backlog**, unlike the ring's quarter-hour bucket (#192). Don't route these through `StepAccumulator`. Double-counting with the phone is the same trade-off as the ring |
| `0x3A` resting HR | `.restingHeartRate` → `.restingHeartRate` | bpm, one per day | **device-reported**, unlike the ring's derived `RestingHR`. Write it as-is; skip `RestingHR` derivation for this device |
| `0x3D` max HR | none | — | **gap**: no HealthKit type. Keep it local (or drop it) |
| `0x49` HRV (RMSSD) | `.hrvSDNN` → `.heartRateVariabilitySDNN` (+ Recovery HRV on iOS 27+) | ms | strap reports **RMSSD** 🟡 (Amazfit's product-line documentation, which doesn't name the strap; not compared with Zepp's display, `ZEPP_PROTOCOL.md` §6.5); written into the SDNN field and **tagged via metadata** (`OpenCircuitHRVStatistic = "RMSSD"`, no fake conversion), exactly like the ring's — see "HRV: RMSSD stored in the SDNN field" below |
| `0x25` SpO₂ (auto + manual) | `.spo2` → `.oxygenSaturation` | % ÷ 100 (fraction), from the low 7 bits of the value byte | none. `0x26` sleep SpO₂ is optional (Gadgetbridge doesn't store it) |
| `0x2E` temperature | `.temperature` → `.bodyTemperature` | centi-°C ÷ 100 | per-minute **all day**, not just the sleep window like the ring. Decide whether to write every minute, only the sleep window (matching the ring's #29 behaviour), or a downsampled series. Same skin-vs-core caveat as the ring |
| `0x38` sleep respiratory rate | `.respiratoryRate` → `.respiratoryRate` | breaths/min as-is | none |
| `0x48` sleep session + stages | `.sleep` → `.sleepAnalysis` | stage `04` light → `asleepCore`, `05` deep → `asleepDeep`, `08` REM → `asleepREM`, `07` awake → `awake`; unknown stage → `asleepCore`; a stage's end minute is inclusive (decision 70e). Plus one `inBed` sample per session over its in-bed span (decisions 70a/70b) | the strap's own staging, and its own record span as In Bed (🟡, `ZEPP_PROTOCOL.md` §6.6) |
| `0x13` stress (auto) | none | — | **gap**: no HealthKit type. Local only |
| `0x0D` PAI | none | — | **gap**: no HealthKit type. Stored as phone-only `.pai` history (decision 45), never in Health |
| active energy | `.activeEnergy` → `.activeEnergyBurned` | derived from HR with `Calories` (the strap sends no energy history) | same derivation as the ring. Needs dense HR, which the strap's per-minute HR provides |
| `0x05`/`0x06` workouts | `HKWorkout` | — | **out of scope for v1** (see protocol §6.5) |

Cross-device rules (plan of record §4): attach an `HKDevice` naming the strap to every write,
and allow **one active device at a time** in v1, because Apple Health can't dedupe two
devices writing under the same source app.

### What the app writes (phase 3)

Everything is stored on the strap's own timeline (`zeppos:<peripheral id>`) and reaches Apple
Health through the ring's `LocalStore` → `HealthKitWriter` path, carrying the strap's `HKDevice`
(name "Helio Strap", manufacturer "Amazfit", hardware/firmware from the strap's reads). The pure
rules are in `ZeppKit/HelioSyncPolicy.swift`, tested by `HelioSyncPolicyTests`.

| Metric | Stored | Apple Health |
|---|---|---|
| Heart rate (activity per-minute HR) | `.heartRate` | yes, per reading |
| SpO₂ (`0x25`), respiratory rate (`0x38`) | `.spo2`, `.respiratoryRate` | yes |
| Skin temperature (`0x2e`) | `.temperature`, **gated**: 30–42 °C, the minute's activity record known and not `0x73`/`0x76`, inside the strap's own sleep window | yes, as the ring's nightly readings (`.bodyTemperature`); the night's mean goes to the Sleep summary via the ring's `SkinTempBaseline.nightlyVerdict` |
| Steps (activity per-minute) | `StoredStepSample` per minute + `StoredDaily` | yes, additive deltas over their real minute, through the ring's step writer (watermark advances only after the save) |
| Active / basal energy, resting HR, exercise minutes | derived from the stored HR, as for the ring | yes, the ring's derived writers |
| Resting HR (`0x3a`, strap-reported) | `.restingHeartRate` (local only) | no: the ring's derived daily writer already writes one per day, and writing both would double it |
| HRV (`0x49`, RMSSD 🟡) | `.hrvSDNN` | yes, per reading (`HelioHealthPolicy.writesHRV`, decision 44): the RMSSD value in the SDNN field, tagged `OpenCircuitHRVStatistic = "RMSSD"` like the ring's. Readings stored before this shipped backfill on the next flush (the strap's `hk:hrvSDNN` watermark was never advanced), back to the 30-day raw-sample retention. On iOS 27+ also Recovery HRV, through the same gates (decision 59; see "HRV: RMSSD stored in the SDNN field") |
| Sleep (`0x48`) | the strap's own stages (each ending a minute after its inclusive end minute, decision 70e) → Sleep summary + hypnogram, plus one `.inBed` segment per session over the union of its stage span and its record span (`HelioSleepSelection.inBedSpan`, decisions 70a/70b; a stitched night has one per fragment, the gap stays out). Time in bed is the sum of those segments; the layer never counts as asleep or awake. Plus the in-bed lead-in before the first fragment (decision 77, #328): one `.awake` and one `.inBed` segment over the minutes before sleep where the strap's STORED rows show it worn, still and near the sleeping heart rate (an estimate, not the record's span; below) | yes, through `mirrorStrapNight` (`mirrorSettledNight`): the stages and **`inBed`**, as the ring's nights. Forward-only (decisions 70c, 70h): a night already in Health is not rewritten when its only differences from the written night are the `inBed` layer and/or the stage end's minute; a re-delivery still replaces it only under 28f/58b. A manually edited night is never overwritten. Strap naps carry the same `inBed` envelope as the ring's naps (decision 70g). No `SleepStaging` fallback yet (DECISION-GAP, see `HelioSleepSelection`) |
| Stress (`0x13`) | `.stress`, one 0–100 sample per minute (`ff` skipped), charted through the day (#239). A backfill moves only its fetch watermark back, up to 7 days and never before the strap's ownership start, and only when another build advanced that watermark without storing the minutes (builds 59/60) | **no**: no Health type (`HealthKitWriter.quantityType(for: .stress)` is nil; not in any mirrored-kind list; not exported) |
| PAI (`0x0d`) | `.pai`, one row per valid record (value = total PAI, at the record's own time, owned rows only). Phone-only history (decision 45): the PAI tile in Today's Your Numbers grid shows the newest row under 48 h old (decision 49; tapping it explains PAI), so the number survives a sync with no `0x0d` record and every relaunch. A backfill moves only its fetch watermark back, up to 7 days, never before the strap's ownership start and never past the 30-day sample retention, and only when another build advanced that watermark without storing the records (builds 59–62). No chart, no trend, no usual range in v1, and not a `TodayTile` | **no**: no Health type (`HealthKitWriter.quantityType(for: .pai)` is nil; not in any mirrored-kind list; not exported) |
| Walking + running distance | — | **no**: the ring's distance is its own per-step estimate, so it is derived only from step rows the RING owned (decision 28). The strap sends no distance history and its steps get none. The ring's day distance is one sample from midnight to its last row, named the ring, so on a day with a switch Health's hourly chart spreads it across the strap's hours too (review-224c N-c; the day total is right) |

#### Who owns which time (decision 28)

A wearer can switch between the ring and the strap, and both record the same sleep and steps. Each
switch is recorded (`DeviceOwnershipLog`, persisted by `DeviceOwnershipStore`), and a device only
stores and writes what it measured for time it owned:

- the ring owns everything before the first switch, so a ring-only install is unchanged;
- nights (decisions 28a, 28c–28f):
  - a strap sleep is a night only if it could be that night: it passes the ring's own overnight
    gate (`SleepWindow.isOvernightBlock`, 28c) AND ends in its key's wake window
    (`SleepNightKey.endsInWakeWindow`, before noon, 28d), both judged in the time zone it was
    recorded in, from the strap's own local-midnight reference (28e). First, each session's sleep is
    kept only when the strap owns its own window (28a); only those sleeps, 60 min or less apart, are
    then stitched into one night (`HelioSleepSelection.stitch`, 28f): segments exactly as reported,
    the gap left a gap (until decision 74's awake fill, below). Two overnight sleeps of one night key (each passing both gates above, the
    shared `HelioSleepSelection.isOvernightSleep`, 71a) are stitched whatever the gap, so a long
    mid-night awakening never splits a night (decision 71b, #278); the joined night is no longer
    than 20 h. (Stitching before that check let a doze from before a ring → strap switch
    drag the strap's night into ring time, so neither device kept it: review-224e S-1, fixed in
    #225.) Anything else gets a log line and never takes a night key; it may be a nap (below);
  - a sleep more than 60 min from the rest of its night that the overnight join doesn't reach (one
    that would make the joined night longer than 20 h) is not stitched, and its night key already
    holds the longer part. A `helio-link` breadcrumb notes that it happened and whether it was
    stored as a nap (no time, no length);
  - strap naps (#231, `ZEPP_PROTOCOL.md` §21.5, `HelioSleepSelection.naps`): a strap sleep that is no
    night (the gates above kept it from being one, or another night holds its key) is a nap when it
    is 20 min or longer, more than 60 min from every main sleep, and ended at least 60 min ago. The
    main sleeps are every stored night, either device's (edited windows too), and, for a day whose
    00:00–08:00 window no stored night covers, the longest sleep in that window, which is never a
    nap. Only a nap the strap owned ALL of is kept (`DeviceOwnershipLog.ownsWholly`). It is stored as
    a `StoredNap` like the ring's (no schema change), shown in the same nap views and written by the
    same `flushNaps` as ordinary `sleepAnalysis` samples with the strap's stages, naming the device
    that owned its start (the strap). A nap never displaces a night: naps are judged after the
    sync's nights are stored, `saveNap` refuses one that overlaps a stored night, and a night stored
    later prunes an auto nap it overlaps (a strap night also the strap's auto naps within 60 min of
    it, decision 76l), so the ring's night after a switch is kept either way;
  - strap naps from the activity minutes (decision 76, #327): the strap writes no `0x48` record for
    a daytime nap, only kind-sleep (`0x78`) minutes. An activity sleep block (decision 73, below)
    that joins no night is a nap candidate like the sleeps above, through the same rule: 20 min or
    longer, more than 60 min from every main sleep, settled 60 min after its end (and not still
    going on, 73d), owned wholly by the strap. A block within 60 min after a night's last record
    joins the night. When a strap night is stored, every auto nap the strap owned all of that ends 60
    min or less before its stored in-bed start, starts 60 min or less after its end, or overlaps it,
    is pruned (decision 76l), whatever order the syncs ran in. Never by nearness: a ring night, the
    ring's nap, a nap the person added or edited, a night saved by an edit; overlap prunes as before.
    A pruned nap's Health write is removed: inside the night by the night's own mirror, outside it by
    the next nap flush (#327 S1/S2: `cleanPrunedNaps`, this app's own samples in the pruned strap
    nap's written span, one second clear of every stored night and nap; the span is kept until its
    delete succeeds and dropped 14 days after it ended; a ring nap is unchanged). A nap from a block is
    also HELD (unsettled) by the chain of sleep that follows it (decision 76j, an optimisation that
    avoids a write followed by a delete): the sync's kind-sleep runs (up to 5 other minutes inside a
    run, as a block's) starting within 60 min after the nap's end, then each next run starting within
    60 min of the chain's end so far; held while the chain's last run may still be going on (last
    sleep minute under 20 min before the newest fetched minute) or the chain ended under 60 min before
    the newest minute. The remaining cost: a sync before the night's record, once the doze has settled
    and the hold sees no sleep after it (the night's sleep starts over 60 min after the doze or after
    a first fragment, or ended over 60 min before the sync), stores the doze as a nap and the nap flush
    writes it to Health; the morning sync that stores the record prunes it and the next nap flush
    removes the write. The nap is written and removed again. One that is the
    00:00–08:00 main sleep of a night no stored night covers is stored nowhere (an activity-only
    night is out of scope) and counted (`mainOnlyBlocks`). The nap is a `StoredNap` like any strap
    nap (`saveHelioNap`): one `.inBed` envelope over the block, its sleep minutes as generic sleep
    (`.asleepCore`, the SPEC-GAP mapping), an awake gap of up to 5 min left a gap, no score, written
    by the same `flushNaps`. Every sync re-derives it from the minutes it fetched; a nap holding a
    block that a stored auto nap at the same start already covers is left exactly as stored (a
    re-derivation from fewer minutes never shrinks a nap Apple Health holds, which would re-arm it
    and delete what was written), and one whose start moved overlaps the stored nap and is not
    stored (`otherNapOverlaps`). Not recovered: a nap before the last night's end (no longer
    re-fetched);
  - a strap night already written to Health stands against anything that does not extend it (#225,
    narrowed by decision 58b, #274): a later night for its key replaces it only when it overlaps the
    written span and ends at least 10 min later (`LocalStore.strapNightExtends`). That one is stored
    like any other and reaches the flush behind the same settle margin, where the writer's signature
    rewrite (`mirrorSettledNight`: write first, then delete the old span, own samples only, naps and
    the other device's nights excluded) replaces the written night. One `sleep-extend` breadcrumb is
    left per accepted extension that changes the stored night (so a night whose in-progress copies
    keep growing can leave several), none for a night kept out. A night whose window equals the
    written span (within 1 s) passes through as before: if its stages differ the writer rewrites
    Health, if they are identical it does nothing. Anything else (an earlier or under-10-min-later
    end, a different start only, no overlap, or a thinner night the merge keeps out) is kept out as
    before. A stored night that extends the written span is offered even when the merge kept it over
    a later, slightly different re-delivery, by the sync's hand-over (50a) and by the store backstop
    (50b) alike (decision 58e); after the rewrite the written span covers it and it is not offered
    again, and a declined offer is noted like any other (#259). Why: the strap lets the phone read a
    night still in progress, so a night written early could be hours short and was then locked in.
    A night not yet written still stitches. A night joined over a long awakening (71b) overlaps its
    written first part and ends later, so it is an extension like any other; its store prunes an
    auto nap an earlier build kept for the later part, so the rewrite's union delete clears that
    nap's samples too (71e). Known gap (71h): a night an earlier build split as "earlier part =
    strap nap, later, longer part = the night already in Health" stays split after the update. The
    joined night ends where the written night ends, so it is no extension and is kept out; nothing
    is counted twice or lost, and this build's own stitch never makes that split;
  - a later sleep the strap marks only per minute (decision 73, #278): the strap writes one `0x48`
    record per night, and a sleep after a long awakening can be left only in the activity minutes,
    as kind sleep (`0x78`). A run of those minutes outside every staged session's in-bed span, 20 min
    or longer, with up to 5 non-sleep minutes inside it as an awake gap, is an activity sleep block
    (`HelioSleepSelection.activityBlocks`): one `.inBed` over it, its minutes as generic-asleep
    stages, no strap score. It is stitched like a session (per-block ownership first, then 28f/71b)
    and is used ONLY when it joins a night that holds a session record and starts at or after the
    in-bed end of that night's LAST session (no lead-in, nothing between records: 73f, 73i). A block never costs a night (73g):
    if the night it would make fails the overnight gates or is longer than 20 h while the sessions
    alone make an overnight sleep, the sessions' night is kept and the block counted alone. One that
    stands alone (a daytime sleep, an evening doze, a night with no record) is never a night; since
    decision 76 (#327) it is judged as a strap nap (next item). A block whose last sleep minute
    is less than 20 min before the sync's newest activity minute may still be going on and waits
    for the next sync. No new write path: the joined night overlaps the written night and ends
    later, so it is a 58b extension, rewritten once (write first, union delete), and a night not
    yet written is written once after its settle margin. Without activity minutes (that round
    failed or ran out of time) nothing changes;
  - the awake time between a night's fragments (decision 74, #278): in a night with more than one
    fragment, each minute between two fragments where the store holds the strap's own heart rate
    (`.heartRate` under its timeline, for time the strap owns, decision 28) is awake and in bed.
    Those minutes are merged into runs that bridge up to 5 minutes without heart rate; each run is
    one `.awake` and one `.inBed` segment, so Apple Health gets `HKCategoryValueSleepAnalysis.awake`
    and `.inBed` samples there through the same writer path, and time in bed is the fragments plus
    the runs (efficiency and the Sleep Score drop by the awake time). Minutes with no heart rate
    (strap off, nothing recorded) stay a gap: nothing is written for them. Nothing is filled before
    the first fragment or after the last. The fill is measured, never asserted, and derived from the
    STORED heart rate, never a sync's fetched minutes (`LocalStore.helioAwakeFilled`), so the night
    the sync stores, the one it hands to its flush and the one the 50a/50b paths rebuild from the
    stored hypnogram carry the same segments. A night already in Health that differs from the
    written one only by the fill (same span) is rewritten once by the writer's signature rewrite
    (write first, union delete within the written span); a single-fragment night, a ring night and
    an edited night are byte-identical. The skin-temperature gate and verdict and the overnight HRV
    judge the sleep fragments only (`HelioSleepSelection.sleepSpans`), never a run; resting HR reads
    asleep segments only, so all four are unchanged;
  - the in-bed lead-in before the night (decision 77, #328). The record's in-bed span starts at its
    own sleep start, so the strap's time in bed began about 5 minutes before sleep and an app reading
    Time to Fall Asleep from the `inBed` sample saw almost none. When the night is stored (after the
    stitch, the nap split and the fill), `HelioInBedLeadIn` (ZeppKit) reaches back from its first
    in-bed start over the minutes where the store holds the strap's own rows (`LocalStore+HelioLeadIn`):
    a `.heartRate` sample under the strap's timeline (holes of 5 minutes or less bridged, as the fill),
    fewer than 10 steps, and a heart rate at most 15 bpm above the night's sleeping level (the median
    of the first 60 min from the first sleep minute). At most 120 min, nothing under 5 min. It never
    starts before the end of the latest sleep before it (a stored night or nap of either device, or one
    of the sync's own strap sleeps) nor before the strap's ownership start (28). These constants are
    provisional and in one place, to be calibrated on a real store. It is one `.awake` and one `.inBed`
    segment over the same span, so Apple Health gets an `awake` sample before the first sleep stage and
    an `inBed` sample from the lead-in start, through the same writer path (`healthPublication`, no
    writer change). `inBed` never counts as asleep. **It is an estimate from the strap's measured rows,
    not the record's own span.** Naps (decision 77j): the lead-in stops at the end of every nap (stored,
    or one the same sync is about to store, activity-block naps included), and nearness, the 60 min
    rule, 76l's prune and `saveNap`'s overlap backstop, is measured from the night's SLEEP, never its
    lead-in; so the lead-in never prunes a nap, whatever order the nap and the night were stored in.
    A manual nap's add or edit and the nap Health-delete fences still keep out of the whole in-bed
    window. Asleep time is unchanged; time in bed and awake time grow, so
    efficiency and the Sleep Score drop (a synthetic 8 h night with a 60 min lead-in: in bed 480 →
    540 min, efficiency 0.969 → 0.861, Sleep Score 83 → 71). The skin-temperature verdict, overnight
    HRV, resting HR and the night key are those of the night without it.
    Every reader that averages a night's vitals (the illness alert, Vitals Status, the card's
    overnight averages, Trends, the headache HRV and bedtime regularity) reads the night's sleep window,
    the in-bed window without the lead-in (decision 77h, `StoredSleepSummary.sleepWindowStart`), so
    baselines and alerts are as before; a ring night, a night without a lead-in and an edited night
    read exactly as before. A night an earlier build wrote without a lead-in that later extends at the
    end (58b) takes the lead-in along in that one rewrite (77i).
    - Steps: `StoredStepSample` rows carry no device column; they are the strap's by ownership (28:
      each step writer keeps its rows wholly in time its device owns), and the lead-in never reads
      before the strap's ownership start.
    - From the STORED rows, never a sync's fetched minutes, so every re-delivery derives the same
      lead-in, and the 50a/50b paths rebuild the night with the lead-in it was stored with.
    - Forward-only: a night already in Health is never rewritten for its lead-in. One written with the
      same lead-in passes as before; one written without (an earlier build, or before the heart rate
      was stored) goes on without a lead-in, exactly as before, so the card and Health agree; any other
      start-only change is kept out by 28f/58b, store row included. A night not yet written is written
      once with it, and a 58b extension takes it along.
    - Naps, edited nights and the ring: unchanged;
  - the strap's gate is the ring's pass 1 only: the ring's second pass (a night whose onset was
    never recorded, `onsetIsUnobserved:`) needs its epoch archive's evidence of a hole, which the
    strap has no equivalent of, so a strap session recorded only from 06:00 is not a night;
  - the device you went to bed with keeps the night: the device chosen when its in-bed window began,
    however late a switch lands inside it (for the strap, the window of its own stitched sleeps, so a
    doze before the switch never moves the night's start into the other device's time). A switch at exactly the in-bed start goes to the NEW
    device (the switch counts as made before bed);
  - sleeps that overlap: a stored night is never replaced or merged by the other device's night;
    when a switch falls between the two devices' bedtimes, each window began under its own device,
    so whichever device syncs first keeps the night. "Whichever syncs first" applies only to sleeps
    that overlap;
  - two sleeps that DON'T overlap but share one key (e.g. the ring's 23:00–07:00 and the strap's
    07:30–10:00 after a morning switch): the longer one that ends in the wake window is the night,
    and the shorter one never makes it unkeepable (the night may replace it);
  - the device that doesn't keep the night is skipped (`ownedByOtherDevice`, or
    `ownedByOtherDeviceNoRow` when the owner stored none, which the Sleep card shows as a notice
    instead of the ring's reading). A kept night goes to Health named its owner, even where it covers
    the other device's minutes; the mirror's delete never reaches the other device's kept night.
    **Don't switch while asleep** anyway: the night stays with the device you went to bed with, and
    the new device's reading of it is not kept;
- step rows lie wholly in their device's time (decision 28b): the ring's first quarter-hour bucket
  after a switch back is clamped to the switch, its delta kept, so it is named the ring and gets
  distance. At most the pre-switch part of that one bucket can be counted by both devices;
- the strap fetches nothing older than the start of its current ownership (`HelioFetchPlan`'s
  `notBefore`), except on an install that never had a ring, where its first ownership starts in the
  distant past and the first sync is the normal backfill;
- the ring's catch-up after a switch back stores its rows for the strap's window locally, but none
  of them is pending for Apple Health and no night is saved from them;
- resting HR, active/basal energy and exercise minutes use only HR from the device that owned it;
- every write names the device of its ROW: a timeline's rows name that timeline's device, untagged
  rows (steps, sleep, naps, derived values) name the device that owned their start (a night: the
  device it belongs to, above). A strap sync flushed after a switch back to the ring still names the
  strap, or writes nothing when the strap never passed the first-write guard. BP estimates (its PPG
  calibration) and the distance estimate (its per-step constant, a sample starting at midnight) are
  the ring's and always name the ring.
- baselines ("your usual") are per device (decision 29): every in-app comparison (the Today tiles and
  sentence, Vitals Status and its Apple Health fallback, the temperature and fever alerts, the Sleep
  card's skin temperature, cycle and headache signals, the ring's own prior-nights judgement, the
  basal-energy resting-HR baseline) compares a night or day only with earlier ones from the same
  device, so a new device starts "Learning your usual". Nothing written to Health changes;
- **Known limit (v1 is one strap):** untagged rows in strap-owned time name the CURRENTLY saved strap
  (`HelioConnection.savedPeripheralID`). Pairing a second strap before the first one's untagged rows
  (steps, sleep, derived values) are flushed would name the new strap for them. Tagged rows (heart
  rate, SpO₂, respiratory rate, temperature) always name their own strap.

## User-entered logs

Not everything we write comes from the ring. These types carry what the **user typed**,
and the ring contributes nothing to them. Same house pattern in both cases: a SwiftData
row keyed by its start, with the written sample UUIDs recorded on the row so an edit
deletes-then-rewrites (HealthKit is append-only) and a delete removes the sample from Health.

| User-logged entry | HealthKit type | Kind | Unit | Notes |
|---|---|---|---|---|
| Period / flow (#78) | `HKCategoryType(.menstrualFlow)` | Category | — | one single-day sample per logged day; `HKMetadataKeyMenstrualCycleStart` on the first day only |
| Headache | `HKCategoryType(.headache)` | Category | — | value = `HKCategoryValueSeverity`; written **only** from an explicit user entry — see notes |

## Implementation notes

- **Sources & dedup.** Use a stable `HKSource`/bundle id so re-syncs update rather
  than duplicate. Track a per-metric sync cursor (last record timestamp) in the
  local store; only write newer records.
- **Authorization.** HealthKit requires explicit per-type write permission and an
  `NSHealthShareUsageDescription` / `NSHealthUpdateUsageDescription` in Info.plist.
  You cannot detect denial vs absence of data, so design for partial grants.
- **Sleep modeling.** HealthKit represents a night as many contiguous
  `sleepAnalysis` category samples (one per stage segment), not one summary record.
- **Sleep provenance (2026-08-24).** When a wearer edits a night, the part of it over
  ground the epoch archive PROVES holds no records is written with
  `HKMetadataKeyWasUserEntered: true`; everything else goes in unlabelled. The flag is
  provenance only — Apple's "Time Asleep" still sums those samples — so a corrected night
  reaches Health in full while a reader can still tell which minutes came from the wearer.
  Manually ADDED naps carry the same flag. 🟢 Reversal of build 47, which withheld those
  samples entirely; see `SleepHealthPublication`.
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

### HRV: RMSSD stored in the SDNN field, labeled via metadata (#37); also Recovery HRV on iOS 27+ (decision 59)

The ring reports HRV as **RMSSD** (`BulkSleep` / `HRV.rmssd`), and so does the Helio Strap
(`0x49`, 🟡: Amazfit documents its devices' HRV as RMSSD without naming the strap, and no value has
been compared with Zepp's, `ZEPP_PROTOCOL.md` §6.5). Before iOS 27 HealthKit had a
single HRV field, `.heartRateVariabilitySDNN`. RMSSD and SDNN are **not** related by a
fixed constant (their ratio depends on the RR spectrum), so we do **not** apply a made-up
conversion. Instead each HRV sample is written to the SDNN field with metadata
`OpenCircuitHRVStatistic = "RMSSD"` (`HealthKitWriter.metadata(for:)`), so the value is
honest and a reader can tell which statistic it actually is. If a future capture shows the
ring also reports true SDNN, switch to writing that directly and drop the tag. The tag has no
per-device branch: both devices are taken as RMSSD, so a device with another statistic would need one.

**iOS 27 and later: Recovery HRV (decision 59, #277).** iOS 27 added an RMSSD type,
`HKQuantityTypeIdentifierHeartRateVariabilityRMSSD` (ms), the type behind Health's Recovery HRV
section. Where it exists, every HRV reading the regular copy is offered is ALSO saved there:

- **Where.** Decided by `HKObjectType.quantityType(forIdentifier:)` on the raw identifier returning
  non-nil (`HealthKitWriter.resolveRecoveryHRVType`), never by an OS version and never through
  `HKQuantityType(_:)`, which traps on nil. The iOS 26.5 SDK we build with has no Swift symbol for
  it, hence the raw string. Below iOS 27 nothing changes: same share set, same writes, no switch.
- **Same gates.** The device's policy (`healthMirroredKinds` / `HelioHealthPolicy.healthMirroredKinds()`,
  so a strap with `writesHRV` off writes neither copy), `value > 0`, decision 28's ownership and the
  workout exclusions. `LocalStore` applies them through one shared filter for both sinks.
- **Same sample, other type.** The stored value in ms, never converted, on the row's own times, naming
  the same device as the regular copy. No `OpenCircuitHRVStatistic` tag (the type is the statistic)
  and no `HKMetadataKeySyncIdentifier`.
- **Own watermark.** `hk:recoveryHRV` per device, beside `hk:hrvSDNN`, advanced only after a confirmed
  save. Its first run offers every retained HRV reading (30-day raw retention) once; a failure of
  either copy never holds or moves the other. One more `StoredCursor` row, no schema change.
- **The regular copy stays, behind a switch.** Profile ▸ Apple Health ▸ "Also write HRV as Heart Rate
  Variability", on by default, shown only where the RMSSD type exists. Off stops new regular copies
  only (nothing in Health is deleted) and leaves `hk:hrvSDNN` where it is, so turning it back on
  offers what was held back.
- **Authorization.** The type joins `allTypes` only where it exists, so an existing iOS 27 install is
  asked once more, for the new type, by the #129 re-ask. A refusal shows as "Recovery HRV" in the
  partial-grant line, and a failing save as its own "Recovery HRV" failure (`recoveryHRV` in
  `hk.failures.byMetric`), never as the regular HRV's.
- **On the phone.** The flush log lines (`helio: Health flush …`, the strap's background run line,
  `[OC] healthKit …`) end in `recoveryHRV=<n>` when it saved and `recoveryHRV=failed` when its save
  threw, and say nothing about it otherwise. The sync card names it ("Synced to Health: 12 Recovery
  HRV"). With the switch off, an older regular-HRV failure is left out of the warning (it can't clear
  while no regular copy is attempted) and comes back if the switch is turned on again.
- **Not verified.** That Health's Recovery HRV screen shows a third-party sample. Apple hasn't
  documented it, and its support page says Recovery HRV is sampled while the person is still, while the
  ring's HRV comes from any worn epoch (#185). Retiring the regular copy waits until a phone shows it.

### HRV and RR come from ANY worn epoch, not sleep-vitals only (#185)

Both metrics ride the `0x4c` history stream, which has two record templates (PROTOCOL.md §5.3).
Until #185 we emitted HRV `[5]` and RR `[7]` **only** from *sleep-vitals* records, so roughly half
of both never reached Apple Health even though the ring had measured them: `0x12`/`0x13`
**activity** epochs carry a real RMSSD and a real RR too (🟢 measured, 6 independent archives —
median delta vs the nearest sleep-vitals neighbour within 300 s is −1.5…+2.5 ms on Gen-2/Gen-3).

What the sample path now writes:

- **RR** — from any worn epoch, `[7]/8`, clamped to 4.0…30.0 brpm. Motion does not corrupt this
  field, so there is no motion gate.
- **HRV** — from sleep-vitals epochs as before, and from activity epochs **only while the ring's own
  `[15:20]` intensity tail is zero** (the epoch did not move), clamped to 1…200 ms. Moving epochs
  are excluded because that is where the 146–200 ms PPG artifact tail lives.
- **SpO₂** — unchanged, still sleep-vitals only, permanently: `[8]` **is** the activity tag, so
  there is no SpO₂ on an activity epoch to recover.

Expected yield on the measurement corpus: **HRV +67 %, RR +132 %** samples per drain. Nightly *mean*
HRV therefore shifts slightly (≤2 ms on Gen-2/Gen-3; −6.9 ms on the FR04 Gen-2-Air) because the
sample population widened — anything z-scoring HRV against a rolling baseline (`HeadacheEngine`)
re-baselines across the changeover. `SyncCursor` is forward-only, so already-synced nights are not
retro-filled; only new drains benefit.

⚠️ The recovery is confined to the HealthKit sample path. Sleep **detection, staging, naps and
`SleepStress`** still read the strict sleep-vitals-scoped accessors, because for them "the ring
emitted a sleep-vitals record" is a *mode* signal, not just a value — widening it would move the
detected night. The two recovering accessors are deliberately `internal` to `OpenCircuitKit` so the
app target cannot reach them; `StrictVitalsPinningTests` pins the whole sleep pipeline byte-identical.

### Steps: the wire field is a quarter-hour bucket (#192)

The `0x10`/`0x87` descriptor's `[4:6]` step field is **not** a running daily total — it counts
steps since the last wall-clock `:00`/`:15`/`:30`/`:45` and clears at each boundary 🟢 (re-derived
over 10,327 descriptor frames from two rings; 268 clears, every one at a quarter boundary; the
field never exceeds 746 on days the app itself folded to 2,611–4,566). Consequences for what we
can honestly write to Health:

* **The day total is the sum of the quarter-hour buckets we were connected for.** There is no
  cumulative counter anywhere on this wire, so a quarter nobody observed cannot be back-filled —
  steps are the only metric with **no ring-side backlog** to heal a gap. A missed session is a
  permanent undercount, which is why the force-quit residency failure (iOS blocking BGTask +
  CoreBluetooth restoration after a swipe-close) shows up on steps first and hardest.
* `OpenCircuitKit.StepAccumulator.update` folds it: credit the increment while the bucket climbs,
  credit the raw value whole when it drops. That *is* "sum the observed buckets". The tempting
  "credit in full at every wall-clock boundary" rule measures **+4.9 % over** (+8.2 % with a lag
  margin) on the real corpus, because the ring can keep reporting the previous bucket for up to
  **108 s** after a boundary. Do not reintroduce it.
* Each delta is written as its own timestamped `StoredStepSample`, and its window START is floored
  to the sample's own bucket (`StepAccumulator.windowStart`). Before #192, a reconnect stamped the
  previous reading from hours earlier and the day's first reading stamped local midnight —
  measured, 22 of 989 credits (5.3 % of all step mass) were smeared that way, six of them across
  11–22 hours. Totals were unaffected; only the time placement in Health was wrong.
* **A reading of 0 says nothing about wear or wake.** It means "no steps in this quarter yet",
  which is what most of a night — and a morning spent in bed — looks like.

### Resting HR: derived daily, idempotent (#18, #37)

The ring does not transmit resting HR; `OpenCircuitKit.RestingHR` derives a daily value:
preferred = mean HR across the night's `asleep*` segments; fallback = the lowest sustained
(5-min rolling-mean) HR, the same basis Apple Health uses, so the values sit side by side.
`HealthKitWriter.flushRestingHR` writes one `.restingHeartRate` sample per day, anchored at
start-of-day, finalizing a day only once it's ~12 h old (so a pre-dawn sync can't freeze a
partial-night value while last night's RHR still lands by midday).

Coverage floor (#298): a day answered by the fallback needs at least 12 readings spanning at
least 4 h (`RestingHR.dayCoverage`), or it gets no resting HR: not on the Today tile, not in
Vitals Status or alerts, and not in Apple Health. Night wearers are unaffected (the sleep mean
answers, and a night spans more than 4 h). Someone who wears the device only a few daytime hours
and never at night (a short ring session, a strap worn only for a workout) gets no resting HR
written: the lowest HR of a short awake or exercising stretch is not a resting heart rate. The
watermark moves only onto a written day, so a thin day after the last written one is written
later with its full value if its readings fill in (within the 7-day lookback).

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

### Headache log → `HKCategoryType(.headache)`

The headache log is a **label series the user writes**, not a measurement. It exists so a
later phase's detector has ground truth to be validated against, and the mirror to Apple
Health keeps that series portable and re-importable.

**Write direction — user entries only.** A `.headache` sample is written for exactly one
reason: the user opened the log sheet and said they had a headache. Nothing in this app ever
*infers* a headache from ring data and writes it to Health. `StoredHeadacheEntry.source`
records provenance (`user` / `healthImport` / `periodLogImport`), and
`LocalStore.pendingHeadacheEntries()` excludes `healthImport` rows, so a sample read out of
Health is never written back into it.

**Severity is the identity function.** `StoredHeadacheEntry.severityRaw` deliberately stores
`HKCategoryValueSeverity`'s own raw values, so the mapping is `severityRaw` → itself and
there is no translation table that can silently drift when either side gains a case:

| stored `severityRaw` | `HKCategoryValueSeverity` | shown in-app |
|---|---|---|
| 0 | `.unspecified` | Unspecified |
| 1 | `.notPresent` | None |
| 2 | `.mild` | Mild |
| 3 | `.moderate` | Moderate |
| 4 | `.severe` | Severe |

**An open headache writes a zero-length sample.** When the user has logged an onset but no
resolution (`end == nil`), the sample's start and end are both the onset — we never invent
a duration for a headache that hasn't ended. The entry stays un-finalized so a later flush
can delete that placeholder and re-write the real span once the user logs the end (the same
delete/re-write path an edit uses).

**Read direction — labels, never a displayed measurement.** Headaches already in Apple
Health can be imported (on the user's explicit tap) so the label series isn't empty for
people who have been logging elsewhere. Imported rows are marked `healthImport`, are
de-duplicated by `importedHKUUID`, are shown as what they are — the user's own Health
entries — and are never presented as something OpenCircuit measured or derived. The only
downstream consumer is a future detector, which consumes them as **labels**. HealthKit does
not report READ grants, so an empty read means *unknown*, never "this user has no
headaches" — an import that returns nothing must not be treated as evidence of absence.

**The detector writes nothing to Apple Health.** The overnight signals index
(`StoredHeadacheRisk`) is local-only: no score, no band and no notification state is ever
saved to Health, and there is no HealthKit type for any of it. The only thing this feature
ever puts into Apple Health is what the user typed.

**Authorization.** `HKCategoryType(.headache)` joins `HealthKitWriter.allTypes` — the
single source of truth for the share set — so it is covered by the same partial-grant
handling as every other type. Like every non-workout type there it is *also* requested for
READ, which is what makes the import possible. It is a third-party-writable symptom type,
so unlike
`.appleSleepingWristTemperature` or `.appleExerciseTime` it can safely be listed in
`toShare`.
