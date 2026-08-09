// Sleep-stage classifier — Awake / Light / Deep / REM from the 0x4c per-epoch
// signals (PROTOCOL.md §5.3). The ring does NOT transmit a hypnogram; the RingConn
// app computes stages on-device from the same vitals we decode, so we approximate
// that proprietary algorithm here with standard consumer-wearable heuristics.
//
// ⚠️ APPROXIMATION, NOT GROUND TRUTH. We have no PSG (or even per-epoch app) labels —
// only the app's NIGHT TOTALS to sanity-check against (see the night of 2026-06-14:
// asleep 7:37, awake 43m, REM 1:42, light 4:45, deep 1:10). So this is tuned to be
// physiologically principled and to roughly partition a night the way a wrist/ring
// tracker would; it is NOT validated to reproduce per-epoch stage timing, and the
// exact Deep/REM split should be read as approximate proportions, not a clinical
// hypnogram.
//
// Signals per 150 s epoch (forward-filled across epochs that drop a reading):
//   • HR  [4]  — the spine of the model. Stage bands are set from the NIGHT'S OWN HR
//                distribution (percentiles of the asleep HR), never absolute bpm, so
//                it generalises across people and nights.
//   • HRV [5]  — RMSSD; fused in as a secondary REM cue via its short-term variability.
//   • motion [10:15] — the awake signal (a moving sleeper is awake).
//
// Awake is decided FIRST, and from HR as well as motion: an epoch is awake when its
// motion exceeds the threshold OR its smoothed HR sits a margin above the night's
// sleeping floor. That HR gate is the fix for "lying still but awake" — the motion
// still-block alone counts pre-sleep / quiet-morning wakefulness as sleep, so the
// in-bed window starts hours early and a low-movement morning wake is missed. Sleep
// ONSET/OFFSET are then the start of the first, and end of the last, SUSTAINED asleep
// run; leading/trailing in-bed time outside that span is kept as AWAKE-IN-BED (it is
// time in bed, just not asleep — RingConn's two-window model, efficiency = asleep /
// time-in-bed), never counted as sleep. (REM and quiet wake
// overlap in HR, so the wake margin is set deliberately wide — above REM elevation —
// and short HR-only awake runs erode back to asleep so a REM bump can't punch a hole.)
//
// Stage logic, per asleep epoch:
//   • Deep  — HR near the night's minimum (low percentile) AND low HR variability AND
//             no motion: the calm, consolidated low-HR troughs.
//   • REM   — HR elevated toward waking OR HR/HRV notably variable, but motion ~0
//             (muscle atonia). Variability — not absolute HR — is what separates REM
//             from Light, matching the physiology.
//   • Light — everything else asleep (the remainder).
// Bands are percentiles of the TRIMMED (in-window) asleep distribution, so pre-sleep
// wakefulness no longer pollutes them. Stages persist in real sleep, so short Deep/REM
// runs are smoothed back to Light to avoid single-epoch flapping.

import Foundation

/// Stage-by-stage classifier over a night's `0x4c` `BulkRecord`s. Pure/testable:
/// it takes records, returns `[SleepSegment]`, and touches no I/O.
public enum SleepStaging {

    /// Tunable thresholds. All HR/variability cut-offs are PERCENTILES of the night's
    /// own asleep distribution (plus small absolute floors), so they adapt per night
    /// rather than baking in fixed bpm. The Deep/REM percentile defaults were CALIBRATED
    /// (2026-06-20) against a Helio strap hypnogram (06-20: Deep 19% / Light 55% / REM 26%)
    /// and the RingConn app's 06-14 totals (Deep 15% / Light 62% / REM 22%), validated to
    /// give physiological proportions across four decoded nights. Deep is keyed off HR
    /// FLATNESS (low variability) as much as low HR — real light sleep carries HR jitter,
    /// which is what keeps it out of Deep; a too-strict deepHRPercentile collapsed Deep to
    /// a few minutes on real (flat-HR) nights.
    public struct Tuning: Sendable, Equatable {
        /// Motion magnitude (sum of non-baseline `[10:15]` counts over the epoch) above
        /// which the epoch is Awake. Baseline `01` contributes 0.
        public var awakeMotion: Int
        /// Lower HR percentile (of asleep epochs) bounding Deep — near the night's floor.
        public var deepHRPercentile: Double
        /// Upper HR percentile bounding "HR elevated toward waking" → a REM cue.
        public var remHRPercentile: Double
        /// HR-variability percentile below which an epoch is "calm enough" for Deep.
        public var deepVarPercentile: Double
        /// HR-variability percentile above which an epoch is "variable" → a REM cue.
        public var remVarPercentile: Double
        /// Half-window (epochs each side) for the rolling HR/HRV variability estimate.
        public var variabilityHalfWindow: Int
        /// Non-degeneracy floor for the Deep variability gate, so a flat night still admits
        /// Deep. NOTE: this is on the *blended* variability scale (HR rolling-SD plus
        /// `hrvVarWeight`×HRV rolling-SD), not raw bpm — the threshold is `max(percentile, floor)`
        /// over that same blended pool, so the floor only binds on near-zero-variance nights.
        public var deepVarFloor: Double
        /// Non-degeneracy floor for the REM variability gate (blended scale; see deepVarFloor).
        public var remVarFloor: Double
        /// Minimum consolidated run length (epochs) for Deep; shorter → relabelled Light.
        public var minDeepRunEpochs: Int
        /// Minimum consolidated run length (epochs) for REM; shorter → relabelled Light.
        public var minREMRunEpochs: Int
        /// Minimum Awake run; shorter motion blips inside sleep → relabelled Light.
        public var minAwakeRunEpochs: Int
        /// Weight of HRV short-term variability fused into the variability score (0 = HR
        /// only). Only contributes on epochs where HRV is present.
        public var hrvVarWeight: Double
        /// Weight of respiratory-rate short-term variability fused into the variability
        /// score (0 = no RR contribution). Mirrors `hrvVarWeight` exactly: it adds
        /// `rrVarWeight × rollingSD(RR)` to the blended variability scale, and only on
        /// epochs where RR is present. RingConn's on-device staging fuses RR (APK RE), but
        /// the exact weight is not recoverable from their binary, so this defaults to 0 —
        /// byte-identical output to the pre-RR model — and is meant to be SUPERVISED-FIT
        /// against captured RingConn labels before being raised.
        public var rrVarWeight: Double

        // --- HR-aware wake / onset-offset (the "still but awake" fix) --------------
        // The motion still-block alone counts lying-still-but-awake as sleep, so the
        // in-bed window can start hours before real sleep onset and a quiet morning
        // wake (little movement) is missed. These gate sleep on HR: a sleeper's HR sits
        // near the night's floor; awake/active HR rides well above it.

        /// Low percentile of the block's HR taken as the night's SLEEPING FLOOR. Robust:
        /// even a window polluted by pre-sleep wake has a real sleep core at the bottom,
        /// so the floor is stable where a high percentile (the thing we're detecting)
        /// would not be.
        public var sleepFloorPercentile: Double
        /// bpm above the sleeping floor at which a (smoothed) epoch counts as awake.
        /// Deliberately set ABOVE typical REM elevation — REM and quiet wake overlap in
        /// HR, so the seam is wide; sustained wake (pre-sleep activity, the morning rise)
        /// clears it while a REM bump does not. The single most validation-sensitive knob;
        /// retune against a captured night with known bed/wake times.
        public var wakeHRMarginBPM: Double
        /// Half-window (epochs each side) for the rolling-MEDIAN HR used by the wake gate,
        /// so a one-epoch HR spike doesn't read as an awakening.
        public var hrWakeHalfWindow: Int
        /// Half-window (in epochs) for the sleep-vitals coverage that softens MOTION-awake: an epoch
        /// with a sleep-vitals (HRV) epoch within this many epochs on either side AND sub-wake HR is
        /// treated as moving-but-ASLEEP, not motion-awake — so the `sleepVitalsRescue` tail survives
        /// staging's re-trim. Sized to bridge the sleepV/activity epoch interleave (~1 sleepV per 2
        /// epochs). 0 disables the softening (byte-identical to the pre-rescue staging).
        public var motionAwakeVitalsHalfWindow: Int
        /// A sustained asleep run of at least this many epochs anchors sleep ONSET (its
        /// start) and OFFSET (the end of the last such run). Leading/trailing awake outside
        /// that span is trimmed from the in-bed window — this is what shrinks an over-wide
        /// motion window back to the real night.
        public var onsetSustainEpochs: Int
        /// Minimum length of an HR-ONLY-driven interior awake run; shorter ones erode back
        /// to asleep so a transient REM-ish HR bump can't punch a hole in sleep. Motion-
        /// driven awake epochs are exempt (a real movement is awake however brief).
        public var minHRWakeRunEpochs: Int

        // --- Second-bout HR-wake rescue (the "sleep never continues after a 3 a.m. wake" fix) ----
        // The wake gate above condemns an epoch on a SINGLE night-wide floor (`sleepFloorPercentile`
        // + `wakeHRMarginBPM`). A night with a real mid-sleep awakening is BIMODAL: the consolidated
        // first half is deep-rich, owns the low tail, and so SETS the floor; sleep AFTER the awakening
        // returns legitimately lighter (less N3, more N2/REM, a little post-ambulation elevation) and
        // can sit a few bpm above that floor — an objectively LOW heart rate that still clears
        // floor+18, so EVERY epoch of the second bout flags awake and the whole back half of the night
        // (hours) is lost as "awake with low HR". `erodeShortHRWake` can't undo it (it reaches only
        // runs < `minHRWakeRunEpochs`); the motion softening can't (it needs `smHR < wakeThreshold`,
        // the very thing that failed); the coarse `sleepVitalsRescue` can't (it grows the block's END
        // into a trailing `.active` period, but here the COARSE layer got the night right so there is
        // nothing to grow into — the error is staging-only). So add the missing ADD-only counterpart:
        // relabel a long, motion-free, sleep-vitals-backed, only-mildly-elevated HR-awake run back to
        // asleep when a consolidated sleep bout already lies BEHIND it. Grounded on the 2026-07-19
        // tester report (build 26): slept ~23:00–03:00, a ~10-min bathroom trip, then read "awake with
        // low heart rate" until 07:00 — ~4 h of real sleep dropped. 🟢 the mechanism + the cliff at
        // exactly floor+`wakeHRMarginBPM` are reproduced by a synthetic-night test (see
        // SleepContinuationTests); 🟡 that THIS tester's second-bout HR sat in the rescue band pending
        // his replayed archive.

        /// bpm above the sleeping floor at/above which an epoch is taken to be GENUINELY awake and is
        /// never rescued: every epoch of a rescued sub-run must sit strictly below `floor + this`, so the
        /// effective rescue band is [floor+`wakeHRMarginBPM`, floor+this) ≈ [+18, +25). NOTE the number
        /// 25 is borrowed from `ActivityPeriod.awakeHRMarginBPM` as a plausible "definitely awake above
        /// this" line, but the layers are NOT symmetric: the coarse gate uses +25 only to REMOVE sleep
        /// (SleepDetection.swift:104, "only REMOVES sleep, never adds it"), whereas this pass ADDS sleep
        /// below it — so in [+18, +25) the coarse layer is merely "not sure it's awake" while this pass
        /// asserts "asleep". That is the deliberate bias documented on `rescueSecondBoutHRWake` (light
        /// second-bout sleep vs still quiet wake are not separable here); this knob is the dial for it.
        /// `0` DISABLES the rescue entirely — byte-identical to the pre-rescue staging (the regression
        /// escape hatch, mirroring `motionAwakeVitalsHalfWindow = 0` / `preOnsetBedtimeReachEpochs = 0`).
        /// The single most validation-sensitive knob of this rescue; retune against a captured
        /// mid-night-wake night with known bed/wake truth before widening it.
        public var hrWakeRescueCeilingBPM: Double
        /// Minimum fraction of a candidate awake run's epochs that must carry SLEEP-VITALS (a raw,
        /// non-forward-filled HRV read — the ring's OWN evidence it got a clean motionless optical
        /// pass, the same signal the coarse `sleepVitalsRescue` trusts). Sized to the ~1-sleep-vitals-
        /// per-2-epochs interleave the ring emits (see the `motionAwakeVitalsHalfWindow` note above), so
        /// ≥ 0.5 means the ring was measuring sleep across the run rather than an odd stray epoch.
        public var hrWakeRescueVitalsFraction: Double

