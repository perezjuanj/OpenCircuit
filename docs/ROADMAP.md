# Roadmap

Goal: replicate openwhoop's local-first health extraction for the **RingConn Gen 2**,
writing all metrics to **Apple Health**.

## Phase 1 — Decode the protocol  ◀ current
The gating work. Produce a written spec; almost nothing is public.
- [ ] Enumerate full GATT tree (`scan`) → fill `PROTOCOL.md` §1.
- [ ] Capture a fresh app launch; determine if/how it authenticates (§2).
- [ ] Determine whether the BLE link is encrypted (sniffer / pairing check).
- [ ] Decode framing: header, length, sequence, checksum (§3).
- [ ] Decode live heart rate end to end (confirm the `0x0804` 7-bit field).
**Exit:** `listen` shows decoded live HR from real captures.

## Phase 2 — Desktop proof-of-client
Validate the spec cheaply before committing to Swift.
- [ ] Implement each sync command (battery, SpO2, sleep, HRV, steps, temp).
- [ ] Page through history; reassemble multi-packet records.
- [ ] Dump everything to SQLite + CSV; sanity-check against the official app.
**Exit:** one full day of the ring's data pulled offline, matching the app.

## Phase 3 — iOS app skeleton
- [x] Port the validated **framing codec** to Swift — `ios/OpenRingKit` SwiftPM
      package (`Frame`, `Opcode`, `LiveHR`), tested against real FR02.018 capture
      frames. Builds/tests without Xcode via `swift run RingKitVerify`.
- [ ] Port **per-metric parsers** (blocked: needs decoded metric formats — sleep/
      SpO2/HRV/steps/temp captures are 🔴 in PROTOCOL.md §5).
- [x] **Xcode app target** — `ios/project.yml` (XcodeGen) generates `OpenRingConn`
      (bundle `com.openringconn.app`, iOS 17, embeds OpenRingKit, HealthKit + BLE
      Info.plist keys + `bluetooth-central` background mode). **Compiles** for the
      iOS simulator (`xcodebuild … CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED).
- [x] **CoreBluetooth glue** — `BLE/RingScanner.swift` (scan by confirmed name
      prefix, connect) + `RingSession.swift` (discover notify/write chars by UUID,
      enable notify, poll live HR via OpenRingKit.Frame, decode 0x15 frames).
- [x] **HealthKitWriter** — auth + per-type write/units per HEALTHKIT_MAPPING.md.
- [x] **Metric models + SyncCursor** — `Metrics.swift` + `SyncCursor.swift`, tested.
- [x] **LocalStore (SwiftData)** — StoredSample/StoredCursor wrapping SyncCursor.
- [x] **XCTest suite** runs under Xcode: 23 tests, 0 failures.
- [ ] Port **per-metric parsers** (blocked: metric formats 🔴 in PROTOCOL.md §5).
- [ ] Run on a real device + ring (BLE needs hardware; simulator can't connect).
**Exit:** iOS app pulls the same data the desktop client does.

> **Blocked on hardware/decisions (hard stops):** (a) notify/write **characteristic
> UUIDs are still 🟡** — `openringconn scan` must bind them to the confirmed handles
> 0x0804/0x0802 before the app can connect; (b) **history/metric record formats are
> 🔴** (PROTOCOL.md §5) — sync beyond live HR needs captures; (c) running on device
> needs **code-signing** (Apple Developer account). Compilation verified; functional
> sync is not.

## Phase 4 — HealthKit write
- [ ] Map each metric per `HEALTHKIT_MAPPING.md`; request authorizations.
- [ ] Write live + historical samples with device timestamps; dedup on re-sync.
- [ ] Backfill on first run, incremental thereafter.
**Exit:** ring metrics appear in Apple Health, no cloud involved.

## Phase 5 — Analytics (port from openwhoop)
- [x] Port **HRV (RMSSD)**, **stress (Baevsky index)**, **strain (Edwards TRIMP)**,
      and **sleep score** to Swift in `OpenRingKit/Analytics/`, with tests mirroring
      openwhoop's own Rust vectors (exact calibration anchors match: strain 21.0 at
      24h@maxHR, stress 10.0 at constant RR).
- [ ] Port **sleep-cycle detection** (activity.rs ActivityPeriod + sleep staging) —
      device-agnostic algorithm; defer until we confirm the ring's HR/RR/IMU stream.
- [ ] Wire analytics to real decoded metrics (blocked: RR-interval availability &
      sample cadence are 🔴 in PROTOCOL.md §5 — needs a capture).
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
