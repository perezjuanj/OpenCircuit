# Handoff → continue on macOS (iOS incorporation)

You're picking this up on a Mac to start the **iOS app** (Phases 3–5). The Windows
machine produced the desktop reverse-engineering workbench and the docs. This file
is the single place to resume from.

## First, orient
1. Read `CLAUDE.md`, then `docs/ROADMAP.md` and `docs/PROTOCOL.md`.
2. Check how far Phase 1/2 got: open `docs/PROTOCOL.md` and see which entries are
   🟢 confirmed vs 🔴 guesses. **The iOS parser can only be as good as that spec.**

## Critical gate before writing much Swift
Confirm in `docs/PROTOCOL.md` whether the BLE link is **encrypted/authenticated**.
- If unencrypted and the sync command set is decoded → proceed to build the iOS app.
- If still unknown → the highest-value work is finishing Phase 1/2 on the desktop
  workbench first (it iterates faster than rebuilding/redeploying an iOS app).

## What the desktop workbench already gives you (reuse the knowledge, not the code)
`desktop/openringconn/` has, in Python, the things the Swift app must re-implement:
- `ble.py` — the observed UUIDs/handles (notify `8327ad97-…`, write `8327ad98-…`,
  live-HR handle `0x0804`, keepalive `95 00 95` → `0x0802`).
- `framing.py` — `decode_live_hr()` and the checksum parameters that matched real
  frames (port the matching CRC into Swift).
- `sniff.py` / captures — the decoded command→response pairs behind `PROTOCOL.md`.

## Build the iOS app (Phase 3)
Create `ios/` as a SwiftUI app. Suggested module layout:

```
ios/OpenRingConn/
  BLE/
    RingScanner.swift        # CBCentralManager: scan, match name/service, connect
    RingSession.swift        # subscribe notify char, write commands, keepalive
    RingCodec.swift          # framing + checksum + per-metric parsers (port from desktop)
  Model/
    Metrics.swift            # HeartRate, SpO2, SleepSegment, HRV, Steps, Temp …
    SyncCursor.swift         # last-synced timestamp per metric (avoid re-writing)
  Store/
    LocalStore.swift         # SwiftData: raw samples + cursors
  Health/
    HealthKitWriter.swift    # auth + write samples (see docs/HEALTHKIT_MAPPING.md)
  Analytics/                 # Phase 5: port openwhoop sleep/HRV/strain to Swift
  App.swift / ContentView.swift
```

CoreBluetooth notes:
- iOS gives **no raw ATT handles** — you address by characteristic UUID. The
  desktop captures used handles; map each handle to its UUID during `scan`/
  `enumerate` and record the UUID in `PROTOCOL.md` so Swift can use it.
- Background BLE sync needs the `bluetooth-central` background mode + state
  restoration if you want sync while the app is suspended.

## HealthKit (Phase 4)
- Add HealthKit capability; set `NSHealthShareUsageDescription` and
  `NSHealthUpdateUsageDescription` in Info.plist.
- Request write auth per type, then save samples with the **device's own
  timestamps** so history backfills correctly. Dedup via the per-metric sync cursor
  + a stable bundle id. Full type table: `docs/HEALTHKIT_MAPPING.md`.
- Gotchas already noted there: HealthKit stores **SDNN** (not RMSSD); sleep is many
  per-stage `sleepAnalysis` category samples, not one record.

## Definition of done per phase
See `docs/ROADMAP.md` "Exit" lines. Phase 3 exit: the iOS app pulls the same data
the desktop client does. Phase 4 exit: ring metrics appear in Apple Health offline.

## Environment differences from the Windows box
- Shell is zsh/bash, not PowerShell. Paths use `/`.
- You can capture iOS BLE with **PacketLogger** (Additional Tools for Xcode) +
  a paired iPhone, complementing the Android HCI snoop logs.
- Keep committing decoded findings to `docs/PROTOCOL.md`; never commit `captures/`.
