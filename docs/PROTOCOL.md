# RingConn Gen 2 — BLE Protocol (living spec)

This is the primary deliverable of Phase 1. Everything here is an **observation**,
not vendor documentation. Mark each fact with a confidence level and the capture it
came from. Treat unconfirmed entries as hypotheses to disprove.

Confidence legend: 🟢 confirmed (reproduced) · 🟡 probable · 🔴 guess / unverified

---

## 1. Connection & GATT layout

> ⚠️ The device is reported to be **not fully GATT-compatible** — services may not
> advertise normally and tools may need to read by handle rather than by UUID.
> (Source: Gadgetbridge issue #4506.)

| Item | Value | Conf. | Source |
|---|---|---|---|
| Advertised name | `RingConn-…` / `R…` (TBD) | 🔴 | — |
| Notify characteristic | `8327ad97-2d87-4a22-a8ce-6dd7971c0437` | 🟡 | GB #4506 |
| Write characteristic | `8327ad98-2d87-4a22-a8ce-6dd7971c0437` | 🟡 | GB #4506 |
| Service A | `f7bf3564-fb6d-4e53-88a4-5e37e0326063` | 🔴 | GB #4506 |
| Service B | `984227f3-34fc-4045-a5d0-2c581f81a153` | 🔴 | GB #4506 |
| Live-HR notify handle | `0x0804` | 🟡 | GB #4506 |
| Keepalive write handle | `0x0802` | 🟡 | GB #4506 |

Action: run `openringconn scan` and fill the real advertised name, full
service/characteristic tree, handles, and characteristic properties
(notify/write/write-no-response).

## 2. Authentication / handshake

**Unknown.** Smart rings commonly require a per-session handshake (the app proves a
shared key or echoes a challenge) before history sync is allowed. Capture the very
first writes/notifications after connect on a *fresh* app launch.

Open questions:
- [ ] Is there a handshake at all, or does live HR work with no auth (matches the
      `0x0802 ← 95 00 95` keepalive observation)?
- [ ] Is a token derived from the ring's MAC / serial / a cloud-issued secret?
- [ ] Does history sync require auth that live HR does not?

## 3. Framing

**Unknown.** For each notification, log and look for:
- A fixed header byte / command id (compare openwhoop's "category byte" idea).
- A length field.
- A sequence counter (history packets usually increment).
- A checksum/CRC trailer (openwhoop's Whoop uses CRC-32 `0x4C11DB7` — test common
  CRC-8/16/32 variants against captured frames with `framing.guess_checksum`).

## 4. Commands (request → response)

Fill as decoded. Template:

| Command | Write (hex) | Response shape | Metric | Conf. |
|---|---|---|---|---|
| Keepalive | `95 00 95` → `0x0802` | (none?) | — | 🟡 |
| Live HR start | TBD | notify on `0x0804`, 7-bit HR | heart rate | 🔴 |
| Battery | TBD | TBD | battery % | 🔴 |
| Sync sleep | TBD | paged records | sleep stages | 🔴 |
| Sync HRV | TBD | paged records | RMSSD/RR | 🔴 |
| Sync SpO2 | TBD | paged records | SpO2 % | 🔴 |
| Sync steps/activity | TBD | paged records | steps, kcal | 🔴 |
| Sync temperature | TBD | paged records | skin temp | 🔴 |
| Set time | TBD | TBD | — | 🔴 |

## 5. Decoded metric formats

### Heart rate (live) 🟡
Handle `0x0804`. A 7-bit field holds BPM (e.g. `1001100` = 76). Confirm full byte
layout, whether RR intervals / signal-quality accompany it, and the sampling rate.

### (others)
Document each as decoded: byte offsets, scale/units, timestamp encoding
(epoch? minutes-since? local vs UTC?), and how multi-record pages are delimited.

---

## How to extend this file

1. Capture with the official app doing one thing (e.g. only a SpO2 measurement).
2. Isolate the writes/notifications in that window (`openringconn decode-log`).
3. Form a hypothesis about the command + response format; note it 🔴.
4. Replay the write with `openringconn replay` and confirm the response → 🟡.
5. Reproduce across sessions / values until stable → 🟢.