        // --- Descent-relative ONSET trim (the "mild wind-down" fix) -----------------
        // The fixed `wakeHRMarginBPM` gate (floor + 18) catches a CLEARLY elevated pre-sleep
        // block (lying in bed at 78 bpm) but MISSES the common case: HR drifting down from a
        // calm-evening level (~65) through the quiet wind-down (~55–60) into sleep (~50) — all
        // of it BELOW floor+18, so the whole pre-sleep stretch reads as asleep and efficiency
        // pins at an impossible ~100%. These knobs add a SECOND, leading-edge-only onset rule
        // keyed to the night's OWN HR descent: onset is where smoothed HR first SETTLES near the
        // floor (a fraction of the way down from the evening level) and stays there. It scales
        // per person/night (a fast sleeper with no descent is untouched) and is bounded on both
        // ends — gated on a real descent, searched only within the first window — so it can never
        // run away and trim genuine sleep as wake. Validated 2026-06-26 against a Helio strap
        // (onset matched within ~20 min) plus the night's stored summaries; SUPERVISED-FIT
        // territory, so every knob is exposed.

        /// Fraction of the evening→floor HR descent at which (smoothed) HR is taken to have
        /// "settled" into sleep. Onset band = floor + fraction × (eveningLevel − floor). 0 disables
        /// the band move (band == floor); raise toward 1 to trim more of an elevated wind-down.
        /// EMPIRICAL, non-monotonic across the whole onset pipeline (it interacts with the lead-in
        /// gate + the night-relative bands). Calibrated to 0.60 against two user-ground-truthed late-
        /// onset nights: it moves the 2026-07-16 quiet-wake lead-in from 23:39 to 01:16 (reported
        /// onset ~01:00) while changing the earlier 2026-07-12 replay by only one epoch versus 0.55.
        /// This is still not a supervised hypnogram fit; RUNBOOK_SLEEP_GROUNDTRUTH supersedes it once
        /// per-epoch labels are available.
        public var onsetSettleFraction: Double
        /// Minimum evening→floor descent (bpm) for the onset trim to fire at all. Below this there
        /// is no real wind-down to trim (the sleeper was already calm at lights-out), so the night
        /// is left byte-identical to the pre-onset-trim model. The single safety gate that keeps a
        /// flat night — where the band would otherwise cut through ordinary sleep — untouched.
        public var onsetMinDescentBPM: Double
        /// Epochs at the window head used to estimate the pre-sleep "evening level" (their median,
        /// robust to a one-epoch spike). ~12 ≈ the first 30 min in bed.
        public var onsetScanEpochs: Int
        /// The onset settle is sought ONLY within the first this-many epochs of the window; if HR
        /// never sustains below the band that early, the night is NOT trimmed (no onset guessed).
        /// Bounds the trim so a restless night that only quiets hours in can't be declared
        /// "awake until 2 a.m." ~48 ≈ 2 h.
        public var onsetSearchEpochs: Int

        // --- Point-of-no-return OFFSET (the "quiet morning wake" fix) ----------------
        // `wakeHRMarginBPM` is ONE knob doing TWO jobs: it must sit ABOVE typical REM elevation
        // (or REM reads as wake) AND catch the morning rise. When a night's morning rise is SMALLER
        // than its evening wind-down spread, no single value can do both. 🟢 MEASURED on ONE night
        // (2026-08-04, FR02.018, primary motion channel placeholder-flat on 250/253 epochs so HR was
        // the only lever; user-reported wake 08:02): margins 18→12 all leave the wake at 08:52:44;
        // 11→08:47:44; 9→08:15:14; and at 8 the ONSET COLLAPSES 00:05:14→02:02:44 (117 min of the
        // window reclassified awake), taking total asleep from 527 to 370 min. So on THIS night
        // lowering the shared knob shed more sleep at the head than it recovered at the tail. That is
        // one night, not a proof — but it is why the tail gets its own test rather than a retune.
        //
        // The trailing edge admits a threshold-LIGHT test the interior cannot use: at final wake the
        // smoothed HR rises and does not return to the sleeping floor, whereas a REM bump settles
        // back. 🟡 PROBABLE, and knowingly incomplete — a real mid-night arousal does NOT settle back
        // either, which is why the pass must not overrule `rescueSecondBoutHRWake`. See
        // `markPointOfNoReturnOffset` for the guards that follow from this.

        /// How far above the sleeping floor the ENTIRE remaining night must stay for the scan to
        /// call final wake — expressed as a FRACTION of the night's own sleeping-HR spread
        /// (`median − floor`), never an absolute bpm. **0 disables the pass entirely.**
        ///
        /// DERIVED, not absolute, for the same reason `motionAboveLocalFloor` and `derivedActiveCut`
        /// are: an absolute bpm cut cannot serve two people (or two nights) whose HR spreads differ.
        /// A sleeper whose HR barely varies gets a tight margin; a fragmented or restless night —
        /// where the median is dragged up — automatically gets a more conservative one. The resolved
        /// margin is floored at `offsetNoReturnMinMarginBPM` so a very flat night cannot derive a
        /// near-zero (hair-trigger) threshold.
        ///
        /// 🟡 PROBABLE, fit against ONE night (2026-08-04, FR02.018; user-reported wake 08:02).
        /// Measured there: fraction 0.5 → margin 3.0 bpm → wake 08:00:14 (2 min error). Absolute
        /// sweeps on the same night, for reference: 2 → 07:52:44, 3/4 → 08:00:14, 5 → 08:10:14,
        /// 6 → 08:12:44, 8 → 08:15:14, 10 → 08:47:44; `median−floor` (6.0) and IQR (7.0) both land
        /// 08:12:44. One night is one night (N8) — this is a starting point to be FIT against
        /// accumulated user sleep-edit labels (`SleepEditLabel`), not a settled value.
        public var offsetNoReturnSpreadFraction: Double

        /// Floor on the derived offset margin, in bpm. The ring reports INTEGER bpm and the wake
        /// scan runs on a rolling MEDIAN of integers, so ~1 bpm is pure quantisation; 2 bpm is twice
        /// that. Instrument-derived, not fitted.
        public var offsetNoReturnMinMarginBPM: Double

        // --- Lead-in wake ONSET (the "lay awake still for hours" fix) ----------------
        // The descent trim above keys off a clean HR DESCENT into the floor. But the hardest night
        // is lying still and AWAKE for hours with FLUCTUATING HR (the 2026-06-26 capture: HR bouncing
        // 58–99 with a clear ~90-bpm block near midnight, then sleep ~01:30). The fixed/descent gates
        // mark the clearly-elevated epochs awake, but the SHORT still dips between them read as
        // "asleep", so onset anchors to the FIRST such dip — hours before real sleep. This rule says:
        // if a SUSTAINED awake block still lies ahead within the onset search window, sleep hasn't
        // begun — push onset past the END of the LAST such block. It reuses the already-validated
        // awake detection (motion + HR gate), so it only ever moves onset past epochs ALREADY judged
        // awake, never invents wake from a quiet signal.

        /// A consolidated asleep run of at least this many epochs BEFORE a lead-in wake block means the
        /// block is a normal mid-night awakening (real sleep already happened) — so onset is NOT pushed
        /// past it. Only when no real sleep preceded the block (longest prior asleep run < this) is the
        /// block treated as part of a pre-sleep struggle. The single guard that keeps a normal night —
        /// asleep early, one brief stir — untouched. ~16 ≈ a 40-min first cycle.
        public var minConsolidatedSleepEpochs: Int

        /// When a `PersonalBaseline` is supplied to `classify`, an epoch may be DEEP only if its HR
        /// is within this many bpm of the person's TYPICAL deep-sleep HR. This caps Deep on a
        /// STRONGLY-ELEVATED night (fever, illness), whose OWN low percentile would otherwise admit
        /// "Deep" at an HR that is not deep for this person. Set DELIBERATELY WIDE so it never strips
        /// genuine Deep on a merely MILDLY-elevated night that still had real deep sleep (a hard
        /// training day, a warm room, a glass of wine run ~10–15 bpm high but still reach deep) — only
        /// a clearly anomalous night (≳ this margin above the personal floor) is suppressed. It only
        /// ever REMOVES Deep, never adds it, and is ignored entirely when no baseline is supplied, so
        /// the single-night classifier is byte-identical (the property is inert without a baseline).
        public var deepBaselineMarginBPM: Double

        // --- Bedtime widen (the "in bed == asleep / 100% efficiency" fix) ------------
        // The motion-still block defines "in bed" by STILLNESS, so a MOVING-but-awake pre-sleep
        // stretch (reading/scrolling in bed) never enters the block and inBedStart collapses onto
        // onset → efficiency reads a phantom 100%. On a fast-onset night the ring DID record that
        // lead-in (device-confirmed: motion + an elevated HR descending toward the floor, before a
        // data gap the block detector split on), it was just discarded. This reaches back over that
        // MEASURED lead-in and re-opens the in-bed envelope, leaving onset/wake — the #176 edit
        // anchors — untouched. It never fabricates a latency: with no measured awake-in-bed lead-in
        // (HR already flat at the floor, or no worn pre-onset epochs) it is a no-op and the night
        // stays 100% honestly.

        /// Max epochs (150 s each) to reach back before the detected in-bed start when re-opening the
        /// envelope over a measured awake-in-bed lead-in. `0` DISABLES the widen entirely, so every
        /// night — including the 100 %-efficiency ones — stages byte-identically to the pre-widen
        /// model (the regression escape hatch, mirroring `motionAwakeVitalsHalfWindow = 0`). ~24 ≈ 1 h.
        public var preOnsetBedtimeReachEpochs: Int
        /// Largest short sensor/history gap (in 150-second epoch intervals) that the bedtime widen
        /// may cross. A few missing epochs are common while the ring changes measurement state; a
        /// much longer awake-bordered hole remains ambiguous and must not be called time in bed.
        /// ~5 ≈ 12.5 min, covering the device-observed 2026-07-18 11-minute dropout.
        public var preOnsetBedtimeMaxGapEpochs: Int

        // --- SpO2-CADENCE wake OFFSET (the "reported wake is when you synced" fix, #190) ---------
        // Every pass above locates final wake from the SLEEPER (HR, motion, HRV density). When the
        // primary motion channel is a flat placeholder and the morning HR rise is small, all of them
        // miss, and the staged night then runs to the LAST RECORD — so the reported wake is
        // `lastRecord + 120 s`, i.e. whenever the user last synced. 🟢 MEASURED on 2026-08-09
        // (FR02.018, build 39): truncating the same capture in 49 five-minute steps moved reported
        // sleep 367 → 625 min, one +5 per step, with no byte of physiology changed.
        //
        // This pass locates the wake from the RING instead. While the ring runs its sleep-measurement
        // program it takes an SpO2 reading every 300 s, which makes consecutive 150-second epochs
        // alternate sleep-vitals / activity 1:1 (`BulkRecord.layout`). That duty cycle EXITS near
        // wake. 🟢 CONFIRMED over 5650 unique records / 4 rings, re-derived independently from raw
        // frames by a second decoder with 0 byte conflicts:
        //   • sleep-vitals inter-arrival is modal at 300 s on every ring (63–84 %);
        //   • on the primary ring, activity-activity same-template pairs number 1305 against just 24
        //     sleepVitals-sleepVitals — the ring essentially never emits two SpO2 reads in a row;
        //   • the same-template ("violation") rate is 6.0 % inside the staged sleep window and 43.6 %
        //     outside it; split at the user-reported wake it goes 3.9 %→23.8 % (08-09) and
        //     1.6 %→34.8 % (08-05);
        //   • Mann-Whitney AUC 0.819–1.000 on the two labelled nights, far above every vitals channel
        //     (SpO2 0.44/0.41, RR 0.61/0.59, HRV 0.79/0.50, confidence byte 0.42/0.27).
        // Sync/drain/BLE confounds are REFUTED: 20 sync, drain and reconnect events sit strictly
        // INSIDE violation-free runs, including four successful drains inside one 5.7 h run and a BLE
        // teardown+reconnect inside 08-09's 191-epoch run. Cross-page enrichment goes to 0.0 % under
        // regime control (147 cross-page pairs inside the quiet regime, zero violations).
        //
        // ⚠️ NAME IT CORRECTLY. `raw[8]` is the SpO2 byte (PROTOCOL §5.3; APK `spo2` loc 0xb) with
        // `0x12`/`0x13` as "no SpO2 here" sentinels. `layout` is a discriminator COMPUTED at
        // `BulkSleep.layout`, not a device mode tag — this is an SpO2-CADENCE rule, and any change to
        // that discriminator's fall-through silently moves it.

