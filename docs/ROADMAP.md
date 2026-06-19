# Roadmap

Goal: replicate openwhoop's local-first health extraction for the **RingConn Gen 2**,
writing all metrics to **Apple Health**.

## Phase 1 — Decode the protocol  ✅ COMPLETE
The gating work. Produce a written spec; almost nothing is public.
- [x] Enumerate full GATT tree (`scan`) → `PROTOCOL.md` §1 (🟢 service 8327ad99,
      notify/write chars bound to handles 0x0804/0x0802).
- [x] Auth/handshake: none observed — data flows after CCCD enable (§2).
- [x] Encryption: BLE app layer is plaintext (§0, 🟢).
- [x] Framing: `[cmd][len][payload][xor]`, resp = cmd XOR 0x80 (§3, 🟢).
- [x] Confirm live HR end to end — 🟢 byte[2] of `0x15` frames = HR in bpm,
      confirmed by a targeted HR-only capture settling to 61 bpm resting.
**Exit:** ✅ **MET** — decoded live HR from a real capture (`decode-log` +
`framing.decode_live_hr`). Phase 1 complete.

## Phase 2 — Desktop proof-of-client
Validate the spec cheaply before committing to Swift.
- [ ] Implement each sync command (battery, SpO2, sleep, HRV, steps, temp).
- [ ] Page through history; reassemble multi-packet records.
- [ ] Dump everything to SQLite + CSV; sanity-check against the official app.
**Exit:** one full day of the ring's data pulled offline, matching the app.

## Phase 3 — iOS app skeleton
- [x] Port the validated **framing codec** to Swift — `ios/OpenCircuitKit` SwiftPM
      package (`Frame`, `Opcode`, `LiveHR`), tested against real FR02.018 capture
      frames. Builds/tests without Xcode via `swift run RingKitVerify`.
- [x] Port **sleep-vitals parser** — `OpenCircuitKit/BulkSleep.swift` decodes `0x4c`
      history pages → HR/HRV/SpO2 per-epoch `QuantitySample`s (PROTOCOL.md §5.3 🟢,
      app-confirmed). Tested against real 2026-06-13 sync frames. Steps/temp/RR parsers
      still pending their formats (🟡/🔴).
