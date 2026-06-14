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
- [ ] Xcode project under `ios/`; CoreBluetooth scan/connect to the ring.
- [ ] Port the validated codec (framing + per-metric parsers) to Swift.
- [ ] Local store (SwiftData) + per-metric sync cursor; background BLE sync.
**Exit:** iOS app pulls the same data the desktop client does.

## Phase 4 — HealthKit write
- [ ] Map each metric per `HEALTHKIT_MAPPING.md`; request authorizations.
- [ ] Write live + historical samples with device timestamps; dedup on re-sync.
- [ ] Backfill on first run, incremental thereafter.
**Exit:** ring metrics appear in Apple Health, no cloud involved.

## Phase 5 — Analytics (port from openwhoop)
- [ ] Port sleep detection, HRV analysis, strain/stress scoring to Swift.
- [ ] Write derived metrics to HealthKit / app UI.

## Known risks
- **Encryption / auth.** If the BLE link or app layer is encrypted with a
  cloud-issued key, offline decoding may be blocked at Phase 1 — this is the make-or-break unknown.
- **Non-standard GATT.** May require handle-based access and quirks per platform.
- **HealthKit constraints.** No RMSSD type (only SDNN); sleep is segment-based;
  iOS-only — none of this is reachable from desktop.
- **Firmware updates** can change the protocol; pin observations to a FW version.