        /// Minimum length, in epochs, of the unbroken sleep-vitals/activity ALTERNATION that the wake
        /// locator will trust as "the ring was running its sleep-measurement program here". The wake
        /// candidate is the epoch immediately after the LAST such run. **0 DISABLES the pass entirely
        /// — byte-identical to the pre-cadence staging** (the regression escape hatch every other
        /// pass in this file carries: `motionAwakeVitalsHalfWindow`, `hrWakeRescueCeilingBPM`,
        /// `preOnsetBedtimeReachEpochs`, `offsetNoReturnSpreadFraction`).
        ///
        /// 🟢 The admissible band is MEASURED, not guessed. Sweeping K over the 16-night local corpus
        /// gives, per night, the closed interval of K that yields the SAME committed cut:
        /// 08-09 [12,191] · 08-05 [7,119] · 08-05(export) [6,119] · 08-04 [6,27] · 08-04(export)
        /// [6,27] · 08-02 [2,40] · 06-27 [4,161] · 06-30 [2,137]. The binding constraints are
        /// 08-09's 11-epoch post-wake quiet run (K must exceed it) and 08-04's 27-epoch final run
        /// (K must not exceed it), so every night in the corpus agrees for K ∈ [12, 27]. 20 is the
        /// value that MAXIMISES the worst-case headroom over that corpus (7 epochs ≈ 17 min either
        /// side); 12 — the value a naive `minConsolidatedSleepEpochs` reuse would pick — sits on a
        /// ONE-epoch margin worth 43 minutes on 08-09.
        ///
        /// 🟡 The corpus behind that band is 16 nights / 5 rings, but the two nights carrying WAKE
        /// GROUND TRUTH are the same person on the same ring (08-09 → 09:06, 08-05 → 08:02). That is
        /// below this project's own evidence bar; see `docs/RUNBOOK_SLEEP_GROUNDTRUTH.md` and
        /// `SleepEditLabel` for the supervised labels that should re-fit it.
        public var cadenceWakeQuietEpochs: Int

        /// Upper bound, in epochs, on a quiet run the locator will trust. A run LONGER than this is
        /// not a night's sleep-measurement program — it is a ring left in continuous SpO2 mode, and
        /// its "end" carries no information about when anyone woke up.
        ///
        /// 🔴 This gate does NOT fire anywhere in the local corpus (the longest trusted run is 191
        /// epochs ≈ 7.96 h, on 08-09). It exists because the corpus DID produce the failure it guards
        /// against: ring `u4` holds the 300 s cadence for a continuous 11.96 h — timezone-independent,
        /// no zone makes that a night. On that ring the run happens to reach the data edge, which the
        /// locator already declines; this bound is what stops the same ring being cut at a stray
        /// violation once more data drains in behind it. 240 ≈ 10 h, i.e. above every real night
        /// measured here and below the u4 regime.
        public var cadenceWakeMaxQuietEpochs: Int

        // --- Wear gate on the STAGED path (#41 / #194) ------------------------------
        // `BulkSleep.mainSleep` has always accepted `temperatures:` so an off-wrist / charging
        // block — perfectly still, and so indistinguishable from a night by motion alone — can be
        // reclassified `.active` (#41). The COARSE path (`BulkSleep.sleepSegments`) and the
        // night-SCOPING pass (`BulkSleep.latestNightRecords`) both pass it; `classifyContiguous`
        // did not, so the gate was inert on the path that actually produces the hypnogram and the
        // two paths could disagree about what counts as a worn night. Threading the samples is the
        // whole fix; this flag is its kill switch.

        /// Whether the staged path honours the skin-temperature wear gate. `false` DROPS the samples
        /// at the `classifyContiguous` boundary, restoring the pre-#194 behaviour byte-identically
        /// (the regression escape hatch every other pass in this file carries). Inert either way
        /// when the caller passes no temperature samples — which is why the local corpus is
        /// byte-identical with it ON: every persisted sample there reads WORN (🟢 24 073 samples
        /// across the 7 export bundles, min 28.00 °C, none below the 28 °C `wornMinTemperatureC`
        /// line), because the store persists worn readings only and the cold ones live in
        /// `RingSession.nightTemperatureLog`, which no export carries. The evidence for the flip is
        /// therefore a synthetic unworn block over REAL night bytes, not a corpus night. See #194.
        public var stagedWearGate: Bool

        public init(awakeMotion: Int = 15,
                    deepHRPercentile: Double = 0.42,
                    remHRPercentile: Double = 0.86,
                    deepVarPercentile: Double = 0.50,
                    remVarPercentile: Double = 0.84,
                    variabilityHalfWindow: Int = 2,
                    deepVarFloor: Double = 2.5,
                    remVarFloor: Double = 3.0,
                    minDeepRunEpochs: Int = 3,
                    minREMRunEpochs: Int = 2,
                    minAwakeRunEpochs: Int = 1,
                    hrvVarWeight: Double = 0.5,
                    rrVarWeight: Double = 0,
                    sleepFloorPercentile: Double = 0.12,
                    wakeHRMarginBPM: Double = 18,
                    hrWakeHalfWindow: Int = 2,
                    motionAwakeVitalsHalfWindow: Int = 3,
                    onsetSustainEpochs: Int = 6,
                    minHRWakeRunEpochs: Int = 5,
                    hrWakeRescueCeilingBPM: Double = 25,
                    hrWakeRescueVitalsFraction: Double = 0.5,
                    onsetSettleFraction: Double = 0.60,
                    onsetMinDescentBPM: Double = 10,
                    onsetScanEpochs: Int = 12,
                    onsetSearchEpochs: Int = 48,
                    offsetNoReturnSpreadFraction: Double = 0.5,
                    offsetNoReturnMinMarginBPM: Double = 2,
                    minConsolidatedSleepEpochs: Int = 16,
                    deepBaselineMarginBPM: Double = 18,
                    preOnsetBedtimeReachEpochs: Int = 24,
                    preOnsetBedtimeMaxGapEpochs: Int = 5,
                    cadenceWakeQuietEpochs: Int = 20,
                    cadenceWakeMaxQuietEpochs: Int = 240,
                    stagedWearGate: Bool = true) {
            self.awakeMotion = awakeMotion
            self.deepHRPercentile = deepHRPercentile
            self.remHRPercentile = remHRPercentile
            self.deepVarPercentile = deepVarPercentile
            self.remVarPercentile = remVarPercentile
            self.variabilityHalfWindow = variabilityHalfWindow
            self.deepVarFloor = deepVarFloor
            self.remVarFloor = remVarFloor
            self.minDeepRunEpochs = minDeepRunEpochs
            self.minREMRunEpochs = minREMRunEpochs
            self.minAwakeRunEpochs = minAwakeRunEpochs
            self.hrvVarWeight = hrvVarWeight
            self.rrVarWeight = rrVarWeight
            self.sleepFloorPercentile = sleepFloorPercentile
            self.wakeHRMarginBPM = wakeHRMarginBPM
            self.hrWakeHalfWindow = hrWakeHalfWindow
            self.motionAwakeVitalsHalfWindow = motionAwakeVitalsHalfWindow
            self.onsetSustainEpochs = onsetSustainEpochs
            self.minHRWakeRunEpochs = minHRWakeRunEpochs
            self.hrWakeRescueCeilingBPM = hrWakeRescueCeilingBPM
            self.hrWakeRescueVitalsFraction = hrWakeRescueVitalsFraction
            self.onsetSettleFraction = onsetSettleFraction
            self.onsetMinDescentBPM = onsetMinDescentBPM
            self.onsetScanEpochs = onsetScanEpochs
            self.onsetSearchEpochs = onsetSearchEpochs
            self.offsetNoReturnSpreadFraction = offsetNoReturnSpreadFraction
            self.offsetNoReturnMinMarginBPM = offsetNoReturnMinMarginBPM
            self.minConsolidatedSleepEpochs = minConsolidatedSleepEpochs
            self.deepBaselineMarginBPM = deepBaselineMarginBPM
            self.preOnsetBedtimeReachEpochs = preOnsetBedtimeReachEpochs
            self.preOnsetBedtimeMaxGapEpochs = preOnsetBedtimeMaxGapEpochs
            self.cadenceWakeQuietEpochs = cadenceWakeQuietEpochs
            self.cadenceWakeMaxQuietEpochs = cadenceWakeMaxQuietEpochs
            self.stagedWearGate = stagedWearGate
        }

        public static let `default` = Tuning()
    }

    /// A person's rolling, multi-night HR baseline. RingConn's on-device staging is believed to key its
    /// stages off multi-day personalized baselines (🟡 probable — `hrAvg7Days`/`hrvAvg7Days` fields read
    /// from the v3.2.1 APK data model; exact use + thresholds NOT recoverable, see memory
    /// `ringconn-sleep-is-on-device`), where ours historically used single-night percentiles only. A
    /// single-night percentile is fragile on an
    /// ATYPICAL night: when the WHOLE night runs elevated (fever, alcohol, illness), the night's own
    /// lowest epochs still look "deep" relative to that night, so Deep is assigned at an HR that is not
    /// deep for the person. Anchoring the Deep band to the person's typical deep-sleep HR fixes that.
    /// Optional everywhere — absent it, staging is exactly the single-night classifier as before.
    public struct PersonalBaseline: Sendable, Equatable {
        /// The person's TYPICAL deep-sleep heart rate (bpm), across recent nights — the personal
        /// "sleeping floor" the Deep band anchors to (see `Tuning.deepBaselineMarginBPM`).
        public let deepSleepHR: Double

        public init(deepSleepHR: Double) { self.deepSleepHR = deepSleepHR }

        /// Build from recent nights' per-night deep-sleep HR means (e.g. `StoredSleepSummary.hrDeep`).
        /// Uses the MEDIAN — robust to a single outlier night (a fever night, or a night with no real
        /// Deep) — and ignores non-positive entries (a night with no detected Deep contributes nothing).
        /// Returns `nil` when fewer than `minNights` valid nights exist: too little history to
        /// personalize, so the caller stays on single-night staging until the baseline is trustworthy.
        public static func fromRecentDeepHR(_ deepHRs: [Int], minNights: Int = 3) -> PersonalBaseline? {
            let valid = deepHRs.filter { $0 > 0 }.map(Double.init).sorted()
            guard valid.count >= minNights else { return nil }
            // True median (average the two central values for an even count) — an upper-median would
            // bias the ceiling upward (weaker suppression) on the common even-count windows.
            let mid = valid.count / 2
            let median = valid.count.isMultiple(of: 2) ? (valid[mid - 1] + valid[mid]) / 2 : valid[mid]
            return PersonalBaseline(deepSleepHR: median)
        }
    }

    /// Per-stage durations for a night, plus convenience totals. `inBed` is the whole
    /// detected window; `totalAsleep` excludes Awake (and the overlapping inBed span).
    public struct Summary: Equatable, Sendable {
        public let inBed: TimeInterval
        public let awake: TimeInterval
        public let light: TimeInterval
        public let deep: TimeInterval
        public let rem: TimeInterval

        public init(inBed: TimeInterval, awake: TimeInterval,
                    light: TimeInterval, deep: TimeInterval, rem: TimeInterval) {
            self.inBed = inBed; self.awake = awake
            self.light = light; self.deep = deep; self.rem = rem
        }

        /// Time actually asleep = Light + Deep + REM.
        public var totalAsleep: TimeInterval { light + deep + rem }
        /// Sleep efficiency = asleep / in-bed, 0…1 (0 if no in-bed window).
        public var efficiency: Double { inBed > 0 ? totalAsleep / inBed : 0 }

        /// The same numbers in whole minutes, handy for dashboards/sanity checks.
        public var minutes: (inBed: Int, awake: Int, light: Int, deep: Int, rem: Int, asleep: Int) {
            func m(_ t: TimeInterval) -> Int { Int((t / 60).rounded()) }
            return (m(inBed), m(awake), m(light), m(deep), m(rem), m(totalAsleep))
        }
    }

