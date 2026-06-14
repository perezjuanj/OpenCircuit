# RingConn Gen 2 — BLE Protocol (living spec)

This is the primary deliverable of Phase 1. Everything here is an **observation**,
not vendor documentation. Mark each fact with a confidence level and the capture it
came from. Treat unconfirmed entries as hypotheses to disprove.

Confidence legend: 🟢 confirmed (reproduced) · 🟡 probable · 🔴 guess / unverified

**Reference capture:** Android btsnoop, FW **FR02.018**, ring `RingConn Gen2-03AD`
(MAC `F8:79:99:F7:03:AD`), 2026-06-13 21:51. 326 ATT events: identity reads, a live
measurement (`0x95` poll loop), and a bulk history/PPG download. Pin observations
below to this FW until re-confirmed on another version.

---

## 0. Encryption gate — ANSWERED 🟢

**The BLE application layer is NOT encrypted.** ATT payloads in the capture are
plaintext: readable identity strings, monotonic counters, and a checksum that
validates (§3). No app-layer key exchange or challenge/response precedes data
access. Offline decoding is viable → the iOS app is unblocked.
(Link-layer LE encryption, if any, is transparent to CoreBluetooth — irrelevant.)

## 1. Connection & GATT layout

> ⚠️ Reported as not fully GATT-compatible. The capture confirms the app drives the
> ring almost entirely through two value handles (`0x0802` write, `0x0804` notify)
> rather than discrete per-metric characteristics.

### Identity (Device Information Service `0x180a`)
| Item | Value | Conf. | Source |
|---|---|---|---|
| Advertised name (GAP `0x2a00`, val handle `0x0003`) | `RingConn Gen2-03AD` (suffix = last 2 MAC bytes) | 🟢 | capture + scan |
| Manufacturer (`0x2a29`, val `0x0032`) | `JZ_Tech` | 🟢 | capture + scan |
| Serial (`0x2a25`, val `0x0034`) | `RCA1F252311002B09` | 🟢 | capture + scan |
| Firmware (`0x2a26`, val `0x0036`) | `FR02.018` | 🟢 | capture + scan |
| System ID / MAC (`0x2a23`, val `0x0038`) | `F8:79:99:F7:03:AD` | 🟢 | capture + scan |
| Hardware rev (`0x2a27`, val `0x003a`) | `00010001` | 🟢 | capture + scan |

### Primary data service `8327ad99-2d87-4a22-a8ce-6dd7971c0437` (handle `0x0800`) 🟢
The ring is driven entirely through this notify/command pair (not per-metric chars).
iOS addresses by UUID; the value handle = characteristic declaration handle + 1.

| Role | Characteristic UUID | Decl. | **Value** | Props | Conf. |
|---|---|---|---|---|---|
| **Write / commands** | `8327ad98-2d87-4a22-a8ce-6dd7971c0437` | `0x0801` | `0x0802` | write | 🟢 |
| **Notify (all responses + data)** | `8327ad97-2d87-4a22-a8ce-6dd7971c0437` | `0x0803` | `0x0804` | notify | 🟢 |
| Notify CCCD (enable w/ `01 00`) | `0x2902` | — | `0x0805` | — | 🟢 |

### Secondary service `1d14d6ee-fd63-4fa1-bfa4-8f47b42119f0` (handle `0x0900`) 🔴
Two **write** characteristics; role unobserved in the capture (likely OTA/firmware
or bulk transfer). Not used by the main protocol. Decode if needed later.

| Characteristic UUID | Handle | Props |
|---|---|---|
| `f7bf3564-fb6d-4e53-88a4-5e37e0326063` | `0x0901` | write |
| `984227f3-34fc-4045-a5d0-2c581f81a153` | `0x0903` | write, write-without-response |

> Corrections now confirmed by `scan`: (1) GB #4506's char UUIDs were right
> (🟡→🟢). (2) GB #4506 mislabeled `f7bf3564`/`984227f3` as *services* — they are
> *characteristics* inside service `1d14d6ee`; the real data service is `8327ad99`.
> (3) value handle = decl + 1, which ties the scan to the capture's `0x0802`/`0x0804`.

## 2. Authentication / handshake

