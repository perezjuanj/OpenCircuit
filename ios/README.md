# OpenCircuit

Local-first, no-cloud health data for the **RingConn Gen 2/3** smart ring — read all
metrics over Bluetooth LE and write them to **Apple Health**. Inspired by
[openwhoop](https://github.com/bWanShiTong/openwhoop), which does the same for the
Whoop 4.0.

<a href="https://www.buymeacoffee.com/standardsoftware" target="_blank"><img src="https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=&slug=standardsoftware&button_colour=5F7FFF&font_colour=ffffff&font_family=Bree&outline_colour=000000&coffee_colour=FFDD00" alt="Buy me a coffee" height="40"></a>

> **OpenCircuit** is the user-facing name (home screen / store). The Xcode target,
> the bundle id (`com.standardsoftwaresolutions.opencircuit`), and the `OpenCircuitKit` Swift package
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

## What you get

Every metric below is decoded **on-device** from the ring's own Bluetooth stream and
written to **Apple Health** — nothing is sent to a server.

**Health metrics → Apple Health**

- ❤️ **Heart rate** — live, all-day, and during workouts
- 🫀 **Resting heart rate**
- 📈 **Heart-rate variability (HRV)**
- 🩸 **Blood oxygen (SpO₂)**
- 🌬️ **Respiratory rate**
- 🌡️ **Skin temperature** (overnight)
- 👣 **Steps** + an active-energy estimate
- 😴 **Sleep** — duration plus an on-device sleep-stage *estimate* (the ring sends no
  stage labels, so staging is computed locally and clearly labeled "est.")

**Ring & charging-case status, live in the app**

- 🔋 Ring **battery %**, raw **voltage**, and **time-to-empty / time-to-full** estimates
- ⚡ **Charging detection** — knows the instant the ring is on the charger
- 🧳 **Charging-case battery %** and whether the case itself is charging
- 🖐️ **Wear detection** — auto-measurement pauses when the ring is off-wrist or charging

**How it connects**

- 🔗 **Standalone, no cloud key** — the ring's per-connection authentication is fully
  reverse-engineered (an SM3 challenge keyed only on the ring's *own* MAC), so OpenCircuit
  connects and streams on its own, with **no RingConn account or app needed for everyday
  use**. A ring you've already set up with the official app is bonded and works
  immediately. *(One case is still being verified: a brand-new ring that has never been
  activated in the official app on any phone — see issue #106.)*
- 💍 Works with **any RingConn Gen 2 ring**, and **multiple rings per phone**.
- 🔄 Background sync, keepalive, and periodic auto-measure for continuous tracking.

## Use it alongside Bevel or Athlytic

OpenCircuit writes **standard Apple Health data types**, so any app that reads from
Apple Health can use your RingConn data — including recovery/readiness apps like
**Bevel** and **Athlytic** (both on the App Store), which normally pull from an Apple
Watch, Oura, or Whoop. OpenCircuit becomes the bridge:

```
RingConn Gen 2  →  OpenCircuit (BLE, on-device)  →  Apple Health  →  Bevel / Athlytic
```

Wear your RingConn, let OpenCircuit sync it to Apple Health, and get Bevel's or
Athlytic's recovery, readiness, strain, and sleep insights on top of **ring** data —
no Oura or Whoop subscription required.

## Local-first by design

- **Nothing leaves your phone** except the data you choose to write into Apple Health.
- **No RingConn cloud account, no subscription, no third-party server** — the ring talks
  BLE straight to a client you control.
- All decoding and analytics run **on-device**; raw BLE captures used for protocol
  reverse-engineering are gitignored and never committed — only decoded *findings* live
  in [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

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

python -m opencircuit scan          # find the ring, list services/characteristics
python -m opencircuit listen        # connect and log every notification (hex)
python -m opencircuit decode-log captures/btsnoop_hci.log   # parse an Android HCI capture
```

## Support

OpenCircuit is free and open-source. If it's useful to you, you can support development:

<a href="https://www.buymeacoffee.com/standardsoftware" target="_blank"><img src="https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=&slug=standardsoftware&button_colour=5F7FFF&font_colour=ffffff&font_family=Bree&outline_colour=000000&coffee_colour=FFDD00" alt="Buy me a coffee" height="40"></a>

## Legal / safety

For interoperability and personal data ownership. You own the ring and your data.
Don't redistribute RingConn firmware or proprietary assets. The BLE protocol facts
in `docs/PROTOCOL.md` are observations of traffic from your own device.