- [x] **Xcode app target** — `ios/project.yml` (XcodeGen) generates `OpenCircuit`
      (bundle `com.opencircuit.app`, iOS 17, embeds OpenCircuitKit, HealthKit + BLE
      Info.plist keys + `bluetooth-central` background mode). **Compiles** for the
      iOS simulator (`xcodebuild … CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED).
- [x] **CoreBluetooth glue** — `BLE/RingScanner.swift` (scan by confirmed name
      prefix, connect) + `RingSession.swift` (discover notify/write chars by UUID,
      enable notify, poll live HR via OpenCircuitKit.Frame, decode 0x15 frames).
      `syncHistory()` drains `0x4c` pages → `BulkSleep` → HR/HRV/SpO2 samples,
      finalized on `0x50` end-of-history; ContentView writes them to HealthKit.
- [x] **HealthKitWriter** — auth + per-type write/units per HEALTHKIT_MAPPING.md.
- [x] **Metric models + SyncCursor** — `Metrics.swift` + `SyncCursor.swift`, tested.
- [x] **LocalStore (SwiftData)** — StoredSample/StoredCursor wrapping SyncCursor.
- [x] **XCTest suite** runs under Xcode: 23 tests, 0 failures.
- [ ] Port **per-metric parsers** (blocked: metric formats 🔴 in PROTOCOL.md §5).
- [x] Run on a real device + ring — **the app pulls live data from the ring** (live HR
      decoded 68 bpm; history sync runs) once the iPhone is **bonded** to the ring (pair
      via the official app once; BLE bonds are shared across apps — PROTOCOL.md §0).
**Exit:** ✅ **MET** — iOS app pulls the same live HR / history the desktop decodes.
Remaining for end-to-end into Apple Health: the paid-account HealthKit entitlement (Phase 4).

> **Blocked on hardware/decisions (hard stops):** (a) notify/write **characteristic
> UUIDs are still 🟡** — `opencircuit scan` must bind them to the confirmed handles
> 0x0804/0x0802 before the app can connect; (b) **history/metric record formats are
> 🔴** (PROTOCOL.md §5) — sync beyond live HR needs captures; (c) running on device
> needs **code-signing** (Apple Developer account). Compilation verified; functional
> sync is not.

## Phase 4 — HealthKit write
- [x] Map each metric per `HEALTHKIT_MAPPING.md`; request authorizations
      (`HealthKitWriter` per-type units + auth; sleep as `sleepAnalysis` category).
- [x] Write historical samples with device timestamps; **dedup on re-sync** —
      sync → `LocalStore.ingest` (cursor-based `selectNew`) + `ingestSleep` (gated on
      the `.sleep` cursor) → only NEW samples/segments reach HealthKit (ContentView).
- [x] Backfill on first run, incremental thereafter — the per-metric cursor makes the
      first sync write everything and later syncs write only newer records.
> Dedup *logic* is unit-tested via `SyncCursor`; the `LocalStore` SwiftData wrapper is
> build-verified only (no app-target test target yet). Live-HR samples aren't persisted
> (only history sync routes through the store). Functional run needs device + ring.
> **The only blocker to actually writing Health is the HealthKit entitlement, which needs
> a paid Apple Developer account.** On a paid team, uncomment the `entitlements:` block in
> `ios/project.yml`, `xcodegen generate`, and pick your team (see HANDOFF). Do NOT set the
> entitlement on a free team — it breaks device launch (pre-main libxpc crash).
**Exit:** ring metrics appear in Apple Health, no cloud involved.

## Phase 5 — Analytics (port from openwhoop)
- [x] Port **HRV (RMSSD)**, **stress (Baevsky index)**, **strain (Edwards TRIMP)**,
      and **sleep score** to Swift in `OpenCircuitKit/Analytics/`, with tests mirroring
      openwhoop's own Rust vectors (exact calibration anchors match: strain 21.0 at
      24h@maxHR, stress 10.0 at constant RR).
- [x] Port **sleep-cycle detection** (activity.rs: stillness → Sleep/Active periods,
      `findSleep`) to `Analytics/SleepDetection.swift`, with tests mirroring openwhoop's.
- [x] **Wire sleep detection to real data** — `detectFromMotion` feeds the decoded
      `0x4c [10:15]` motion channel (no gravity vector needed) into the same core;
      `BulkSleep.sleepSegments` → `inBed`/`asleepCore`/`awake` for HealthKit, surfaced in
      RingSession + ContentView. Validated on the 2026-06-13 night: detects in-bed
      00:33→09:34 vs the app's ~00:32→09:30.
- [~] **Experimental Deep/REM staging** — `BulkSleep.stagedSegments` (HR-percentile
      heuristic: Awake=motion, Deep=HR≤p20, REM=HR≥p70, else Light, ≥5-min runs).
      Matches the night's stage TOTALS to ~13% (Deep 100 vs 90, REM 142 vs 115, Light
      222 vs 242, Awake 8 vs 13 min) but **NOT the architecture** (put Deep late / REM
      early — HR alone can't place cycles, and the deepest HR fell before sleep-onset).
      Shown in-app as "experimental"; **only the coarse segments are written to
      HealthKit**. A faithful hypnogram needs richer signal / per-epoch ground truth.
- [ ] Wire **HRV/stress/strain** to real metrics (still gated: those assume per-beat
      RR intervals; the ring sends per-epoch HRV(ms)/HR, not RR — see note below).
- [ ] Write derived metrics to HealthKit / app UI (Phase 4 dependency).

> ⚠️ The ported analytics assume per-beat **RR intervals** and ~1 Hz HR (Whoop's
> stream shape). Whether RingConn exposes RR at all is unconfirmed — the math is
> ready, but its inputs must be validated against a real capture before trusting
> derived HRV/stress/strain numbers.

## Known risks
- **Encryption / auth.** If the BLE link or app layer is encrypted with a
  cloud-issued key, offline decoding may be blocked at Phase 1 — this is the make-or-break unknown.
- **Non-standard GATT.** May require handle-based access and quirks per platform.
- **HealthKit constraints.** No RMSSD type (only SDNN); sleep is segment-based;
  iOS-only — none of this is reachable from desktop.
- **Firmware updates** can change the protocol; pin observations to a FW version.