    /// Classify a night's records into `inBed` + Awake/Light(core)/Deep/REM segments.
    /// Returns `[]` when no sleep block (≥1 h still) is detected.
    ///
    /// STITCHING: a night handed off across several drains (the ring buffers only ~4.75 h and drops
    /// the oldest; each sync drains a partial slice) arrives as CONTIGUOUS runs separated by data gaps.
    /// Each run is staged independently and the segments concatenated, so the whole captured night is
    /// kept — not just one block. Without this, a single gap split the night and only the latest
    /// fragment survived (the "sleep shrinks on every sync" bug). Each fragment carries its own `inBed`
    /// segment (gaps are NOT counted as in-bed); `summary` sums them. A single-fragment input (every
    /// existing caller of a contiguous night, and every unit test) is staged exactly as before.
    ///
    /// WEAR GATE (#41 / #194): pass `temperatures:` — the night's skin-temp samples INCLUDING the
    /// cold/charging ones — so an off-wrist block can't masquerade as a night. It is the SAME set
    /// the coarse `BulkSleep.sleepSegments` and the night-scoping `BulkSleep.latestNightRecords`
    /// already take; omitting it here (as every caller did before #194) left the gate inert on the
    /// path that produces the hypnogram while the other two enforced it, so the two could disagree
    /// about what counts as a worn night. Empty ⇒ motion-only, exactly as before: absence of
    /// temperature data is not evidence of being unworn.
    public static func classify(from records: [BulkRecord],
                                temperatures: [TemperatureSample] = [],
                                epoch: Int = Command.syncEpoch,
                                tuning: Tuning = .default,
                                baseline: PersonalBaseline? = nil) -> [SleepSegment] {
        let temps = tuning.stagedWearGate ? temperatures : []
        let frags = BulkSleep.contiguousFragments(records)
        let staged: [SleepSegment] = frags.count > 1
            ? frags.flatMap { classifyContiguous(from: $0, temperatures: temps, epoch: epoch,
                                                 tuning: tuning, baseline: baseline) }
                   .sorted { $0.start < $1.start }
            : classifyContiguous(from: records, temperatures: temps, epoch: epoch,
                                 tuning: tuning, baseline: baseline)
        // Re-open the in-bed envelope over a MEASURED pre-onset awake-in-bed lead-in the still-block
        // missed (the "inBed == asleep / 100 % efficiency" fix). Runs over the FULL record set so it
        // sees a lead-in that a data gap split into a discarded fragment. No-op when the knob is 0.
        return applyBedtimeWiden(staged, records: records, epoch: epoch, tuning: tuning)
    }

    /// Extend the in-bed envelope back over a MEASURED awake-in-bed lead-in that the motion still-block
    /// missed — a moving/reading-in-bed stretch before onset — so a fast-onset night stops reporting a
    /// phantom 100 % efficiency. Guarantees (each verified by a test):
    ///   • ONSET/WAKE UNTOUCHED — only the first `.inBed` segment's start moves and a leading `.awake`
    ///     is prepended; the asleep segments (and thus `sleepOnset`/`sleepWake`, the #176 edit anchors)
    ///     are byte-identical. So this widens `inBed`/`awake`/lowers efficiency, never re-times sleep.
    ///   • FAST-ONSET ONLY — fires only when the in-bed envelope already opens exactly at onset (no
    ///     pre-onset `.awake`). A 07-11-style night (a detected still-but-awake lead-in) is untouched.
    ///   • MEASURED, NOT FABRICATED — `preOnsetBedStart` widens only on real worn epochs carrying an
    ///     elevated (awake) HR; with no such lead-in it returns nil and the night stays as staged.
    ///   • BYTE-IDENTICAL WHEN OFF — `preOnsetBedtimeReachEpochs == 0` short-circuits to `segments`.
    private static func applyBedtimeWiden(_ segments: [SleepSegment], records: [BulkRecord],
                                          epoch: Int, tuning: Tuning) -> [SleepSegment] {
        guard tuning.preOnsetBedtimeReachEpochs > 0, !segments.isEmpty else { return segments }
        let asleep: Set<SleepStage> = [.asleepCore, .asleepDeep, .asleepREM]
        guard let onset = segments.filter({ asleep.contains($0.stage) }).map(\.start).min(),
              let inBedIdx = segments.firstIndex(where: {
                  $0.stage == .inBed && $0.start <= onset && onset < $0.end
              })
        else { return segments }
        // Fast-onset only: the envelope opens exactly at onset and nothing awake precedes it.
        guard segments[inBedIdx].start == onset,
              !segments.contains(where: { $0.stage == .awake && $0.start < onset })
        else { return segments }
        guard let bedStart = preOnsetBedStart(records: records, onset: onset, epoch: epoch, tuning: tuning),
              bedStart < onset else { return segments }
        var out = segments
        out[inBedIdx] = SleepSegment(start: bedStart, end: segments[inBedIdx].end, stage: .inBed)
        out.append(SleepSegment(start: bedStart, end: onset, stage: .awake))
        return out.sorted { $0.start < $1.start }
    }

    /// The earliest time we can HONESTLY call "in bed" before `onset`. Walks worn epochs backward from
    /// onset, bridging small data gaps (or a larger gap only while HR stays at sleep level on both
    /// sides — asleep across it, so bridging doesn't invent bed time during an up-and-about spell), and
    /// widens ONLY if the run contains at least one genuinely-awake epoch (HR ≥ sleeping floor + wake
    /// margin). Returns nil — no widen — when no measured awake-in-bed lead-in exists (the honest
    /// fast-onset outcome), bounding the reach to `preOnsetBedtimeReachEpochs`.
    private static func preOnsetBedStart(records: [BulkRecord], onset: Date, epoch: Int,
                                         tuning: Tuning) -> Date? {
        let interval = TimeInterval(BulkRecord.epochSeconds)   // 0x96 = 150 s, canonical
        let reach = onset.addingTimeInterval(-Double(tuning.preOnsetBedtimeReachEpochs) * interval)
        // Sleeping floor from the first ~2 h after onset (the same low-percentile basis classify uses).
        let sleepHR = records
            .filter { let t = $0.date(epoch: epoch); return t >= onset && t < onset.addingTimeInterval(2 * 3600) }
            .compactMap(\.heartRate).map(Double.init)
        guard sleepHR.count >= 4 else { return nil }
        let floor = percentile(sleepHR.sorted(), tuning.sleepFloorPercentile)
        let wakeThreshold = floor + tuning.wakeHRMarginBPM
        // HR at onset seeds the first gap's asleep-bridge test (defaults to the floor if not found —
        // floor ≤ threshold, so a genuinely-asleep first gap still bridges).
        let onsetHR = records.first { abs($0.date(epoch: epoch).timeIntervalSince(onset)) < 1 }?
            .heartRate.map(Double.init) ?? floor
        // Worn epochs strictly before onset within reach, nearest-first (descending time).
        let pre = records
            .filter { r in
                let t = r.date(epoch: epoch)
                return t < onset && t >= reach && r.heartRate != nil
            }
            .sorted { $0.counter > $1.counter }
        guard !pre.isEmpty else { return nil }
        var bedStart: Date?
        var sawAwake = false
        var prevTime = onset
        var prevHR = onsetHR
        for r in pre {
            let t = r.date(epoch: epoch)
            let hr = Double(r.heartRate!)
            let gap = prevTime.timeIntervalSince(t)
            // Tolerate a SHORT dropout (real 0x4c streams can miss several epochs while changing
            // measurement state) so measured awake lead-in is not discarded. Longer gaps still
            // require sleep-level HR on both sides and therefore retain the anti-fabrication guard.
            let maxShortGap = interval * Double(max(1, tuning.preOnsetBedtimeMaxGapEpochs))
            let contiguous = gap <= maxShortGap
            let asleepBridge = hr <= wakeThreshold && prevHR <= wakeThreshold
            guard contiguous || asleepBridge else { break }
            bedStart = t
            if hr >= wakeThreshold { sawAwake = true }
            prevTime = t
            prevHR = hr
        }
        return sawAwake ? bedStart : nil
    }

