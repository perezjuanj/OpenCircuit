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
| `docs/RUNBOOK_SLEEP_GROUNDTRUTH.md` | **Capture RingConn's computed hypnogram (`sleepPhases`) via mitmproxy → fit our staging to it** |
| `docs/RUNBOOK_OSA_APNEA.md` | **OSA sleep-apnea (#91) — capture cracked (start `05 22 01`, dense PPG `0x48`), decode→AHI parked; forward plan** |
| `docs/RUNBOOK_GEN3_BP_HAPTIC.md` | **Gen 3 vibrate motor + BP-calibration collection, written for a NON-DEV helper (iPhone→Mac capture). Landmines in "Notes for us": the vibrate opcode is NOT in the APK (capture only, don't re-mine), `BleSub*` means sub-DEVICE not sub-command, and RingConn's BP is cloud-computed — the raw PPG is on the wire, their number isn't** |
| `desktop/ringconn_sleep_fit.py` | Supervised-fit harness: align our epochs to RingConn `sleepPhases`, fit `SleepStaging.Tuning` (`--synthetic` to demo) |
| `docs/SLEEP_REPLAY_HARNESS.md` | **Swift replay harness — stage any night from raw bytes via `swift test`.** Measure a staging change instead of arguing about it; read §2 (production parity) and §4 (the edit trap) before quoting any number |
| `docs/HEADACHE_SIGNALS.md` | **Headache signals (#183) — plan of record. Read §1 first: the honest accuracy arithmetic is why the alert must EARN its way on per-user** |
| `docs/RUNBOOK_HEADACHE_VALIDATION.md` | **On-device validation for #183 (freeze / migration / HealthKit) + the tester-facing "What to Test"** |
| `docs/RUNBOOK_SCHEMA_MIGRATION_REHEARSAL.md` | **MANDATORY before shipping any SwiftData schema change. Two gates: "Gate A" is the named suite invocation `-only-testing:OpenCircuitTests/ShippedStoreMigrationTests` — run it on its own and check the executed-test COUNT, because a full-target run has already skipped the whole suite silently; then rehearse the upgrade on a real phone from a PRE-45 build. Build 44 deleted every raw history row on upgrade; a simulator pass and a current-build store both skip the defect** |
| `docs/HEALTHKIT_MAPPING.md` | Each metric → HealthKit type |
| `docs/BACKGROUND_SYNC.md` | **How the official RingConn app syncs to Apple Health without being opened (RE'd blueprint) → mapped to our BGTask + CoreBluetooth-restoration implementation (#119); deliberate divergences + validation runbook** |
| `docs/HANDOFF_MACOS_IOS.md` | **Pickup instructions for the iOS work on macOS** |
| `docs/ROADMAP.md` | Phases + risks |
| `ios/` | Swift app (Phase 3+, not yet created) |

## Conventions
- Captures in `desktop/captures/` are gitignored — they hold real health data. Commit
  decoded *findings* only, never raw captures.
- Tag every protocol claim 🟢 confirmed / 🟡 probable / 🔴 guess, with its source.
