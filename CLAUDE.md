# CLAUDE.md — OpenCircuit

Project context for Claude Code. Read this and `docs/ROADMAP.md` first.

## Goal
Replicate [openwhoop](https://github.com/bWanShiTong/openwhoop)'s local-first health
extraction for the **RingConn Gen 2** smart ring and write all metrics to **Apple
Health** — no cloud, no subscription.

## Where we are
- **Phase 1 (protocol RE) is the gating work.** The RingConn Gen 2 BLE protocol is
  almost entirely undocumented and reportedly not fully GATT-compatible.
- `desktop/` holds a working Python + `bleak` workbench to decode it. The living
  spec it feeds is `docs/PROTOCOL.md`.
- The **make-or-break unknown**: is the BLE link encrypted with a cloud-issued key?
  If so, offline decoding stalls. Answer this before deep work.

## Hard constraints (don't relitigate)
- HealthKit is **iOS-only**; iOS BLE must use **CoreBluetooth** → the data-writing
  app must be **native Swift**. openwhoop's Rust/btleplug stack cannot be reused on
  iOS. The desktop workbench is throwaway tooling for decoding only.
- Only openwhoop's **analytics** (sleep/HRV/strain) port across devices; its
  transport + parser are Whoop-specific and rewritten here.

## Decisions already made
- Desktop RE client first (Python + bleak), iOS app after the protocol is proven.
- Analytics ported **natively to Swift** (no Rust/UniFFI).
- User has the ring and can capture Android HCI snoop logs.

## Map
| Path | What |
|---|---|
| `desktop/opencircuit/` | RE workbench: scan/enumerate/listen/replay/decode-log/guess-checksum |
| `docs/PROTOCOL.md` | Living protocol spec (the Phase 1 deliverable) |
| `docs/REVERSE_ENGINEERING.md` | Capture + decode workflow |
| `docs/RUNBOOK_OVERNIGHT_TEMP.md` | **Overnight capture for skin temp / sleep stages / HRV (#7,#9,#12)** |
| `docs/RUNBOOK_AIR_SLEEP_LABELS.md` | **Get self-reported bed/wake labels from the two Gen 2 Air testers.** Every Air capture we hold is UNLABELLED, so no Air staging change can be adjudicated — only shown to have moved. The load-bearing instruction is "write it down BEFORE opening the app" (otherwise it is another echo label) |
| `docs/RUNBOOK_SLEEP_GROUNDTRUTH.md` | **Capture RingConn's computed hypnogram (`sleepPhases`) via mitmproxy → fit our staging to it** |
| `docs/RUNBOOK_OSA_APNEA.md` | **OSA sleep-apnea (#91) — capture cracked (start `05 22 01`, dense PPG `0x48`), decode→AHI parked; forward plan** |
| `desktop/bp_collect.py` | **Drives `06 05 00` mode 5 and records the 100 Hz 4-ch raw PPG (`0x12`) + a paired cuff reading.** stdlib+bleak only (no numpy). ⚠️ `06 00 00` is sent from a `finally` on EVERY exit — mode 5 is INVISIBLE in the descriptor state byte (stays idle `0x02`/`0x03`, unlike sport mode's `0x06`), so a stranded stream can't be detected from telemetry. Does NOT open a sync session, to avoid draining the user's history. `--replay <btsnoop>` decodes offline |
| `docs/RUNBOOK_GEN3_VIBRATE_CONFIRM.md` | **Follow-up for the Gen 3 tester: confirm the decoded vibrate frame `0b 03 01 64 00` by feel (`verify_vibrate.py`) + 3 no-equipment questions.** Sent after the FR05.011 capture cracked the motor opcode (PROTOCOL.md §5.9); this run is the 🟡→🟢 gate |
| `docs/RUNBOOK_GEN3_BP_HAPTIC.md` | **Gen 3 vibrate motor + BP-calibration collection, written for a NON-DEV helper (iPhone→Mac capture). Landmines in "Notes for us": the vibrate opcode is NOT in the APK (capture only, don't re-mine), `BleSub*` means sub-DEVICE not sub-command, and RingConn's BP is cloud-computed — the raw PPG is on the wire, their number isn't** |
| `desktop/ringconn_sleep_fit.py` | Supervised-fit harness: align our epochs to RingConn `sleepPhases`, fit `SleepStaging.Tuning` (`--synthetic` to demo) |
| `docs/SLEEP_REPLAY_HARNESS.md` | **Swift replay harness — stage any night from raw bytes via `swift test`.** Measure a staging change instead of arguing about it; read §2 (production parity) and §4 (the edit trap) before quoting any number |
| `docs/HEADACHE_SIGNALS.md` | **Headache signals (#183) — plan of record. Read §1 first: the honest accuracy arithmetic is why the alert must EARN its way on per-user** |
| `docs/RUNBOOK_HEADACHE_VALIDATION.md` | **On-device validation for #183 (freeze / migration / HealthKit) + the tester-facing "What to Test"** |
| `docs/RUNBOOK_SCHEMA_MIGRATION_REHEARSAL.md` | **MANDATORY before shipping any SwiftData schema change. Two gates: "Gate A" is the named suite invocation `-only-testing:OpenCircuitTests/ShippedStoreMigrationTests` — run it on its own and check the executed-test COUNT, because a full-target run has already skipped the whole suite silently; then rehearse the upgrade on a real phone from a PRE-45 build. Build 44 deleted every raw history row on upgrade; a simulator pass and a current-build store both skip the defect** |
| `docs/HEALTHKIT_MAPPING.md` | Each metric → HealthKit type |
| `docs/TRAINING_METRICS.md` | **Training load (Edwards TRIMP) + VO₂ max estimate (ACSM + Swain) from recorded workouts (#232): citations, inputs, skip rules, why recovery time / training effect are NOT shipped, and the Zepp two-week tolerance fixed before shipping. `vo2Max` is asked lazily through its own one-type request — never add it to `HealthKitWriter.allTypes`** |
| `docs/ZEPP_PROTOCOL.md` | **Amazfit Helio Strap (Zepp OS) clean-room protocol spec (#215).** The Swift implementation must be built from this file ALONE: never open Gadgetbridge (AGPL) or HelioCore (unlicensed). Its worked examples (§3.6, §3.7, §4.6, §6.2 example D, and E–H in §11–§13) are our own vectors and can be used as test fixtures; §6.2's trace T1 is from hardware (control bytes only), not a fixture. §10 is the capture checklist that promotes claims to 🟢, and §10.1 holds the first real-strap results (2026-09-30). Landmine: the start reply's length unit is per type, and activity counts 8-byte RECORDS, not bytes |
| `docs/HELIO_KEY_EXTRACTION.md` | User guide: getting the Helio Strap's 16-byte auth key (one-time Zepp pairing; needs a computer). Unpairing in Zepp invalidates the key, so users should delete the app instead |
| `ios/OpenCircuitKit/Sources/ZeppKit/`, `Sources/HelioVerify/` | **Zepp OS protocol core for the Helio Strap (#215 phase 1), built from `docs/ZEPP_PROTOCOL.md` ONLY** (same clean-room rule: never open Gadgetbridge, HelioCore or NOOP to change it). B-163 ECDH ported from public-domain tiny-ECDH-c and tested against OpenSSL (`Tests/ZeppKitTests/make_b163_vectors.sh`); framing, auth and history fetch are pure state machines. The fetch acks `03 09` (keep on strap) on every path except `.deleteAfterDurableCommit` plus a caller-confirmed durable commit of a CRC-verified round. Every conservative reading of the spec is marked `// SPEC-GAP:`. `swift run HelioVerify --help` is the macOS check against a real strap. Device controls (§11–§15: find device, buzz, alarms, haptic alerts) are pure machines gated per connection by `ZeppControlCapabilities` (unknown = unsupported = nothing sent); alarm writes go only through `ZeppAlarmEditor` (read first, one slot, re-read), and vibration patterns are deliberately unsendable in v1. Strap settings (HEALTH and WORKOUT config, §17/§19) are written only through `ZeppSettingsEditor` (read the arg and its parent, one entry echoing the version read, wait for `06`, re-read; WORKOUT `40` and HEALTH `05` are never written); `HelioVerify --settings`, `--set-config` and `--config-probe` (the §10 item 25 rejection probes) drive it on hardware. The app's pure Helio rules (key text, fetch plan, skin-temperature gate, sleep selection, HRV policy) are `ZeppKit/HelioSyncPolicy.swift`; the simulated strap for tests is `Sources/ZeppKitTesting/` |
| `ios/OpenCircuit/Helio/` | **The Helio Strap in the app (#215 phase 3).** `HelioSession` (a `WearableSession`, no CoreBluetooth, tested against `FakeZeppDevice`) drives auth → clock → fetch → controls; `HelioConnection` is its own central (restore id `…opencircuit.helio`); the key lives in the Keychain (`HelioKeyStore`). One device at a time (`Wearable/ActiveDeviceChoice.swift`): with the strap chosen the ring's scanner is never constructed, and every fetch round is acked `03 09` (no delete path). Decisions of record: `briefs/helio-decisions.md` (orchestrator) |
| `docs/BACKGROUND_SYNC.md` | **How the official RingConn app syncs to Apple Health without being opened (RE'd blueprint) → mapped to our BGTask + CoreBluetooth-restoration implementation (#119); deliberate divergences + validation runbook.** B.5 is the Helio Strap on the same wakes (`Background/HelioBackgroundSyncService.swift`, #215 phase 4): no new modes or task ids, `BackgroundDrain` runs only the chosen device's drain. #233 (decisions 33, 35): the strap wakes the app (reconnect/restoration, idle-link traffic, the woke-up hint, HealthKit step delivery; `Background/HelioWakeSync.swift`), simultaneous grants coalesce, and the `helio-link` breadcrumbs (Diagnostics ▸ "Strap link and wakes") say what happened overnight |
| `docs/SHORTCUTS.md` | **Shortcuts actions (#260, decision 52): Vibrate Wearable, Set / Clear Wake Alarm on Wearable.** `Wearable/WearableShortcuts.swift` reaches the strap (chosen AND saved, else nothing is created; a ready session as it is, else the standing connect for ≤ 15 s; never disconnects); the buzz returns only after its `06` went out. The wake alarm is ONE managed slot planned by the pure `StrapWakeAlarmPlanner` (`Helio/StrapWakeAlarm.swift`), persisted first and applied right after the next connection's setup alarm read; the record changes only on a confirming re-read. Never touches another slot. **RingConn Gen 3 (52g, untested on hardware)**: Vibrate via the saved ring's standing connect + the same 15 s wait for a ready, idle session (`Wearable/RingShortcutSupport.swift`); Set/Clear drive the app's own ring alarm (`RingAlarmController`, nothing on the ring), "Once" is an app-layer one-shot (`alarm.ring.oneShotOccurrence.v1`), Clear only while it matches `shortcuts.ringAlarm.v1` |
| `docs/HANDOFF_MACOS_IOS.md` | **Pickup instructions for the iOS work on macOS** |
| `docs/APP_STORE_SUBMISSION.md` | **App Store 1.0 submission: store-build state, ASC checklist, review notes, open guideline risks.** Developer tools, the BP calibration flow (and its HealthKit BP types) and the ring Debug card (7 taps on Profile's version line in Release) are hidden so Release passes review; keep it that way. The indoor location keep-alive stays in Release by owner decision (§4 risk) |
| `docs/ROADMAP.md` | Phases + risks |
| `ios/` | Swift app (Phase 3+, not yet created) |

## Conventions
- Captures in `desktop/captures/` are gitignored — they hold real health data. Commit
  decoded *findings* only, never raw captures.
- Tag every protocol claim 🟢 confirmed / 🟡 probable / 🔴 guess, with its source.