**No app-layer handshake observed.** After enabling notifications (`0x0805 ← 01 00`)
the app immediately issues data commands and the ring responds — no token, no
challenge, no key derived from MAC/serial. History sync uses the same channel as
live data with no extra auth. (Re-verify on a *fresh pair* capture to be certain a
one-time bonding step isn't being skipped on an already-bonded phone.)

## 3. Framing 🟢 (verified live on the Mac)

**Commands and responses use DIFFERENT trailers — this corrects an earlier error.**

**Responses (RX, ring → host):** `[respid][payload…][xor]`
- **respid = command id XOR 0x80**: `01→81 · 02→82 · 06→86 · 07→87 · 95→15 · c7→47 · cc→4c · d0→50` (10 cmds reproduced).
- **xor trailer** = XOR of all preceding bytes. Validates on 86/88 RX frames. (The two `0x50` status frames lack it — see §5.)

**Commands (TX, host → ring):** `[cmd][sub][payload…][00]` — **NOT checksummed.**
- Sent **verbatim**; the last byte is a literal `0x00`, not an XOR. ⚠️ The GB #4506
  keepalive `95 00 95` is **wrong**; the real command is `95 00 00`. Building command
  frames by appending an XOR trailer produces invalid bytes the ring ignores.
- The ring ATT-acks any write but only *acts* on commands whose contents are valid.

Bulk frames (`0x47`/`0x4c`) pack fixed-size records, each prefixed by delimiter
`0x0c` + a **3-byte BE counter** in the sync-cursor space (`0x47` steps `+0x0384`,
`0x4c` steps `+0x96`; see §5.2/§5.3). Continue a page by ACKing: `0x47` → `c7 00 00`,
`0x4c` → `cc 00 00`; the page header byte[2] counts remaining records, `0x00` on the last.

## 4. Commands (request → response) 🟢

| Command | Write (hex) | Resp | Role | Conf. |
|---|---|---|---|---|
| Status read | `01 00 00` | `81 00 ..` | works unauthenticated; only cmd that replies cold | 🟢 |
| Status read 2 | `01 01 31 82 67 00` | `81 01 ..` (38B) | record/config table | 🟢 |
| **Sync open** | `02 00 <cursor:4> 00 01 00` | `82 ..` | opens data session; **cursor, not wall-clock** | 🟢 |
| Fetch / stream | `07 00 00` | `87`/`15`/`47`/`4c` | pulls next data per current mode | 🟢 |
| Live-HR mode | `06 01 00` | `86 00 86` | switch session to live HR | 🟢 |
| Poll | `95 00 00` | `15 ..` | one live sample per poll | 🟢 |
| Page ACK | `c7 00 00` / `cc 00 00` | `47`/`4c` | continue bulk transfer | 🟢 |
| Status query | `d0 00 00` | `10`/`50` | session/record status | 🟡 |

**The `02` arg is a sync CURSOR, not a timestamp** (🟢, this was the key unlock).
Real-time values are *rejected* (no `82`); only a cursor **≥ the ring's last-synced
position** is accepted. `02 00 FF FF FF FF 00 01 00` (max) always works and means
"sync everything". The capture's `0c 22 98 c3` was the app's then-current cursor;
replaying it now fails because the ring has since advanced past it.

**Verified live-HR sequence (from the Mac, `desktop/livehr.py`):**
```
01 00 00                  -> 81 ..        (wake/status)
01 01 31 82 67 00         -> 81 01 ..     (config table)
02 00 FF FF FF FF 00 01 00 -> 82 ..       (open sync, cursor=all)
07 00 00 + c7/cc acks     -> 87,47,4c ..  (drain any history backlog)
06 01 00                  -> 86 00 86     (enter live-HR mode)
07 00 00                  -> 15 ..        (first live sample)
95 00 00  (repeat)        -> 15 00 <hr> 0a b0 <xor>   (one HR sample per poll)
```
Caveats (🟡): live `15` frames require the ring **worn with good skin contact** and
a few seconds of PPG warm-up; and the ring sleeps/stops advertising seconds after
disconnect (wake via charger contact or motion). Metric-specific sync commands
(sleep/HRV/SpO2/steps/temp) not yet isolated.

> **Session-open nuances (🟡), from the HR-only capture.** Two args are
> **per-session, not fixed** — replaying captured values fails:
> - `01 01 <3 bytes>` carries a per-session **nonce** (`31 82 67`, then `f0 1e 88`,
>   `9c 61 91` across sessions). Our replays reused a stale nonce, so the session
>   never opened — this, not just the cursor, is why Mac live-HR replay stalled.
> - `02 00 <cursor:4> …` cursor advances each sync (`0c 22 98 c3` → `0c 22 bb f7`).
>   `FFFFFFFF` works only while a backlog exists.
> The HR DECODE is confirmed (above); reproducing the live stream on demand from the
> Mac needs the nonce + cursor derived correctly (source of the nonce still 🔴 —
> likely from an `81` response field). Not required for Phase 1.

## 5. Decoded metric formats

Structure below is from parallel structural RE of `captures/btsnoop_hr.log`
(FW FR02.018): 11× `0x47`, 3× `0x4c`, 6× `0x81`, ~40 `0x10`/`0x87`, 3× `0x50`,
3 sync-opens. **Structure is 🟢/🟡; semantic VALUES are mostly 🔴 pending
ground-truth captures (§6).**

> **Refines §3's bulk-record prefix.** The delimiter is a single byte `0x0c`; the
> bytes after it are a **3-byte big-endian counter** (the `09`/`0a`/`22` is its high
> byte — it rolls cleanly `0c 09 ff 9a → 0c 0a 00 30`). This counter shares the
> **same value space as the `0x02` sync cursor** (§5.6): late records sit at
> `0c 22 xx xx`, matching cursor `0c 22 98 c3`. The `+0x0384`/record step is the
> `0x47` rate; `0x4c` steps `+0x96`.

### 5.1 Heart rate (live) 🟢 CONFIRMED
`0x95` poll → `0x15`: **`15 00 <hr> 0a b0 <xor>`**, byte[2] = HR bpm (61 bpm resting
in the HR-only capture). First sample is a warm-up sentinel (byte[2] ≈ 8); treat
< ~30 as "not locked". Longer `15 01 …` frames carry extra fields (SpO2? 🔴).

### 5.2 `0x47` — bulk PPG / waveform page (ACK each with `c7 00 00`)
Page: `[0]`=`0x47` · `[1]`=`00` · **`[2]`=remaining-RECORD countdown** (−5/full page,
0 on last; e.g. `1c 17 12 0d 08 03 00`) · body = N×**47-byte records** · `[last]`=XOR
(valid 11/11). 🟢
Record (47 B): `[0]`=`0x0c` · `[1:4]`=BE counter **+0x0384/rec** (cursor space) 🟢 ·
`[4:6]`=16-bit field drifting with baseline 🟡 · `[6:9]`=usually `00 00 00`, else
per-record flag/event 🟡 · `[9:47]`=**38 B ≈ 30 samples × 10-bit BE** (self-consistent
but unproven; 10-vs-12-bit ambiguous) 🟡. Waveform is flat/settling when idle,
oscillatory (pulsatile-like) when worn — not globally monotonic.

### 5.3 `0x4c` — bulk activity/sleep page (ACK each with `cc 00 00`)
Page: `[0]`=`0x4c` · `[1]`=`00` · **`[2]`=remaining-RECORD countdown** (−6/page) ·
body = 6×**23-byte records** · `[last]`=XOR. 🟢
Record (23 B): `[0]`=`0x0c` · `[1:4]`=BE counter **+0x96/rec** (cursor space) 🟢 ·
`[8]`=subtype tag (idle alternates `12/13`) 🟢 · `[10:15]`=baseline `01 01 01 01 01` ·
`[15:22]`=7-B payload (zero idle, dense when worn) 🟡 · `[22]`=trailer flags (idle
`12→00`/`13→04`) 🟢. Idle/unworn template: `[4:7]=05 00 0c 00`, `[9]=0a`, `[10:14]=01×5`,
`[15:21]=00×7` 🟢. Likely the per-epoch sleep/activity stream (role = inference).

### 5.4 `0x10` / `0x87` — fixed 19-byte descriptor
`0x10` ← `d0 00 00` (also spontaneous ~30–60 s); `0x87` ← `07 00 00`. **Identical
layout** (only `[0]` respid differs; `0x87` body == `0x10` body) → shared descriptor,
XOR-valid. `[1]`=per-session marker (`4e`→`5c`; same value in `0x81 01`) 🟡 · `[2]`=
state enum `01–04` (not a counter) 🟡 · `[6:8]`/`[8:10]`=16-bit A/B with validity
flag byte (`00`+`fd` cold, `01`+value once data exists) 🟡 · `[15]`=declines over an
evening but **not plain battery** 🟡 · `[17]`=`ff` idle; **non-`ff` precedes a bulk
stream → "data follows"** 🟡.

### 5.5 `0x50` — end-of-history cursor report (NO XOR trailer) 🟡
Spontaneous after the last bulk page. Distinct class: **no XOR trailer** (last byte
is the low byte of the final cursor). `[0:3]`=`50 00 00`, then 6-byte entries
`[type=15][sub][cursor:4 BE]` — decodes as a **from/to cursor pair** bracketing the
synced range, e.g. `50 00 00 | 15 12 0c22aae4 | 15 12 0c22acb5`. A 21-byte variant
is undecoded 🔴.

### 5.6 `0x02` sync cursor — TIMESTAMP 🟢 CONFIRMED
Host write `02 00 <cursor:4 BE> <flag:1> 01 00` → `82 00 00 82`.
**cursor = 4-byte BE seconds since epoch `1577793600` (2019-12-31 12:00:00 UTC)** —
3 (time,value) pairs + 2 in-frame cross-checks agree to <0.34 s; 1/sec, monotonic;
same epoch as the record counters. Build current: `floor(unix_utc) − 1577793600`,
BE, into `02 00 <BE4> 00 01 00`; `FF FF FF FF` = "everything" while backlog exists.
The 12 h offset vs 2020-01-01 is byte-confirmed but its **cause** (local-tz vs
firmware epoch vs AM/PM) is unresolved from one timezone 🟡. `flag` byte[6]
(`00`/`03`) meaning unknown 🟡.

### 5.7 `0x81` — status replies (← `0x01`)
**`81 00 XX YY`** (← `01 00 00`): `[2]` is the only varying byte, full 8-bit range,
>100 → **not battery %**; likely a session token 🔴.
**`81 01 …`** (38 B, ← `01 01 <nonce>`): mostly constant; notable — `[27:32]`=
`21 49 ac <XX> f4` (4/5 const, device-id-like) · `[34:36]`=16-bit monotonic counter
≈ 1/sec (30→1475→9045 over 3 sessions) 🟡. The `01 01 <3-B nonce>` arg is per-session
and **arbitrary** (ring accepts any value — see §4); the constant `21 49 ac _ f4`
block is a candidate nonce source 🔴.

## 6. Ground-truth captures needed (prioritized)

Each names the single capture that converts a 🟡/🔴 field into a decoded metric.
1. **`0x47` → real PPG:** app's realtime/exported PPG trace recorded over the *same*
   window as a btsnoop sync → confirms bit-width, channel, counter time-unit.
2. **`0x4c` → sleep/HR/HRV/SpO2 epochs:** one fully app-logged night with timestamped
   per-epoch values + session start/end → map the `+0x96` counter and payload bytes.
3. **Counter→wall-clock:** two syncs a known gap apart (ring worn) → pins counter units.
4. **`0x10`/`0x87` `[6:8]`/`[15]`:** sync after a known wear interval + app UI/battery
   screenshot → maps A/B to record counts and `[15]` to a real quantity.
5. **`0x81` token vs battery:** repeat `01 00 00` within a session & across battery
   levels → is `81 00 [2]` a token or battery; disambiguate `81 01 [34:36]`.
6. **`0x02` epoch cause:** a capture incl. the clock-SET command, or a sync from a
   phone set to UTC → resolves the 12 h offset.
7. **Session nonce source:** correlate `01 01 <nonce>` against prior `0x81`/`0x10`
   fields. *(Not required — nonce is arbitrary; §4.)*

---

## How to extend this file

1. Capture with the official app doing one thing (e.g. only a SpO2 measurement).
2. Isolate the writes/notifications in that window (`openringconn decode-log`).
3. Form a hypothesis about the command + response format; note it 🔴.
4. Replay the write with `openringconn replay` and confirm the response → 🟡.
5. Reproduce across sessions / values until stable → 🟢.
