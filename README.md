# OpenCircuit

Local-first, no-cloud health data for the **RingConn Gen 2** smart ring — read all
metrics over Bluetooth LE and write them to **Apple Health**. Inspired by
[openwhoop](https://github.com/bWanShiTong/openwhoop), which does the same for the
Whoop 4.0.

> **OpenCircuit** is the user-facing name (home screen / store). The Xcode target,
> the bundle id (`com.dreamality.openringconn`), and the `OpenRingKit` Swift package
> keep their original internal names for continuity. See [`docs/ROADMAP.md`](docs/ROADMAP.md)
> for status.

> ⚠️ **Not affiliated with RingConn.** OpenCircuit is an independent interoperability
> project — not affiliated with, authorized, or endorsed by RingConn or JZ_Tech.
> "RingConn" is a trademark of its respective owner. OpenCircuit is **not a medical
> device**. Privacy: [`docs/PRIVACY.md`](docs/PRIVACY.md) · License: [`LICENSE`](LICENSE) (MIT).

## Why this exists

The RingConn app sends your data to RingConn's cloud (AWS, UK). OpenCircuit keeps
it on your devices: the ring talks BLE straight to a client you control, which
writes into Apple Health. No subscription, no third-party server.

## Architecture

```
┌─────────────────────── iOS App (Swift) — Phase 3+ ─────────────────────┐
│  CoreBluetooth  →  RingConn codec  →  Analytics  →  HealthKit (write)   │
│                          ↕                                              │
│                    Local store (SwiftData) ── sync cursor              │
└────────────────────────────────────────────────────────────────────────┘
        ▲ protocol spec produced by ▼
┌──── desktop/  RE workbench (Python + bleak) — Phase 1–2 (current) ──────┐
│  sniff app traffic → dissect → replay commands → decode each metric     │
└─────────────────────────────────────────────────────────────────────────┘
```

Only openwhoop's **analytics** (sleep/HRV/strain detection) port across devices;
its BLE transport and packet parser are Whoop-specific and are rewritten here.
HealthKit only exists on iOS, and iOS BLE must use CoreBluetooth, so the final
data-writing app must be native Swift — the desktop workbench is the throwaway
tool that decodes the protocol first.

## Layout

| Path | What |
|---|---|
| `desktop/` | Python + `bleak` reverse-engineering workbench (Phase 1–2) |
| `desktop/captures/` | Raw BLE capture logs (gitignored) |
| `docs/PROTOCOL.md` | Living protocol spec — the primary deliverable of Phase 1 |
| `docs/REVERSE_ENGINEERING.md` | How to capture and decode traffic |
| `docs/HEALTHKIT_MAPPING.md` | Each metric → its HealthKit type |
| `docs/ROADMAP.md` | Phases and current state |
| `ios/` | Swift app (created in Phase 3) |

## Quick start (desktop workbench)

```bash
cd desktop
python -m venv .venv && . .venv/Scripts/activate   # Windows; use bin/activate on *nix
pip install -r requirements.txt

python -m openringconn scan          # find the ring, list services/characteristics
python -m openringconn listen        # connect and log every notification (hex)
python -m openringconn decode-log captures/btsnoop_hci.log   # parse an Android HCI capture
```

## Legal / safety

For interoperability and personal data ownership. You own the ring and your data.
Don't redistribute RingConn firmware or proprietary assets. The BLE protocol facts
in `docs/PROTOCOL.md` are observations of traffic from your own device.