    /// Stage ONE contiguous record run (no internal data gaps) into `inBed` + stage segments.
    private static func classifyContiguous(from records: [BulkRecord],
                                           temperatures: [TemperatureSample] = [],
                                           epoch: Int = Command.syncEpoch,
                                           tuning: Tuning = .default,
                                           baseline: PersonalBaseline? = nil) -> [SleepSegment] {
        // `temperatures:` is the #41 wear gate, and `mainSleep` is the ONLY place it acts — an
        // off-wrist/charging block is reclassified out of sleep there. Dropping the argument here
        // (pre-#194) is what made the staged hypnogram disagree with both the coarse segments and
        // the night scoping, which pass it. Empty ⇒ motion-only, unchanged.
        guard let block = BulkSleep.mainSleep(from: records, temperatures: temperatures,
                                              epoch: epoch) else { return [] }

        // Epochs inside the in-bed window, forward-filling HR/HRV across dropped reads.
        let inBlock = records
            .filter { $0.date(epoch: epoch) >= block.start && $0.date(epoch: epoch) <= block.end }
            .sorted { $0.counter < $1.counter }
        var lastHR: Int?, lastHRV: Int?, lastSpo2: Int?, lastRR: Double?
        // `vitals` is the RAW (not forward-filled) "this epoch carried sleep-vitals HRV" flag — the
        // ring-measured-sleep signal the motion-awake softening below uses. Kept distinct from `hrv`
        // (forward-filled for variability) because forward-fill would make every post-onset epoch read
        // as sleep-vitals.
        var rows: [(time: Date, hr: Int, hrv: Int?, motion: Int, spo2: Int?, rr: Double?, vitals: Bool)] = []
        // Parallel to `rows`: the record TEMPLATE each row came from. Kept out of the tuple because it
        // is not a physiological channel — it is the ring's own SpO2 duty cycle, read by
        // `markCadenceWakeOffset` alone (#190).
        var rowLayouts: [BulkRecord.Layout] = []
        // Per-epoch motion energy is measured ABOVE a LOCAL idle floor (same rolling estimate as
        // detection). Gen 2 idles at ~1, Gen 3 at ~15–16 and DRIFTS across the night with posture
        // (16→24→39, 🟢 FR05.008 capture 2026-06-23). The old `$1 == 1 ? 0 : …` hard-coded Gen 2's
        // flat `1`, so every still Gen-3 epoch summed to ~75 and the `awakeMotion` gate marked the
        // WHOLE night awake → `sleepSpan` found nothing → no staged segments. De-flooring against the
        // local rolling floor stays a no-op for Gen 2 (flat `1` → 0) while tracking Gen-3 drift.
        let times = inBlock.map { $0.date(epoch: epoch) }
        // Some real nights carry a constant filler in `[10:15]` for every epoch while the record's
        // intensity half still contains movement. Select that fallback only for the structurally
        // degenerate run; normal primary-motion nights remain byte-identical.
        let rawMotion = BulkSleep.motionMagnitudes(from: inBlock)
        let floor = ActivityPeriod.rollingLowPercentile(rawMotion, times: times,
                        windowSeconds: ActivityPeriod.motionFloorWindowSecondsStaging,
                        percentile: ActivityPeriod.motionFloorPercentile)
        for (idx, r) in inBlock.enumerated() {
            if let hr = r.heartRate { lastHR = hr }
            if let v = r.hrvRMSSD { lastHRV = v }
            if let s = r.spo2Percent { lastSpo2 = s }       // forward-filled like HRV
            if let rr = r.respiratoryRate { lastRR = rr }   // forward-filled like HRV
            guard let hr = lastHR else { continue }   // skip until the first HR reading
            let motion = max(0, Int(rawMotion[idx] - floor[idx]))
            rows.append((r.date(epoch: epoch), hr, lastHRV, motion, lastSpo2, lastRR, r.hrvRMSSD != nil))
            rowLayouts.append(r.layout)
        }
        guard rows.count >= 2 else { return [] }

        // --- Variability (rolling SD of HR, optionally fused with HRV) -------------
        let hr = rows.map { Double($0.hr) }
        var variability = rollingSD(hr, half: tuning.variabilityHalfWindow)
        if tuning.hrvVarWeight > 0, rows.contains(where: { $0.hrv != nil }) {
            let hrv = filledForward(rows.map { $0.hrv }).map { Double($0 ?? 0) }
            let hrvVar = rollingSD(hrv, half: tuning.variabilityHalfWindow)
            for i in variability.indices { variability[i] += tuning.hrvVarWeight * hrvVar[i] }
        }
        // Respiratory-rate variability, fused identically to the HRV term above. Defaults
        // off (rrVarWeight == 0) so the blended variability — and every stage decision —
        // is byte-identical to the pre-RR model until the weight is fit.
        if tuning.rrVarWeight > 0, rows.contains(where: { $0.rr != nil }) {
            let rr = filledForward(rows.map { $0.rr }).map { $0 ?? 0 }
            let rrVar = rollingSD(rr, half: tuning.variabilityHalfWindow)
            for i in variability.indices { variability[i] += tuning.rrVarWeight * rrVar[i] }
        }

        // --- HR-aware AWAKE: motion OR sustained HR elevation ----------------------
        // The motion still-block treats "lying still but awake" as sleep, so on its own
        // the in-bed window starts before real onset and a quiet morning wake is missed.
        // Gate on HR: awake/active HR rides well above the night's sleeping floor.
        //
        // ⚠️ THIS FLOOR DRIFTS WITH SYNC TIME, AND FIXING THAT IS A MEASURED DEAD END (#194 item 2).
        // The pool is every epoch in the motion block, and the block ends at the LAST RECORD, so
        // each drain adds post-wake epochs and creeps the low percentile up. It is real — 🟢 on
        // 2026-08-05 (FR02.018) `blockFloor` steps 53 → 54 bpm across the 5-minute trailing-edge
        // cuts — but it is NOT what moves the reported total. Re-deriving the floor from the epochs
        // up to the located wake and re-running the whole mask to a FIXED POINT was implemented and
        // measured: it converged on every night, held the floor at a constant 53 bpm across exactly
        // the cuts where the raw floor moved, and changed **nothing** — 514 truncation cuts over 6
        // nights, byte-identical output, and 17 of 18 corpus nights unchanged with the 18th (`u4`,
        // the one ring with no diagnostics bundle and an unknown timezone) losing 32 min for no
        // reason we can adjudicate.
        //
        // The 08-05 ±5 min step is `tailStart` below, not this. 🟢 With the floor pinned at 53 and
        // `sleepSpan` pinned at 39…232, the interior motion-awake epochs {55, 89, 140, 193, 221}
        // still toggled asleep↔awake cut by cut (5 → 3 → 5 → 3 → … → 0 awake in span) purely
        // because the strict span's end — hence the morning-tail softening boundary — moves as the
        // capture grows. #191 saw the same quantity flicker (`lastVitalsSoftened`, derived from
        // `tailStart`) and de-gated its pass on it for that reason. Anything aimed at this defect
        // belongs there, and must argue with the 24-test `sleepVitalsRescue` family.
        let sleepFloor = percentile(hr.sorted(), tuning.sleepFloorPercentile)
        let wakeThreshold = sleepFloor + tuning.wakeHRMarginBPM
        let smHR = rollingMedian(hr, half: tuning.hrWakeHalfWindow)
        // MOTION-awake, softened for MOVING-BUT-ASLEEP epochs — but ONLY across the MORNING TAIL, the
        // trailing stretch after the last sustained asleep run. This mirrors the coarse `sleepVitalsRescue`,
        // which only ever extends the block's END forward: the softening exists so staging doesn't re-trim
        // the rescued pre-wake morning back off via `sleepSpan`. Scoping it to the tail is what keeps a
        // genuine mid-night WASO (an interior awakening with sustained sleep AFTER it) from being absorbed
        // as sleep — only the morning is rescued, not every restless mid-night.
        let motionAwakeStrict = rows.map { $0.motion > tuning.awakeMotion }
        // Tail boundary from the STRICT (un-softened) span: the epoch just after the end of the last
        // sustained asleep run. `motionAwakeVitalsHalfWindow <= 0` disables the rescue entirely (tail =
        // end of night → no epoch is softened → byte-identical to the pre-rescue staging).
        let awakeStrict = rows.indices.map { smHR[$0] >= wakeThreshold || motionAwakeStrict[$0] }
        let tailStart = tuning.motionAwakeVitalsHalfWindow > 0
            ? (sleepSpan(awakeStrict, sustain: tuning.onsetSustainEpochs).map { $0.1 + 1 } ?? rows.count)
            : rows.count
        let vitalsNearby = windowedVitalsCoverage(times: rows.map(\.time), hasVitals: rows.map(\.vitals),
                                                  halfWindow: tuning.motionAwakeVitalsHalfWindow)
        let motionAwake = rows.indices.map { i in
            // Soften only within the trailing morning tail: the ring is still emitting sleep-vitals nearby
            // (windowed HRV coverage, robust to the sleepV/activity epoch interleave) AND HR is below the
            // wake threshold — device measuring sleep, heart agreeing. Genuine wake is unaffected: the HR
            // term below still fires on elevated HR, and sleep-vitals thin at true wake. Still nights and
            // interior WASO are untouched (motion < threshold, or i < tailStart).
            let softenTail = i >= tailStart && vitalsNearby[i] && smHR[i] < wakeThreshold
            return motionAwakeStrict[i] && !softenTail
        }
        var awake = rows.indices.map { smHR[$0] >= wakeThreshold || motionAwake[$0] }
        // Erode HR-only awake runs shorter than the floor so a transient REM-ish HR bump
        // doesn't read as an awakening (motion-driven awakes are kept, however brief).
        erodeShortHRWake(&awake, motionAwake: motionAwake, minRun: tuning.minHRWakeRunEpochs)
        // Rescue a LONG HR-only awake run that is really a SECOND SLEEP BOUT after a mid-night wake —
        // the ADD-only counterpart to the erode above, and the only pass that may relabel a night's
        // INTERIOR awake→asleep. Runs on the settled mask AFTER erosion, and BEFORE the two leading-edge
        // onset passes below (which only ever ADD leading awake) so those still get the last word at the
        // head — though the rescue's "consolidated sleep already behind it" guard means it can never
        // reach the head anyway. No-op when `hrWakeRescueCeilingBPM == 0` (byte-identical to pre-rescue).
        // Remember what the second-bout rescue reclaimed. `markPointOfNoReturnOffset` below must not
        // undo it: a second bout that sleeps at a HIGHER level than the night's floor never "returns
        // to the floor", so the offset scan would otherwise read the whole bout as final wake and
        // delete it. 🟢 MEASURED before this guard existed: a 96-epoch second bout at 71 bpm over a
        // 50 bpm floor lost all 240 min (total asleep 485 → 245) at k=4.
        let beforeSecondBoutRescue = awake
        rescueSecondBoutHRWake(&awake, smHR: smHR, motionAwake: motionAwake,
                               vitals: rows.map(\.vitals), floor: sleepFloor, tuning: tuning)
        let lastRescuedIndex = awake.indices.last { beforeSecondBoutRescue[$0] && !awake[$0] }

        // --- Descent-relative onset: trim the quiet pre-sleep wind-down -------------
        // Mark the LEADING in-bed stretch as awake while HR is still settling DOWN toward the
        // night's floor — the calm-but-awake wind-down that sits below floor+18 and so slips
        // past the gate above (pinning efficiency at ~100%). Leading-edge only and bounded; a
        // night with no real descent is left untouched. Runs AFTER erosion so it isn't undone.
        markDescentOnsetAwake(&awake, smHR: smHR, motionAwake: motionAwake,
                              floor: sleepFloor, tuning: tuning)

        // --- Lead-in wake onset: push past a clear pre-sleep wake block -------------
        // Handles the "lay still but awake for hours, fluctuating HR" night the descent trim misses:
        // if a sustained awake block still lies ahead in the search window (and no real sleep preceded
        // it), onset hasn't happened yet — mark everything up to that block's end as awake-in-bed.
        markLeadInWakeOnset(&awake, tuning: tuning)

        // --- Point-of-no-return OFFSET: mark the trailing "never settled again" run -
        // Runs AFTER both onset passes so they keep the last word at the head, and only ever ADDS
        // trailing awake. Two earlier passes in THIS function already judged specific epochs asleep
        // against the HR gate, and the offset scan must not overturn either of them:
        //   • `rescueSecondBoutHRWake` — a second bout after a mid-night wake.
        //   • the motion-awake VITALS SOFTENING above — a moving-but-asleep morning the ring was
        //     still measuring sleep vitals through (`motionAwakeStrict[i] && !motionAwake[i]`).
        // `notBefore` is the later of the two, so the scan may only cut AFTER both.
        let lastVitalsSoftened = rows.indices.last { motionAwakeStrict[$0] && !motionAwake[$0] }
        let notBefore = [lastRescuedIndex, lastVitalsSoftened].compactMap { $0 }.max()
        markPointOfNoReturnOffset(&awake, smHR: smHR, floor: sleepFloor,
                                  margin: resolvedOffsetMargin(hr: hr, floor: sleepFloor, tuning: tuning),
                                  vitals: rows.map(\.vitals),
                                  notBefore: notBefore, tuning: tuning)

        // --- SpO2-CADENCE OFFSET: where the ring LEFT its sleep-measurement program -
        // The LOCATOR the pass above lacks (#190). Everything before this point reads the sleeper;
        // this reads the RING. Runs AFTER the HR pass, and like it only ever ADDS trailing awake, so
        // whichever of the two cuts EARLIER wins and neither can undo an onset pass or a rescue. It
        // is bound by `lastRescuedIndex` — but DELIBERATELY NOT by `lastVitalsSoftened`. See the
        // "WHY NOT `notBefore`" note on `markCadenceWakeOffset`: gating this pass on the softening
        // is what made the whole result oscillate with sync time (🟢 measured, three sign changes and
        // a 47-minute swing on 08-05 from 25 minutes of extra data).
        markCadenceWakeOffset(&awake,
                              cadence: cadenceSteps(times: rows.map(\.time), layouts: rowLayouts),
                              smHR: smHR, floor: sleepFloor,
                              margin: resolvedOffsetMargin(hr: hr, floor: sleepFloor, tuning: tuning),
                              notBefore: lastRescuedIndex, tuning: tuning)

        // --- ONSET / OFFSET: trim leading & trailing awake -------------------------
        // The kept window runs from the start of the first SUSTAINED asleep run to the
        // end of the last one; everything outside is pre-sleep / post-wake awake-in-bed
        // and is dropped. This is what shrinks an over-wide motion window (e.g.
        // 23:01→09:34 with hours of quiet wakefulness) back to the real night.
        guard let (lo, hi) = sleepSpan(awake, sustain: tuning.onsetSustainEpochs) else { return [] }
        let windowStart = rows[lo].time
        let windowEnd = (hi + 1 < rows.count) ? rows[hi + 1].time : block.end

        // --- Night-relative bands from the IN-WINDOW asleep distribution -----------
        // Computed over [lo, hi] asleep epochs only, so trimmed pre-sleep wakefulness no
        // longer pollutes the percentiles (which previously dragged the bands up and
        // collapsed Deep to a few minutes).
        let windowIdx = Array(lo...hi)
        let asleepIdx = windowIdx.filter { !awake[$0] }
        let pool = asleepIdx.count >= 4 ? asleepIdx : windowIdx
        let hrPool = pool.map { hr[$0] }.sorted()
        let varPool = pool.map { variability[$0] }.sorted()

        let deepHR = percentile(hrPool, tuning.deepHRPercentile)
        let remHR = percentile(hrPool, tuning.remHRPercentile)
        let deepVar = max(percentile(varPool, tuning.deepVarPercentile), tuning.deepVarFloor)
        let remVar = max(percentile(varPool, tuning.remVarPercentile), tuning.remVarFloor)

        // --- Per-epoch decision (over the kept window) -----------------------------
        // Personal-baseline DEEP ceiling: with a multi-night baseline, an epoch may be Deep only if its
        // HR is within `deepBaselineMarginBPM` of the person's typical deep-sleep HR. nil baseline ⇒ no
        // ceiling ⇒ byte-identical to the single-night classifier. Only ever REMOVES Deep (relabels to
        // REM/Light by the same rules below), so a globally-elevated night can't read its non-deep
        // troughs as Deep just because they're the lowest THAT night.
        let deepCeiling = baseline.map { $0.deepSleepHR + tuning.deepBaselineMarginBPM }
        var stages: [SleepStage] = windowIdx.map { i in
            if awake[i] { return .awake }
            // A calm, low-variability trough is deep-LIKE by the night's own bands.
            if hr[i] <= deepHR && variability[i] <= deepVar {
                // It's real Deep only if also near the PERSON's deep HR (when a baseline exists). A calm
                // trough too elevated for this person is NOT Deep — but it is Light, NOT REM: REM needs
                // HR elevation OR variability, and this epoch is flat. Returning Light here (rather than
                // letting it fall through to the REM test, where a flat elevated night has remHR ≈ the
                // flat HR and the whole night would absurdly read as REM) keeps the relabel physiological.
                let nearPersonalDeep = deepCeiling.map { hr[i] <= $0 } ?? true
                return nearPersonalDeep ? .asleepDeep : .asleepCore
            }
            if hr[i] >= remHR || variability[i] > remVar { return .asleepREM }
            return .asleepCore
        }
        smooth(&stages, tuning)

        // --- Emit segments tiling the FULL motion (time-in-bed) window -------------
        // RingConn's two-window model: the BEDTIME window [block.start, block.end] is the
        // full time in bed; the HR-trimmed SLEEP window [windowStart, windowEnd] is
        // onset→final-wake. Efficiency = time-asleep / time-in-bed, so inBed MUST be the
        // full bedtime window — the pre-onset and post-offset spans are awake-IN-BED, not
        // dropped (dropping them inflated efficiency to ~100%). The returned segments tile
        // [block.start, block.end] with no gaps/overlaps:
        //   [inBed(full)] + [pre-awake?] + [onset→offset staged] + [post-awake?].
        var segs = [SleepSegment(start: block.start, end: block.end, stage: .inBed)]
        // Pre-sleep awake-in-bed: lying in bed before real onset.
        if windowStart > block.start {
            segs.append(SleepSegment(start: block.start, end: windowStart, stage: .awake))
        }
        var k = 0
        while k < windowIdx.count {
            var j = k
            while j + 1 < windowIdx.count && stages[j + 1] == stages[k] { j += 1 }
            // Fully tile [windowStart, windowEnd] so staged segments partition the sleep
            // window (else efficiency is mis-stated): clamp the first segment's start to
            // windowStart and the last segment's end to windowEnd.
            let segStart = (k == 0) ? windowStart : rows[windowIdx[k]].time
            let segEnd = (j + 1 < windowIdx.count) ? rows[windowIdx[j + 1]].time : windowEnd
            segs.append(SleepSegment(start: segStart, end: min(segEnd, windowEnd), stage: stages[k]))
            k = j + 1
        }
        // Post-wake awake-in-bed: lingering in bed after the final wake.
        if block.end > windowEnd {
            segs.append(SleepSegment(start: windowEnd, end: block.end, stage: .awake))
        }
        return segs
    }

    /// Total time spent in each stage across the night. The overlapping `inBed` span is
    /// excluded so the asleep stages sum to time-asleep.
    public static func stageTotals(_ segments: [SleepSegment]) -> [SleepStage: TimeInterval] {
        var out: [SleepStage: TimeInterval] = [:]
        for s in segments where s.stage != .inBed { out[s.stage, default: 0] += s.duration }
        return out
    }

    /// Roll the segments up into a `Summary` (per-stage durations + total asleep).
    public static func summary(_ segments: [SleepSegment]) -> Summary {
        let t = stageTotals(segments)
        let awake: TimeInterval = t[.awake] ?? 0
        let light: TimeInterval = t[.asleepCore] ?? 0
        let deep: TimeInterval = t[.asleepDeep] ?? 0
        let rem: TimeInterval = t[.asleepREM] ?? 0
        let staged = awake + light + deep + rem
        // Sum ALL in-bed segments: a stitched multi-fragment night carries one per fragment, and the
        // inter-fragment data gaps must NOT count as in-bed (they'd understate efficiency as phantom
        // wake). A single-fragment night has exactly one, so this is unchanged for it.
        let inBedSum = segments.filter { $0.stage == .inBed }.reduce(0) { $0 + $1.duration }
        let inBed = inBedSum > 0 ? inBedSum : staged
        return Summary(inBed: inBed, awake: awake, light: light, deep: deep, rem: rem)
    }

    /// Convenience: total time asleep (Light + Deep + REM) for a set of segments.
    public static func totalAsleep(_ segments: [SleepSegment]) -> TimeInterval {
        let t = stageTotals(segments)
        return (t[.asleepCore] ?? 0) + (t[.asleepDeep] ?? 0) + (t[.asleepREM] ?? 0)
    }

    /// The actual SLEEP window: from the first asleep epoch (real onset) to the end of the last
    /// asleep epoch (final wake). Distinct from the IN-BED window (segment min…max), which also
    /// spans the pre-sleep and post-wake awake-in-bed time. `nil` when nothing is asleep. The gap
    /// between in-bed start and `onset` is the sleep latency; this is what lets the card say "fell
    /// asleep at X / woke at Y" rather than implying the whole bedtime was sleep.
    public static func sleepWindow(_ segments: [SleepSegment]) -> (onset: Date, wake: Date)? {
        let asleep = segments.filter {
            $0.stage == .asleepCore || $0.stage == .asleepDeep || $0.stage == .asleepREM
        }
        guard let onset = asleep.map(\.start).min(), let wake = asleep.map(\.end).max() else { return nil }
        return (onset, wake)
    }

    // MARK: - Helpers

    /// Relabel sub-minimum Deep/REM/Awake runs to Light, so stages don't flap epoch to
    /// epoch (real stages persist for minutes).
    private static func smooth(_ stages: inout [SleepStage], _ t: Tuning) {
        let n = stages.count
        var i = 0
        while i < n {
            var j = i
            while j + 1 < n && stages[j + 1] == stages[i] { j += 1 }
            let run = j - i + 1
            let minRun: Int?
            switch stages[i] {
            case .asleepDeep: minRun = t.minDeepRunEpochs
            case .asleepREM:  minRun = t.minREMRunEpochs
            case .awake:      minRun = t.minAwakeRunEpochs
            default:          minRun = nil
            }
            if let m = minRun, run < m {
                for k in i ... j { stages[k] = .asleepCore }
            }
            i = j + 1
        }
    }

    /// Centered rolling MEDIAN over a ±`half`-epoch window. Robust to single-epoch HR
    /// spikes, so the wake gate keys off a sustained level rather than a transient.
    private static func rollingMedian(_ xs: [Double], half: Int) -> [Double] {
        let n = xs.count
        guard n > 0 else { return [] }
        var out = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let s = max(0, i - half), e = min(n - 1, i + half)
            var w = Array(xs[s ... e]); w.sort()
            out[i] = w[w.count / 2]
        }
        return out
    }

    /// Per-epoch "the ring is still emitting sleep-vitals nearby" flag: true when a sleep-vitals
    /// (HRV-bearing) epoch sits within `halfWindow` epochs on either side. Robust to the sleepV/activity
    /// epoch interleave (only ~1 in 2 epochs carries HRV), so a single missed slot doesn't read as wake.
    /// `halfWindow <= 0` disables it (all false → motion-awake softening is a no-op).
    private static func windowedVitalsCoverage(times: [Date], hasVitals: [Bool], halfWindow: Int) -> [Bool] {
        let n = times.count
        guard n > 0, hasVitals.count == n, halfWindow > 0 else { return [Bool](repeating: false, count: n) }
        var out = [Bool](repeating: false, count: n)
        for i in 0 ..< n {
            let s = max(0, i - halfWindow), e = min(n - 1, i + halfWindow)
            out[i] = (s ... e).contains { hasVitals[$0] }
        }
        return out
    }

    /// Relabel awake runs that are driven ONLY by HR elevation (no motion epoch inside)
    /// and shorter than `minRun` back to asleep, so a transient REM-ish HR bump doesn't
    /// read as an awakening. A run containing any motion-awake epoch is left untouched.
    private static func erodeShortHRWake(_ awake: inout [Bool], motionAwake: [Bool], minRun: Int) {
        let n = awake.count
        var i = 0
        while i < n {
            guard awake[i] else { i += 1; continue }
            var j = i
            while j + 1 < n && awake[j + 1] { j += 1 }
            let run = j - i + 1
            let hasMotion = (i ... j).contains { motionAwake[$0] }
            if run < minRun && !hasMotion { for k in i ... j { awake[k] = false } }
            i = j + 1
        }
    }

    /// Relabel a LONG, motion-free, HR-only awake stretch back to asleep when it is a SECOND SLEEP
    /// BOUT after a mid-night wake, not a genuine awakening. The complement of `erodeShortHRWake`
    /// (which reaches only runs shorter than `minHRWakeRunEpochs`), and the ONLY pass that may remove
    /// awake from a night's INTERIOR — so it is fenced by five conjunctive guards, each blocking a
    /// distinct false positive, and it only ever ADDS sleep:
    ///   (a) KILL-SWITCH — `hrWakeRescueCeilingBPM <= 0` disables it entirely (byte-identical to the
    ///       pre-rescue staging).
    ///   (b) MOTION-FREE — the candidate is a maximal MOTION-FREE sub-run of awake epochs, so any
    ///       `motionAwake` epoch splits it and can never be rescued. This is what keeps the getting-up
    ///       itself awake: on the tester's night the 10-min bathroom trip (motion) and the sleep that
    ///       follows it (HR-only awake) are ONE contiguous awake run; we rescue only the still tail
    ///       AFTER the last movement, leaving the trip correctly scored as wake. A restless genuine
    ///       awakening — which keeps moving — is never rescued at all.
    ///   (c) LONG ONLY — only sub-runs `>= minHRWakeRunEpochs`, so erosion (shorter) and this rescue
    ///       (longer) are strictly complementary with no overlap.
    ///   (d) REAL SLEEP ALREADY BEHIND IT — a consolidated asleep run of `>= minConsolidatedSleepEpochs`
    ///       must exist somewhere before the sub-run (the same guard `markLeadInWakeOnset` uses to tell
    ///       a mid-night awakening from a pre-sleep struggle; the scan looks past the intervening
    ///       getting-up motion to the first bout). This structurally guarantees the leading edge is
    ///       never touched, so onset detection and the two onset passes below keep byte-identical
    ///       inputs — and it is exactly what spares a genuine lie-awake-first night (2026-06-26), whose
    ///       awake block has NO consolidated sleep before it.
    ///   (e) RING MEASURING SLEEP, HR ONLY MILDLY ELEVATED — EVERY epoch of the sub-run has
    ///       `smHR < floor + hrWakeRescueCeilingBPM` (an above-ceiling arousal splits the sub-run and
    ///       stays awake, so a spike is never averaged away), AND the fraction of sub-run epochs carrying
    ///       raw sleep-vitals is `>= hrWakeRescueVitalsFraction` (the ring's own clean-optical-read
    ///       signal, as trusted by the coarse `sleepVitalsRescue`). Because a motion-free awake epoch
    ///       already has `smHR >= floor + wakeHRMarginBPM`, the rescued band is exactly [+wakeHRMargin,
    ///       +rescueCeiling) — a still, measured, only-mildly-elevated second bout.
    /// The backward scan for guard (d) sees any sub-run this pass ALREADY rescued as asleep, so a night
    /// with two successive mid-night wakes has its second bout support the third — correct by construction.
    ///
    /// HONEST LIMIT (signal ceiling): in the [+wakeHRMargin, +rescueCeiling) band the ring's HR + motion
    /// + vitals cannot fully separate LIGHT second-bout sleep from motionless QUIET WAKEFULNESS — a still
    /// awake wrist emits the same HRV, and its HR can sit in the same few-bpm band. This pass therefore
    /// biases toward COUNTING such a stretch as sleep (fixing the reported lost-continuation night) at
    /// the cost of occasionally over-counting a genuinely-still low-HR awakening. The narrow band, the
    /// per-epoch ceiling, and the motion/consolidated-sleep guards bound that exposure; `hrWakeRescueCeilingBPM`
    /// is the single knob that trades the two error directions (and `0` opts out entirely).
    private static func rescueSecondBoutHRWake(_ awake: inout [Bool], smHR: [Double],
                                               motionAwake: [Bool], vitals: [Bool],
                                               floor: Double, tuning: Tuning) {
        guard tuning.hrWakeRescueCeilingBPM > 0 else { return }   // (a)
        let ceiling = floor + tuning.hrWakeRescueCeilingBPM
        let n = awake.count
        var i = 0
        while i < n {
            // Seed a candidate sub-run only at an awake epoch that is motion-free AND below the ceiling,
            // and extend it only across epochs that stay both. So BOTH a movement epoch (b) and an
            // above-ceiling arousal epoch (e) terminate the sub-run and are left awake — a brief HR
            // arousal inside an otherwise-still bout splits it and is preserved as wake, rather than
            // being averaged away by a run median. Every epoch we ultimately rescue is therefore
            // individually motion-free and < ceiling.
            guard awake[i], !motionAwake[i], smHR[i] < ceiling else { i += 1; continue }
            var j = i
            while j + 1 < n && awake[j + 1] && !motionAwake[j + 1] && smHR[j + 1] < ceiling { j += 1 }
            let run = j - i + 1
            // (d) longest consolidated asleep run anywhere strictly before this sub-run.
            var longestPrior = 0, prior = 0
            for k in 0 ..< i {
                if awake[k] { prior = 0 } else { prior += 1; longestPrior = max(longestPrior, prior) }
            }
            let hasSleepBehind = longestPrior >= tuning.minConsolidatedSleepEpochs   // (d)
            // (e) the ring was measuring sleep vitals across the sub-run (stillness + a clean optical read).
            let vitalsCount = (i ... j).filter { vitals[$0] }.count
            let vitalsFraction = Double(vitalsCount) / Double(run)
            if run >= tuning.minHRWakeRunEpochs,                                      // (c)
               hasSleepBehind,                                                        // (d)
               vitalsFraction >= tuning.hrWakeRescueVitalsFraction {                  // (e)
                for k in i ... j { awake[k] = false }
            }
            i = j + 1
        }
    }

    /// Indices spanning real sleep: from the start of the FIRST asleep run of length
    /// ≥ `sustain` to the end of the LAST such run. Short asleep flickers before the
    /// first / after the last sustained run are treated as pre-sleep / post-wake and fall
    /// outside the span. nil when no run is long enough (no real sleep block).
    private static func sleepSpan(_ awake: [Bool], sustain: Int) -> (Int, Int)? {
        let n = awake.count
        var first: Int?, last: Int?
        var i = 0
        while i < n {
            guard !awake[i] else { i += 1; continue }
            var j = i
            while j + 1 < n && !awake[j + 1] { j += 1 }
            if j - i + 1 >= sustain {
                if first == nil { first = i }
                last = j
            }
            i = j + 1
        }
        if let f = first, let l = last { return (f, l) }
        return nil
    }

    /// Mark the leading pre-sleep WIND-DOWN as awake: the stretch before HR first settles near the
    /// night's floor. Fills `awake[0..<onset] = true`, where `onset` is the start of the first
    /// sustained run of smoothed HR at/below a descent-relative band, sought only within the first
    /// `onsetSearchEpochs`. A no-op (leaves `awake` untouched) when there is no real evening→floor
    /// descent, or when HR never sustains below the band early — so it can only ever ADD leading
    /// awake on a genuine wind-down, never trim real sleep on a flat or restless night.
    private static func markDescentOnsetAwake(_ awake: inout [Bool], smHR: [Double],
                                              motionAwake: [Bool], floor: Double, tuning: Tuning) {
        let n = smHR.count
        guard tuning.onsetScanEpochs >= 1, n > tuning.onsetScanEpochs else { return }
        // Evening level = median of the first few in-bed epochs (robust to a single spike).
        let evening = percentile(Array(smHR[0 ..< tuning.onsetScanEpochs]).sorted(), 0.5)
        let descent = evening - floor
        guard descent >= tuning.onsetMinDescentBPM else { return }   // already calm → nothing to trim
        let band = floor + tuning.onsetSettleFraction * descent
        // First index BEGINNING a sustained (≥ onsetSustainEpochs) at/below-band run — i.e. the
        // settle into sleep. The run may extend past the search horizon; only its START must fall
        // within `onsetSearchEpochs`. Motion epochs break a settle run (a moving sleeper is awake).
        let limit = min(tuning.onsetSearchEpochs, n)
        var i = 0
        var onset: Int?
        while i < limit {
            guard smHR[i] <= band && !motionAwake[i] else { i += 1; continue }
            var j = i
            while j + 1 < n && smHR[j + 1] <= band && !motionAwake[j + 1] { j += 1 }
            if j - i + 1 >= tuning.onsetSustainEpochs { onset = i; break }
            i = j + 1
        }
        if let o = onset, o > 0 { for k in 0 ..< o { awake[k] = true } }
    }

    /// Push sleep ONSET past a clear pre-sleep wake episode. On a night spent lying still and AWAKE
    /// for hours — HR fluctuating, with a clearly-elevated block — the fixed/descent gates flag the
    /// obviously-awake epochs but leave the SHORT still dips between them reading as "asleep", so the
    /// onset anchors to the first dip, hours early. If a SUSTAINED awake run (≥ `onsetSustainEpochs`)
    /// still BEGINS within the onset search window, real sleep hasn't started: mark everything up to
    /// the END of the LAST such run as awake-in-bed. Operates ONLY on epochs already judged awake by
    /// the motion/HR gates (it never converts a quiet epoch to wake), and is GUARDED — it does nothing
    /// when a consolidated asleep run (≥ `minConsolidatedSleepEpochs`) preceded the block, so a normal
    /// night (asleep early, one brief stir) is untouched and only a genuine pre-sleep struggle is
    /// trimmed. Leading-edge + bounded by the search window, so it can never run away.
    private static func markLeadInWakeOnset(_ awake: inout [Bool], tuning: Tuning) {
        let n = awake.count
        let limit = min(tuning.onsetSearchEpochs, n)
        guard limit > 0 else { return }
        // Last sustained awake run that BEGINS within the search window (it may extend past it).
        var blockStart: Int?, blockEnd: Int?
        var i = 0
        while i < limit {
            guard awake[i] else { i += 1; continue }
            var j = i
            while j + 1 < n && awake[j + 1] { j += 1 }
            if j - i + 1 >= tuning.onsetSustainEpochs { blockStart = i; blockEnd = j }
            i = j + 1
        }
        guard let bs = blockStart, let be = blockEnd else { return }
        // Guard: if a real consolidated sleep run preceded the block, it's a mid-night awakening, not
        // a pre-sleep struggle — leave onset where it is.
        var longest = 0, run = 0
        for k in 0 ..< bs {
            if awake[k] { run = 0 } else { run += 1; longest = max(longest, run) }
        }
        guard longest < tuning.minConsolidatedSleepEpochs else { return }
        for k in 0 ... be { awake[k] = true }
    }

    /// The offset margin for a night, DERIVED from its own sleeping-HR spread rather than fixed in
    /// bpm — the same self-calibrating principle as `motionAboveLocalFloor` / `derivedActiveCut` /
    /// `sleepHRFloor`. `median − floor` is "how far a typical epoch sits above this night's sleeping
    /// floor"; a fraction of that scales with the person AND with how settled the night was. Floored
    /// at `offsetNoReturnMinMarginBPM` so a near-flat night can't derive a hair-trigger threshold.
    /// Returns 0 (disabled) when the fraction is 0 or the HR series is empty.
    /// Test seam for the percentile helper (which is `private`).
    static func percentileForTesting(_ xs: [Double], _ q: Double) -> Double { percentile(xs.sorted(), q) }

    /// Test seam for the consolidated-run helper (which is `private`), so a fixture can ASSERT it is
    /// exercising the survival guard rather than tripping an earlier one — the mutation that survived
    /// round 1's suite was exactly a survival guard whose test declined for a different reason.
    static func sleepSpanForTesting(_ awake: [Bool], sustain: Int) -> (Int, Int)? {
        sleepSpan(awake, sustain: sustain)
    }

    static func resolvedOffsetMargin(hr: [Double], floor: Double, tuning: Tuning) -> Double {
        guard tuning.offsetNoReturnSpreadFraction > 0, !hr.isEmpty else { return 0 }
        let spread = max(0, percentile(hr.sorted(), 0.50) - floor)
        return max(tuning.offsetNoReturnMinMarginBPM, tuning.offsetNoReturnSpreadFraction * spread)
    }

    /// Mark the trailing "HR rose and never settled again" run as awake — the OFFSET counterpart to
    /// the two onset passes above.
    ///
    /// Its opposite number in THIS function is the motion-awake VITALS SOFTENING (which removes
    /// trailing wake where the ring was still measuring sleep vitals); `sleepVitalsRescue` is a
    /// different stage entirely — it rewrites `[ActivityPeriod]` during BLOCK DETECTION, before
    /// staging runs, so it is not the counterpart it may look like. Both same-stage passes that add
    /// trailing SLEEP take precedence over this one via `notBefore`.
    ///
    /// WHY A SEPARATE TEST. The interior wake gate keys off `wakeHRMarginBPM`, which must sit ABOVE
    /// typical REM elevation or REM reads as wake. That ceiling is exactly what puts a quiet morning
    /// wake out of reach when the morning rise is smaller than the evening wind-down spread, and
    /// lowering the shared knob collapses the ONSET first (🟢 measured — see the knob's doc). The
    /// trailing edge does not need that ceiling: at TRUE final wake the smoothed HR rises and NEVER
    /// RETURNS to the sleeping floor, while a REM bump or a stir always settles back. Asking "does
    /// the whole REMAINING night stay up?" is a far stronger question than "is this epoch high?",
    /// so it can run at a much tighter margin without eating REM.
    ///
    /// SAFETY. This pass REMOVES sleep, so it is bounded in MAGNITUDE as well as shape. Five
    /// properties, all pinned by tests in `SleepStagingOffsetTests`:
    ///   1. SHAPE — the suffix-minimum scan is monotone from the END, so the marked region is always
    ///      a SUFFIX; it can never punch a hole in the interior.
    ///   2. HEAD — it refuses to start at or before the onset (`start > lo`), so it can never reach
    ///      the head or blank a night from the front.
    ///   3. PRECEDENCE — it refuses to start at or before `notBefore`: the last epoch reclaimed by
    ///      `rescueSecondBoutHRWake` or by the motion-awake vitals softening. A SECOND SLEEP BOUT
    ///      after a mid-night wake often sleeps at a HIGHER level than the night's floor, so it never
    ///      "returns to the floor" and this scan would read the whole bout as final wake. 🟢 MEASURED
    ///      without this guard: a 96-epoch second bout at 71 bpm over a 50 bpm floor was deleted
    ///      whole — 240 min of sleep, night total 485 → 245 at k=4.
    ///   4. MAGNITUDE — the cut point must lie within the last `onsetSearchEpochs` epochs, the same
    ///      bound the two ONSET passes use at the head. Without it the pass was positionally
    ///      unbounded: 🟢 MEASURED on a night containing NO WAKE AT ALL (HR drifting 52→57 across the
    ///      later half, which never dips back under the p12 floor because `smHR` is a rolling MEDIAN),
    ///      it destroyed 101.5 min at k=4 and 196.5 min at k=2. This models the MORNING RISE, so a
    ///      cut point hours from the end is by definition not what it is looking for.
    ///   5. SURVIVAL — it is REVERTED unless a CONSOLIDATED asleep run (`minConsolidatedSleepEpochs`,
    ///      not the much weaker `onsetSustainEpochs`) still survives, so it cannot reduce a night to
    ///      a token fragment.
    ///
    /// ⚠️ The premise — "at true final wake HR rises and never returns to the floor, while a REM bump
    /// or a stir always settles back" — is 🟡 PROBABLE, not established. It is measured on one night,
    /// and property 3 exists precisely because a real 3 a.m. arousal REFUTES the second half of it.
    /// `margin` is the RESOLVED bpm cut, derived by the caller from the night's own HR spread (see
    /// `resolvedOffsetMargin`); a non-positive margin disables the pass.
    ///
    /// `internal` rather than `private` (unlike every sibling pass) ON PURPOSE: its tests drive it
    /// directly, because a synthetic record fixture carries a CONSTANT motion byte that de-floors to
    /// "still" everywhere, so an "awake" fixture silently stages as sleep and the assertions go
    /// vacuous. Feeding the HR array in directly is the only way to test this honestly.
    static func markPointOfNoReturnOffset(_ awake: inout [Bool], smHR: [Double],
                                          floor: Double, margin: Double, vitals: [Bool] = [],
                                          notBefore: Int? = nil, tuning: Tuning) {
        guard margin > 0,
              !awake.isEmpty, smHR.count == awake.count,
              let (lo, _) = sleepSpan(awake, sustain: tuning.onsetSustainEpochs) else { return }
        // The scan may not begin at or before the onset, a rescued second bout, or a vitals-softened
        // morning; nor further back than the onset passes are allowed to reach from their own edge.
        let searchFloor = awake.count - min(tuning.onsetSearchEpochs, awake.count)
        let earliest = max(lo, notBefore ?? lo, searchFloor)
        let threshold = floor + margin
        // Earliest index whose ENTIRE suffix stays above the threshold. Walking backwards and
        // breaking on the first dip makes this a suffix by construction.
        var start: Int?
        var suffixMin = Double.infinity
        for i in stride(from: smHR.count - 1, through: 0, by: -1) {
            suffixMin = min(suffixMin, smHR[i])
            if suffixMin > threshold { start = i } else { break }
        }
        // `> earliest`, not `>=`: the onset epoch (and the last rescued epoch) must remain asleep.
        guard let s = start, s > earliest else { return }

        // TERMINAL-REM GUARD. HR alone cannot tell a final REM period from a quiet wake — both sit
        // elevated and neither returns to the floor — and REM periods LENGTHEN toward morning, so
        // this scan would systematically eat the last REM of every night. The ring settles it: during
        // REM it keeps emitting sleep-vitals (HRV-bearing) epochs at cadence, and at true wake that
        // stream thins. 🟢 MEASURED on the 2026-08-04 night: the sleep-vitals fraction holds
        // 0.42–0.50 from 23:26 through 07:26 and drops to 0.23 in the 08:26 hour. So require the
        // suffix to be materially thinner than the sleep behind it, reusing the same "at most this
        // share" bar `rescueSecondBoutHRWake` uses. No vitals coverage → this guard cannot judge and
        // stays out of the way (absence of data is not evidence of wake).
        // A night with NO sleep-vitals anywhere cannot be judged this way — and since this pass
        // REMOVES sleep, no evidence means no cut (the same "absence of data is not evidence"
        // stance the wear and HR gates take). Passing an empty `vitals` skips the guard entirely;
        // that is for the direct unit tests, not for production, which always threads it.
        if !vitals.isEmpty, vitals.count == awake.count {
            let suffix = vitals[s...]
            let body = vitals[lo..<s]
            let suffixShare = suffix.isEmpty ? 0
                : Double(suffix.filter { $0 }.count) / Double(suffix.count)
            let bodyShare = body.isEmpty ? 0
                : Double(body.filter { $0 }.count) / Double(body.count)
            guard bodyShare > 0 else { return }
            guard suffixShare <= bodyShare * tuning.hrWakeRescueVitalsFraction else { return }
        }
        var candidate = awake
        for i in s ..< candidate.count { candidate[i] = true }
        // Only commit if a CONSOLIDATED asleep run survives. `onsetSustainEpochs` (6 ≈ 15 min) is far
        // too weak a backstop for a pass that removes sleep — it would let an 8-hour night commit down
        // to a quarter of an hour. `minConsolidatedSleepEpochs` (16 ≈ 40 min) is the same bar
        // `markLeadInWakeOnset` uses to decide a real night happened.
        guard sleepSpan(candidate, sustain: tuning.minConsolidatedSleepEpochs) != nil else { return }
        awake = candidate
    }

    // MARK: - SpO2-cadence wake locator (#190)

    /// What one epoch-to-epoch step says about the ring's SpO2 duty cycle.
    ///
    /// While the ring runs its sleep-measurement program it reads SpO2 every 300 s, so consecutive
    /// 150-second epochs alternate `.sleepVitals` / `.activity` 1:1 (see `Tuning.cadenceWakeQuietEpochs`
    /// for the evidence). `.violation` is the ring emitting the SAME template twice in a row — the duty
    /// cycle broke. `.unknown` is a step that carries NO cadence information and must never be read as
    /// either.
    enum CadenceStep: Equatable {
        /// The template flipped exactly as the duty cycle demands (allowing for one bridged hole).
        case alternating
        /// Two same-template epochs in a row: the duty cycle broke here.
        case violation
        /// No cadence information: an unworn/idle epoch on either side, or a hole of more than one
        /// missing epoch. **Absence of evidence, never evidence of a wake.**
        case unknown
    }

    /// Classify every epoch-to-epoch step of the row series against the ring's SpO2 duty cycle.
    ///
    /// ⚠️ GAP- AND JITTER-AWARENESS IS LOAD-BEARING, not politeness. The naive test
    /// `dt == epochSeconds && layout[i] == layout[i-1]` fails in BOTH directions, and they are
    /// complementary, so neither can be traded for the other:
    ///   • DROPPING one interior epoch makes its neighbours same-template in 90.5 % of positions BY
    ///     CONSTRUCTION. A gap-blind rule reads that as a violation storm and severs the night; a
    ///     blind-bridging rule was measured joining 70 missing epochs into a 25-epoch phantom
    ///     *daytime* run. So exactly ONE missing epoch is bridged — its template is inferred from
    ///     PARITY (after an even number of steps the template returns to itself) — and anything
    ///     longer becomes `.unknown`.
    ///   • JITTER: 91 of 3432 steps on the primary ring are not exactly 150 s (151–221 s) with no
    ///     record missing at all. An exact-equality test silently suppresses 57 genuine violations,
    ///     so the step count is `round(dt / 150)`, not `dt == 150`.
    /// 🟢 Monte-Carlo dropout on 08-09 measured the two definitions failing in opposite directions: a
    /// page lost at 08:36 makes the gap-aware rule cut 29.6 min EARLY, one lost at 09:06 makes the
    /// gap-blind rule cut 17.9 min LATE.
    ///
    /// `index 0` is always `.unknown` — there is no step INTO the first row.
    static func cadenceSteps(times: [Date], layouts: [BulkRecord.Layout]) -> [CadenceStep] {
        guard times.count == layouts.count, !times.isEmpty else { return [] }
        var out = [CadenceStep](repeating: .unknown, count: times.count)
        for i in 1 ..< times.count {
            let previous = layouts[i - 1], current = layouts[i]
            // An unworn epoch is outside the measurement program altogether; it is not a violation.
            guard previous != .idle, current != .idle else { continue }
            let dt = times[i].timeIntervalSince(times[i - 1])
            let steps = max(1, Int((dt / Double(BulkRecord.epochSeconds)).rounded()))
            guard steps <= 2 else { continue }   // more than one epoch missing → no information
            // One flip per epoch step, so after an EVEN number of steps the template returns to itself.
            let expectedSame = steps.isMultiple(of: 2)
            out[i] = ((previous == current) == expectedSame) ? .alternating : .violation
        }
        return out
    }

    /// Mark final wake at the point the ring LEFT its sleep-measurement program (#190).
    ///
    /// The wake candidate is the epoch right after the END of the LAST unbroken alternating run of at
    /// least `tuning.cadenceWakeQuietEpochs` epochs. Every other pass in this file infers wake from the
    /// SLEEPER; when the primary motion channel is a flat placeholder and the morning HR rise is small,
    /// all of them miss and the night silently runs to the last record — so the reported wake becomes
    /// `lastRecord + 120 s`, a function of when the user synced rather than of when they woke.
    ///
    /// It is deliberately the LAST qualifying run, not the LONGEST. 🟢 MEASURED: "end of the longest
    /// violation-free run" is catastrophic — 06-29 → 04:38 (−4 h 28 m), 08-04 → 07:25 (−1 h 29 m) — and
    /// "last" is also what protects a ring left in continuous SpO2 mode, whose final long run always
    /// reaches the data edge and is therefore declined.
    ///
    /// GUARDS, in order. Each one is a decline, never a weaker cut:
    ///  1. `cadenceWakeQuietEpochs == 0` — the pass is off; byte-identical to pre-cadence staging.
    ///  2. No run of at least K anywhere after onset — the cadence never held for a plausible night.
    ///  3. The run ends at the DATA EDGE — the ring was still in the program when the capture stopped,
    ///     so no wake has been observed. This is the guard that keeps the pass from re-manufacturing
    ///     the very "wake == last record" artefact it exists to remove.
    ///  4. The run ends at a `.unknown` step (a hole) rather than a `.violation` — absence of evidence.
    ///  5. The run is longer than `cadenceWakeMaxQuietEpochs` — not a night, a ring in continuous SpO2.
    ///  6. `s > earliest` — suffix-only by construction, never reaching onset, a rescued second bout
    ///     (`notBefore`), or further back from the tail than `onsetSearchEpochs` (48 ≈ 2 h), which is
    ///     what bounds the total damage this pass can do.
    ///  7. The HR NO-RETURN confirmation: smoothed HR must stay above `floor + margin` for the WHOLE
    ///     remainder of the night. 🟢 This is the guard doing the real adjudicating work — it is what
    ///     declines the cadence cut on 06-29 (which would otherwise remove 75 minutes from an
    ///     UNLABELLED night) and on 08-07.
    ///  8. A consolidated asleep run must still survive, the same bar `markPointOfNoReturnOffset` uses.
    ///
    /// ⚠️ It does NOT carry `markPointOfNoReturnOffset`'s terminal-REM VITALS guard, and that omission
    /// is deliberate and measured. That guard's premise — "the sleep-vitals stream thins at true wake" —
    /// is 🔴 REFUTED on this hardware: measured FROM the user-reported wake, the suffix/body vitals
    /// ratio is 1.00 on 08-09 and 0.53 on 08-05 against a 0.50 bar, so it declines a perfectly placed
    /// cut on both labelled nights, and no setting of `hrWakeRescueVitalsFraction` can rescue it
    /// (08-09 needs 0.481 ≤ 0.476). The guard was a PROXY for "is the ring still measuring sleep here";
    /// the cadence is that question asked directly, which is exactly why this pass can afford to drop it.
    ///
    /// ⚠️ WHY NOT THE FULL `notBefore`. `markPointOfNoReturnOffset` is held back by BOTH the second-bout
    /// rescue and the motion-awake VITALS SOFTENING (`motionAwakeStrict[i] && !motionAwake[i]`). This
    /// pass is held back only by the FORMER, and that is a measured decision, not an oversight. The
    /// softening's last index is UNSTABLE UNDER SYNC TIME — it is derived from `tailStart`, from a
    /// night-wide HR floor, and from a rolling median whose window is truncated at the data edge — so on
    /// 2026-08-05 it flickered nil → 241 → 245 → nil → 245 → nil across consecutive 5-minute truncation
    /// cuts. Gating on it reintroduced exactly the defect this pass exists to remove: 🟢 MEASURED
    /// end-to-end, the reported night went 478 · 473 · 473 · 497 · 502 · 507 · 512 · 517 · 485 — three
    /// sign changes and a 47-minute swing produced by nothing but when the user synced. With the
    /// softening out of the gate the located wake is IDENTICAL (08:10:14) on every one of those cuts.
    /// The two mechanisms also answer the SAME question at different fidelity — the softening infers
    /// "the ring was still measuring sleep" from HRV epochs within ±3 epochs, the cadence reads the
    /// ring's duty cycle directly — so deferring the direct witness to the proxy is backwards. What
    /// still protects the moving-but-asleep restless morning the softening was written for is guard 7:
    /// a sleeper whose HR is still near the floor fails the HR no-return confirmation and is not cut.
    ///
    /// `internal` rather than `private`, for the same reason as `markPointOfNoReturnOffset`: a synthetic
    /// record fixture carries a constant motion byte that de-floors to "still" everywhere, so an "awake"
    /// fixture stages as sleep and the assertions go vacuous. Its tests drive it directly.
    static func markCadenceWakeOffset(_ awake: inout [Bool], cadence: [CadenceStep], smHR: [Double],
                                      floor: Double, margin: Double, notBefore: Int? = nil,
                                      tuning: Tuning) {
        guard tuning.cadenceWakeQuietEpochs > 0, margin > 0,
              !awake.isEmpty, cadence.count == awake.count, smHR.count == awake.count,
              let (lo, _) = sleepSpan(awake, sustain: tuning.onsetSustainEpochs) else { return }
        let n = awake.count
        guard lo + 1 <= n else { return }
        // The scan may not begin at or before onset or a rescued second bout (`notBefore`), nor
        // further back than the onset passes are allowed to reach from their own edge. It is NOT held
        // back by the motion-awake vitals softening — see "WHY NOT THE FULL `notBefore`" above.
        let searchFloor = n - min(tuning.onsetSearchEpochs, n)
        let earliest = max(lo, notBefore ?? lo, searchFloor)

        // The LAST maximal alternating run of >= K epochs, and WHY it ended. `i == n` is the virtual
        // step past the end of the data — the "regime never exited" terminator.
        var trusted: (end: Int, length: Int, terminator: CadenceStep?)?
        var start = lo
        for i in (lo + 1) ... n {
            let terminator: CadenceStep? = i < n ? cadence[i] : nil
            guard terminator != .alternating else { continue }
            let end = i - 1
            if end - start + 1 >= tuning.cadenceWakeQuietEpochs {
                trusted = (end, end - start + 1, terminator)
            }
            start = i
        }
        guard let run = trusted else { return }              // the cadence never held for a night
        guard run.terminator == .violation else { return }   // data edge or hole: no wake observed
        guard run.length <= tuning.cadenceWakeMaxQuietEpochs else { return }   // not a night

        let s = run.end + 1
        // `> earliest`, not `>=`: the onset epoch (and the last rescued epoch) must remain asleep.
        guard s < n, s > earliest else { return }
        // HR NO-RETURN CONFIRMATION — the same test `markPointOfNoReturnOffset` scans for, used here
        // as a second, INDEPENDENT witness on a cut the cadence has already located. The cadence says
        // where the ring stopped measuring sleep; this says the body never settled back afterwards.
        guard let suffixMin = smHR[s...].min(), suffixMin > floor + margin else { return }

        var candidate = awake
        for i in s ..< n { candidate[i] = true }
        // Only commit if a CONSOLIDATED asleep run survives — a pass that REMOVES sleep must not be
        // able to commit a night down to a token fragment.
        guard sleepSpan(candidate, sustain: tuning.minConsolidatedSleepEpochs) != nil else { return }
        awake = candidate
    }

    /// Centered rolling standard deviation over a ±`half`-epoch window.
    private static func rollingSD(_ xs: [Double], half: Int) -> [Double] {
        let n = xs.count
        guard n > 0 else { return [] }
        var out = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            let s = max(0, i - half), e = min(n - 1, i + half)
            let w = xs[s ... e]
            let mean = w.reduce(0, +) / Double(w.count)
            let varr = w.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(w.count)
            out[i] = varr.squareRoot()
        }
        return out
    }

    /// Forward-then-backward fill of nil gaps, so a sparse channel (HRV, RR) has no
    /// artificial jumps where readings drop out.
    private static func filledForward<T>(_ xs: [T?]) -> [T?] {
        var out = xs
        var last: T?
        for i in out.indices { if let v = out[i] { last = v } else { out[i] = last } }
        var next: T?
        for i in stride(from: out.count - 1, through: 0, by: -1) {
            if let v = out[i] { next = v } else { out[i] = next }
        }
        return out
    }

    /// Value at quantile `q` (0…1) of a pre-sorted array (nearest-rank). 0 if empty.
    private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((q * Double(sorted.count - 1)).rounded())
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }
}
