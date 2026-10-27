# Zepp OS BLE protocol: Amazfit Helio Strap (living spec)

Facts-only specification of the Zepp OS ("Huami 2021") BLE protocol as used by the
**Amazfit Helio Strap**, written for a clean-room Swift implementation (#215). This is the
Phase-0 deliverable of the Helio plan: an implementer must be able to build the transport,
auth, session setup and history fetch **from this document alone**.

**Clean-room rules for this file.** It describes the protocol in prose, tables and byte
diagrams. It contains no code and no pseudo-code from the reference implementations, no
copied comments, and no identifiers except the protocol's own names (UUIDs, opcode values,
endpoint numbers). Every worked example was **constructed for this document** from made-up
keys and made-up readings; none is a capture or a fixture from another project.

Confidence legend (same as `PROTOCOL.md`): 🟢 confirmed on our own strap · 🟡 probable
(two sources agree, or one source that is known to work on the Helio) · 🔴 guess / single
source / inference. §10 is the checklist that promotes claims to 🟢. §10.1 records the first
run on Juan's strap (2026-09-30); the claims it confirmed are 🟢 with the source
`HW:2026-09-30 (hw 0.132.27.2)`, and everything else keeps its 🟡/🔴 tag.

## Source key

Citations use these aliases. Line numbers are 1-based at the pinned commit.

| Alias | What | Pin |
|---|---|---|
| `GB/` | Gadgetbridge (AGPL-3.0), path under `app/src/main/java/nodomain/freeyourgadget/gadgetbridge/` | codeberg `Freeyourgadget/Gadgetbridge@03ee088f090a17d8183492fa38438ff48d0a6ccf` (2026-09-28) |
| `ENC` | `GB/service/devices/huami/Huami2021ChunkedEncoder.java` | same |
| `DEC` | `GB/service/devices/huami/Huami2021ChunkedDecoder.java` | same |
| `SUP` | `GB/service/devices/huami/zeppos/ZeppOsSupport.java` | same |
| `BTLE` | `GB/service/devices/huami/zeppos/ZeppOsBtleSupport.java` | same |
| `AUTH` | `GB/service/devices/huami/zeppos/services/ZeppOsAuthenticationService.java` | same |
| `ECDH` | `GB/util/ECDH_B163.java` | same |
| `CRY` | `GB/util/CryptoUtils.java` | same |
| `FETCH` | `GB/service/devices/huami/operations/fetch/AbstractFetchOperation.java` | same |
| `REPEAT` | `GB/service/devices/huami/operations/fetch/AbstractRepeatingFetchOperation.java` | same |
| `FOP/<Name>` | `GB/service/devices/huami/operations/fetch/Fetch<Name>Operation.java` | same |
| `SVC/<Name>` | `GB/service/devices/huami/zeppos/services/ZeppOs<Name>Service.java` | same |
| `HS` | `GB/devices/huami/HuamiService.java` | same |
| `BLT` | `GB/service/btle/BLETypeConversions.java` | same |
| `HC` | HelioCore (no licence; facts only), `GooseSwift/GooseSwiftApp.swift` | github `a9eelsh/heliocore@ca2a4fa0cd3a10d926c8705957ef91e7251aaa18` (2026-06-03) |
| `TE` | tiny-ECDH-c (Unlicense), `ecdh.c` / `ecdh.h` | `kokke/tiny-ECDH-c@a6095d6e1feaa4e77b84cddda8468d8651ca3a32` |
| `OC-vec` | Vectors computed for this document: tiny-ECDH-c, cross-checked by an independent pure-Python sect163r2 implementation, AES via Python `cryptography` and LibreSSL, CRC via zlib | 2026-09-30 |
| `GB-res/` | Gadgetbridge resources, path under `app/src/main/res/` (§11–§15 only) | same pin as `GB/` |
| `GB#N` | Gadgetbridge issue or pull request N on codeberg `Freeyourgadget/Gadgetbridge` (issues and PRs share one number space) | fetched 2026-09-30 |
| `GB@sha` | a Gadgetbridge commit, cited for *when* a behaviour was added (§11–§15 only) | codeberg, fetched 2026-09-30 |
| `AMZ-S` | Amazfit support page for the Helio Strap, https://support.amazfit.com/us/amazfit_helio_strap/docs/OSUldKzExovDlRxnMyCcH10dnL0 (© 2025) | fetched 2026-09-30 |
| `AMZ-M` | Amazfit Helio Strap user manual, https://support.amazfit.com/us/amazfit_helio_strap/files/user-manual.pdf.pdf (PDF created 2025-08-07); `AMZ-M p.N` = printed page N | fetched 2026-09-30 |
| `HW:2026-09-30 (hw 0.132.27.2)` | Our own HelioVerify run against Juan's Helio Strap: hardware revision 0.132.27.2 (his Zepp account lists firmware 3.3.6.5), macOS CoreBluetooth, every ack `03 09`. Control bytes and lengths only; results in §10.1 | 2026-09-30 |
| `HW:2026-09-30 13:35` | Juan's read-only re-test of the same strap with HelioVerify at `293cd90`, every ack `03 09`: the activity CRC, a full 12 h round, the device-info firmware read and HEALTH arg `0x04`. Results in §10.1 | 2026-09-30 |

HelioCore is the only reference known to run on a real Helio Strap from iOS; Gadgetbridge
covers the whole Zepp OS family and marks the Helio Strap *experimental*
(`GB/devices/huami/zeppos/straps/AmazfitHelioStrapCoordinator.java:33`). Where they
disagree, §9 says so.

---

## 1. Scope and device identification

| Fact | Tag | Source |
|---|---|---|
| The strap advertises the local name **`Amazfit Helio Strap`**, with no MAC suffix. | 🟡 | `GB/devices/huami/zeppos/straps/AmazfitHelioStrapCoordinator.java:39` |
| Zepp OS devices in general may append a 4-character suffix separated by a space or hyphen (`Amazfit Helio Strap 1A2B`, `…-1A2B`). Some devices advertise a second, hyphen-suffixed identity used only for calls. A matcher should accept the exact name, optionally followed by one or more of `-`/space and exactly four `[A-Z0-9]`. | 🟡 | `GB/devices/huami/zeppos/ZeppOsCoordinator.java:99-117` |
| The **Helio Ring** advertises `Amazfit Helio Ring` and speaks the same protocol (same base class, no protocol overrides). Distinguish strap from ring by the name only. | 🟡 | `GB/devices/huami/zeppos/rings/AmazfitHelioRingCoordinator.java:37` |
| Other Zepp OS watches use other exact names (e.g. `Amazfit Balance`); none begins with `Amazfit Helio`. A prefix match on `Amazfit Helio Strap` is therefore sufficient to exclude them. | 🟡 | `GB/devices/huami/zeppos/watches/*Coordinator.java` |
| The strap has **no display** and Gadgetbridge declares it a fitness band. | 🟡 | `AmazfitHelioStrapCoordinator.java:53-55,69-71` |
| Manufacturer data / advertised service UUIDs: **not used by either reference; unknown.** | 🔴 | — (capture item §10) |
| HelioCore's scanner accepts any name containing `helio`, `amazfit` or `zepp` (case-insensitive). Too loose for OpenCircuit: it would also match watches. | 🟡 | `HC:1056` |
| A post-auth **device-info** request (§5.3) returns a flags word; for the Helio Strap Gadgetbridge records it as `0x7f`. It also returns a PnP ID from which a product id / version can be read at PnP bytes 3–4 and 5–6 (little-endian). | 🟡 | `SVC/DeviceInfo:95-101,158-160` |
| Gadgetbridge supports a Bluetooth-Classic transport for some Zepp OS watches. **Ignore it**: iOS is BLE-only, and the Helio uses the BLE path. | 🟡 | `GB/devices/huami/zeppos/ZeppOsCoordinator.java:121-132` |

Firmware seen in the wild on Helio Straps: **3.11.0** and **3.11.0.1** (user reports,
Gadgetbridge issues #5986 opened 2026-04-08 and #5843 opened 2026-03-06). Juan's strap:
hardware revision **0.132.27.2** (DIS `0x2A27`); his Zepp account lists firmware **3.3.6.5**.
The strap has **no DIS firmware-revision characteristic** (`0x2A26`) 🟢
`HW:2026-09-30 (hw 0.132.27.2)`. Its own device-info read (endpoint `0x0043`, §5.3) reports
firmware **3.25.0.3** 🟢 `HW:2026-09-30 13:35`, not the 3.3.6.5 the Zepp account lists.

---

## 2. GATT map

All Huami-specific UUIDs are 128-bit: `0000XXXX-0000-3512-2118-0009af100700`, written below
as `…XXXX`. Discover characteristics **by UUID across all services** rather than assuming
which service holds them (that is what HelioCore does, `HC:1101-1106`).

| UUID | Name here | Props needed | Direction / use | v1? | Tag / source |
|---|---|---|---|---|---|
| service `0xFEE0` | Huami main service | — | parent of the chunked and activity characteristics | yes | 🟡 `HS:28`, `BTLE:75` |
| `…0016` | **chunked-write** | write (HelioCore uses write-without-response) and notify | phone → device message chunks; device's *chunk acks* may arrive here as notifications | **yes** | 🟢 present `HW:2026-09-30 (hw 0.132.27.2)`; 🟡 `HS:57`, `SUP:1074-1075,1145-1156`, `HC:607,894-899` |
| `…0017` | **chunked-read** | notify, write | device → phone message chunks (notify); phone writes its *chunk acks* **to this same characteristic** | **yes** | 🟢 present `HW:2026-09-30 (hw 0.132.27.2)`; 🟡 `HS:58`, `BTLE:138`, `SUP:1158-1165` |
| `…0004` | **activity-control** | write, notify | history-fetch control (§6) | **yes** | 🟢 present and used for every fetch `HW:2026-09-30 (hw 0.132.27.2)`; 🟡 `HS:44`, `SUP:962,973`, `HC:609,944` |
| `…0005` | **activity-data** | notify | history-fetch data packets (§6) | **yes** | 🟢 present and used for every fetch `HW:2026-09-30 (hw 0.132.27.2)`; 🟡 `HS:45`, `SUP:963,1077-1078`, `HC:610` |
| `0x180D` / `0x2A37` | Heart Rate Measurement | notify | live HR (§7) | **yes** | 🟢 present `HW:2026-09-30 (hw 0.132.27.2)`; 🟡 `BTLE:72`, `SUP:1089-1090`, `HC:611` |
| `0x180A` | Device Information Service | read | firmware / hardware revision strings, PnP ID; a leading `V` on the firmware string is stripped by Gadgetbridge. **On the Helio only the hardware revision `0x2A27` is exposed: there is no firmware revision `0x2A26`** | recommended | 🟢 `HW:2026-09-30 (hw 0.132.27.2)` for what the Helio exposes; 🟡 `BTLE:73,78-105` |
| `0x2A2B` | Current Time | write | time-set fallback when the time endpoint is absent (§5.1) | fallback | 🟢 present `HW:2026-09-30 (hw 0.132.27.2)` (not written); 🟡 `BTLE:180-183` |
| `0x180F` / `0x2A19` | Battery Level | read/notify | HelioCore records the characteristic if discovered but never reads or subscribes to it; Gadgetbridge does not use it. **Present on the Helio.** | optional | 🟢 present `HW:2026-09-30 (hw 0.132.27.2)`; `HC:612,1106,1127` |
| `…0001` / `…0002` | raw sensor control / data | — | raw accelerometer stream; not needed | no | 🟡 `HS:37-38` |
| `…0023` / `…0024` | file transfer v3 | — | not needed | no | 🟡 `HS:63-64` |
| `00001530-…` service, `…1531`/`…1532` | firmware update | — | **never write** | no | 🟡 `HS:31-34` |

Before sending anything, **enable notifications on `…0017`** (Gadgetbridge does so first,
`BTLE:138`). Enable notifications on `…0004` and `…0005` before a history fetch (§6).

Of the characteristics HelioVerify looks for, Juan's strap exposed `…0016`, `…0017`, `…0004`,
`…0005`, `0x2A37`, `0x2A19`, `0x2A2B` and `0x2A27`; only `0x2A26` was missing. 🟢
`HW:2026-09-30 (hw 0.132.27.2)`. Not recorded in that run: which service each sits under,
their properties, and the write types `…0016`/`…0004` accept (§10 item 2).

---

## 3. Transport: the chunked ("Huami 2021") protocol

Every command/response except the activity characteristics and standard GATT
characteristics travels as a **message** addressed to a 16-bit **endpoint**, split into
**chunks** that are written to `…0016` (phone → device) or notified on `…0017`
(device → phone).

### 3.1 Chunk header

Byte diagram of one chunk. All multi-byte integers in this protocol are **little-endian**.

```
first chunk of a message (11-byte header):
 +------+-------+------+--------+-------+-----------------------+-----------------+----------
 | 0x03 | flags | 0x00 | handle | count | total length (u32 LE) | endpoint (u16 LE) | data...
 +------+-------+------+--------+-------+-----------------------+-----------------+----------
   [0]    [1]     [2]     [3]      [4]         [5..8]                 [9..10]        [11..]

every later chunk (5-byte header):
 +------+-------+------+--------+-------+----------
 | 0x03 | flags | 0x00 | handle | count | data...
 +------+-------+------+--------+-------+----------
```

| Field | Meaning | Tag / source |
|---|---|---|
| `[0]` = `0x03` | marks a chunk. The receiver ignores anything else on `…0017` except a chunk ack (§3.4). | 🟡 `ENC:136`, `DEC:69-72`, `SUP:1132-1141` |
| `[1]` flags | bit `0x01` **first** chunk · bit `0x02` **last** chunk · bit `0x04` **ack requested** (always set together with *last*) · bit `0x08` **encrypted** (set on *every* chunk of an encrypted message). A single-chunk message therefore has `0x07` (plain) or `0x0F` (encrypted). | 🟡 `ENC:115-135`, `DEC:73-77` |
| `[2]` | "extended header" byte. The phone always writes `0x00`; the receiver skips this byte. | 🟡 `ENC:138-141`, `DEC:79-81`, `SUP:161` (Zepp OS forces the extended form) |
| `[3]` handle | message id, **u8**, per direction. The phone increments its handle **before** each message, so the first message after (re)connect uses `0x01`; it wraps `0xFF → 0x00`. Every chunk of one message carries the same handle. Reset to 0 on every (re)connect/re-auth. | 🟡 `ENC:64,160-163`, `SUP:297-299` |
| `[4]` count | chunk index within the message, u8, starting at `0x00`. | 🟡 `ENC:68,156` |
| `[5..8]` total length | length of the **plaintext** payload in bytes, even for encrypted messages (the ciphertext is longer, §3.3). First chunk only. | 🟡 `ENC:125-128`, `DEC:90-99` |
| `[9..10]` endpoint | 16-bit endpoint number (§3.5 lists them). First chunk only. | 🟡 `ENC:129-130`, `DEC:101` |

### 3.2 Chunk size, MTU and reassembly

- **Max data per chunk** = (ATT MTU − 3) − header size, where header size is 11 for the
  first chunk and 5 for the rest. ATT MTU − 3 is capped at 512. 🟡
  `ENC:111`, `GB/service/btle/AbstractBTLEDeviceSupport.java:92-100`.
  On iOS, use `maximumWriteValueLength(for:)` as the "(MTU − 3)" term: it is what the OS
  actually negotiated. 🔴 (inference; do **not** hard-code 247 as HelioCore does, `HC:843`).
- Gadgetbridge starts every connection assuming MTU 23 (`BTLE:143`, `SUP:158`) and, after
  auth succeeds, requests MTU 247 if the user allows high MTU (`BTLE:191-195`). The device can
  also announce an MTU on endpoint `0x0015` (reply `02` + u16 LE value = MTU − 3,
  `SVC/Connection:49-53`). 🟡
- A chunk is "last" when the remaining payload fits in the current chunk's capacity.
- **Reassembly (device → phone)**: on a *first* chunk, read total length and endpoint and
  start a buffer. For an encrypted message the buffer must hold the *padded ciphertext*
  length, `pad16(total length + 8)` (§3.3). Append every chunk's data. On the *last* chunk,
  decrypt if flagged, **truncate to total length**, and dispatch by endpoint. 🟡 `DEC:89-141`.
- Gadgetbridge ignores chunks whose handle differs from the message being reassembled and
  does not check `count` for gaps or order (`DEC:82-88`). See §9 for why OpenCircuit should
  be stricter.

### 3.3 Encryption

Which endpoints are encrypted is decided per endpoint by the **services list** the device
returns after auth (§5.2); the auth endpoint itself is always plaintext. 🟡 `SVC/Services:62-90`,
`AUTH:57`.

For an encrypted message with plaintext payload `P` of length `L`:

1. Build `P ‖ S ‖ C ‖ Z`, where
   - `S` = the current **encrypted-sequence number** as u32 LE, then increment it by 1 for
     the next encrypted message (it is only consumed by encrypted messages);
   - `C` = **CRC-32** (IEEE 802.3 / zlib / `java.util.zip.CRC32`: reflected, polynomial
     `0xEDB88320`, init and xorout `0xFFFFFFFF`) computed over `P ‖ S`, stored as u32 LE;
   - `Z` = zero bytes to pad the total to a multiple of 16 (none if `L + 8` already is).
   🟡 `ENC:81-99`, `GB/util/CheckSums.java:102-106`
2. **Message key** = the 16-byte **session key** (§4.4) with **every byte XORed with the
   message's handle byte**. 🟡 `ENC:77-80`, `DEC:115-118`
3. Encrypt the padded buffer with **AES-128 in ECB mode, no padding** (each 16-byte block
   independently). No IV. 🟡 `CRY:45-57`, `ENC:101`
4. Chunk the ciphertext as in §3.2, with flag `0x08` on every chunk, and total length = `L`
   (the plaintext length), not the ciphertext length. 🟡 `ENC:116-128`

**Receiving**: decrypt the reassembled ciphertext with the same message-key rule, using the
*incoming* chunk's handle, then keep the first `L` bytes. Gadgetbridge does **not** check the
device's trailing sequence number or CRC (`DEC:106-126`). The device's trailer has the same
`S ‖ C` layout: on the Helio, encrypted replies on `0x000A` and `0x001A` decrypted and the CRC
in their trailer matched `CRC-32(P ‖ S)`. 🟢 `HW:2026-09-30 (hw 0.132.27.2)`. Still open: whether the device's sequence
numbers are its own or follow ours (§10 item 5).

The sequence number starts at the value derived during auth (§4.4) and is per connection.
Gadgetbridge resets it to 0 on reconnect before re-auth overwrites it (`ENC:160-163`).

### 3.4 Chunk-level acks

- When a device → phone message's last chunk has flag `0x04`, the phone acknowledges by
  **writing to `…0017`** (the chunked-*read* characteristic) the 5 bytes
  `04 00 <handle> 01 <count>` where `<handle>` and `<count>` are those of the last chunk
  received. 🟡 `SUP:1131-1137,1158-1165`, `DEC:59-65,87-88,143`
- The device may acknowledge phone → device messages with a notification on `…0016`
  starting `04`, handle at byte `[2]`, count at byte `[4]`. Gadgetbridge only logs it and
  does not wait for it (no flow control). 🟡 `SUP:1145-1156`
- HelioCore sends **no** chunk acks and still completes auth and fetch on a Helio. 🟡
  (`HC` has no ack path). Recommendation: send them as Gadgetbridge does.

### 3.5 Endpoints relevant to v1

| Endpoint | Name here | Default encrypted (before the services list overrides) | Source |
|---|---|---|---|
| `0x0000` | services list | no | 🟡 `SVC/Services:32,38` |
| `0x000A` | config (settings) | yes | 🟡 `SVC/Config:104,116` |
| `0x000F` | alarms (§12) | no | 🟡 `SVC/Alarms:47,72` |
| `0x0015` | connection (MTU announce, ping/pong) | yes | 🟡 `SVC/Connection:30,38` |
| `0x0016` | steps (realtime) | no | 🟡 `SVC/Steps:34,45` |
| `0x0017` | user info | yes | 🟡 `SVC/UserInfo:45,51` |
| `0x0018` | vibration patterns (§13.1) | yes | 🟡 `SVC/VibrationPatterns:44,50` |
| `0x0019` | workout status, phone GPS (§16.2, §18) | yes | 🟡 `SVC/Workout:42,70` |
| `0x001A` | find device / find phone (§11) | yes | 🟡 `SVC/FindDevice:34,60` |
| `0x001D` | heart rate (realtime control) | no | 🟡 `SVC/HeartRate:36,59` |
| `0x001E` | notifications: **not used for the strap** (§13.3) | yes | 🟡 `SVC/Notification:59,98` |
| `0x0029` | battery | yes | 🟡 `SVC/Battery:32,38` |
| `0x0043` | device info | no | 🟡 `SVC/DeviceInfo:48,56` |
| `0x0047` | time | no | 🟡 `SVC/Time:39,49` |
| `0x004B` | activity-fetch control (chunked alternative to `…0004`) | yes | 🟡 `SVC/ActivityFetch:30,35` |
| `0x0082` | **authentication** | **never** | 🟡 `AUTH:47,57` |

(Endpoint numbers coincide numerically with some characteristic short UUIDs, e.g. `0x0016`,
`0x0017`. They are unrelated namespaces.)

The `0x000F`, `0x0018`, `0x001A` and `0x001E` rows were added by the device-controls addendum
(§11–§15). The `0x0019` row was added by the parity addendum (§16–§21). As with every row, the services list (§5.2) decides whether the endpoint exists on
the connected strap and whether it is encrypted.

**The Helio Strap's services list** (🟢 `HW:2026-09-30 (hw 0.132.27.2)`): 28 endpoints, `*` = encrypted:
`0000 0081* 0015 0047 0029 0017* 0028 0043 000a* 0030* 000d 0048 0016 0022 0049 0032 0036*
001d 0031 0018* 0082 0025 004b 000c* 004d* 0019* 000f 001a*`. Every endpoint in the table
above is present except notifications `0x001E` (§13.3). Three of them differ from the default
column: connection `0x0015`, battery
`0x0029` and activity-fetch `0x004B` are **plaintext** on this strap. This is why the services
list, not the defaults, decides encryption (§5.2).

A **connection ping**: the device may send `03` on endpoint `0x0015`; answer `04` on the
same endpoint. 🟡 `SVC/Connection:54-58`

### 3.6 Worked example A: plaintext, multi-chunk (constructed)

The auth public-key message of §4 (52-byte payload, endpoint `0x0082`, handle `0x01`) at
MTU 23. Capacity: first chunk 20 − 11 = 9 bytes, later chunks 20 − 5 = 15 bytes, so
9 + 15 + 15 + 13 = 52 over four chunks. `OC-vec`

```
chunk 0 (20 B): 03 01 00 01 00 | 34 00 00 00 | 82 00 | 04 02 00 02 a1 e4 ad 02 c2
chunk 1 (20 B): 03 00 00 01 01 | a4 4e a2 41 52 96 2c 14 0e a0 63 c6 9b 2e 5c
chunk 2 (20 B): 03 00 00 01 02 | 07 00 00 00 cd 50 73 a0 6d 67 b7 8a 3b c5 f5
chunk 3 (18 B): 03 06 00 01 03 | 19 ab 85 fb 9c f5 85 5d c8 01 00 00 00
```

Flags: `01` first, `00` middle, `06` last + ack-requested. Total length `0x34` = 52.
The same message at MTU 247 is one 63-byte chunk starting `03 07 00 01 00 34 00 00 00 82 00`.

### 3.7 Worked example B: encrypted (constructed, made-up key)

Session key (from worked example C, §4.6): `8c 45 6e 06 23 92 2f ab 73 ce 01 a0 cd dd ee ff`.
Encrypted-sequence number currently `0x2933d231`. Message: a history-fetch start sent through
endpoint `0x004B` as the third message on the connection (handle `0x03`); payload (10 bytes,
§6.2) `01 01 ea 07 09 1e 0c 00 00 08`. `OC-vec`

| Step | Bytes |
|---|---|
| message key = session key XOR `0x03` | `8f 46 6d 05 20 91 2c a8 70 cd 02 a3 ce de ed fc` |
| `P ‖ S` | `01 01 ea 07 09 1e 0c 00 00 08` `31 d2 33 29` |
| CRC-32 over those 14 bytes | `0x9530d05f` → LE `5f d0 30 95` |
| padded plaintext (10 + 4 + 4 = 18 → 32) | `01 01 ea 07 09 1e 0c 00 00 08 31 d2 33 29 5f d0 30 95` + 14 × `00` |
| AES-128-ECB(message key) | `f9 54 ea 42 20 6c b5 96 23 e5 3d c0 11 39 f3 ea e7 6b 3a b5 34 16 39 ae d3 4b de 6d 1c 3b 34 37` |
| next sequence number | `0x2933d232` |

Chunked at MTU 23 (total length field = **10**, the plaintext length):

```
chunk 0 (20 B): 03 09 00 03 00 | 0a 00 00 00 | 4b 00 | f9 54 ea 42 20 6c b5 96 23
chunk 1 (20 B): 03 08 00 03 01 | e5 3d c0 11 39 f3 ea e7 6b 3a b5 34 16 39 ae
chunk 2 (13 B): 03 0e 00 03 02 | d3 4b de 6d 1c 3b 34 37
```

At MTU 247: one 43-byte chunk, `03 0f 00 03 00 0a 00 00 00 4b 00` followed by the 32
ciphertext bytes.

---

## 4. Authentication

### 4.1 Inputs

- **Auth key**: 16 bytes minted by Zepp's cloud when the strap is paired in the Zepp app
  (see `HELIO_KEY_EXTRACTION.md`). Users see it as 32 hex digits, sometimes with a `0x`
  prefix. Accept exactly: optional `0x`/`0X`, then 32 hex digits, surrounding whitespace
  trimmed; reject anything else. 🟡 `AUTH:160-178` (Gadgetbridge also falls back to a default
  key and to raw ASCII bytes for older devices; **do not replicate that**. A wrong key must
  be a visible error.)
- **Curve**: NIST **B-163 = sect163r2** (binary field GF(2¹⁶³), reduction polynomial
  x¹⁶³ + x⁷ + x⁶ + x³ + 1, a = 1, cofactor 2). **Not** sect163k1. 🟡 The parameters in
  `ECDH:56-60` are identical to tiny-ECDH-c's `NIST_B163` set (`TE ecdh.c:100-108`), and
  `OC-vec` confirms them against an independent implementation (base point on curve, order ×
  G = ∞). HelioCore's comment calls it sect163k1 (`HC:1429`) but its constants are also
  B-163's (`HC:1436-1438`).
- **Port tiny-ECDH-c** (Unlicense) for the curve maths: CryptoKit has no binary curves. Keep
  its attribution header.

### 4.2 Wire representation of keys (tiny-ECDH-c layout)

| Item | Size | Layout | Source |
|---|---|---|---|
| private key | 24 bytes | a 192-bit little-endian integer (6 × u32 words, least-significant word first, each word LE) | 🟡 `ECDH:42,407-424`, `TE ecdh.h` |
| public key | 48 bytes | X (24 bytes) then Y (24 bytes), each a field element in the same LE layout. The top 29 bits of each 24-byte element are always zero. | 🟡 `ECDH:43,457-458` |
| shared secret | 48 bytes | the shared **point**, X then Y, same layout (not just X) | 🟡 `ECDH:464-500`, `AUTH:86` |

Private-key rules, as in tiny-ECDH-c (both references do the same): draw 24 random bytes; if
the highest set bit is below bit 81 (degree < 163/2), draw again; the effective scalar is the
value with **every bit from 162 upwards cleared** (in byte terms: byte 20 masked to its low 2
bits, bytes 21–23 zeroed). Apply the same clearing when computing the shared secret. 🟡
`ECDH:442-452,478-484`, `HC:1440-1452,1546`. Use `SecRandomCopyBytes`, not a
non-cryptographic RNG (Gadgetbridge uses `java.util.Random`, `AUTH:135`; don't copy that).

Reject a device public key that is the point at infinity or is not on the curve. 🟡
`ECDH:471-472`

### 4.3 Message sequence (endpoint `0x0082`, plaintext)

```
Phone                                                        Strap
  |  enable notify on …0017                                    |
  |--- [h=1] 04 02 00 02 ‖ phonePub(48) ---------------------->|   52 B  public-key message
  |<-- 10 04 01 ‖ random(16) ‖ strapPub(48) -------------------|   67 B
  |    shared = ECDH(phonePriv, strapPub)                      |
  |    encSeq = u32 LE of shared[0..3]                         |
  |    sessionKey[i] = shared[8+i] XOR authKey[i], i = 0..15   |
  |--- [h=2] 05 ‖ AES(authKey, random) ‖ AES(sessionKey, random) ->|  33 B  session message
  |<-- 10 05 <status> -----------------------------------------|
  |    status 01 = authenticated; 25 = wrong auth key          |
```

| Field | Detail | Tag / source |
|---|---|---|
| request `04 02 00 02` | command `04`; the three bytes `02 00 02` are fixed and unexplained | 🟡 `AUTH:141-146`, `HC:852` |
| reply byte `[0]` | `10` = "response" (any other value: ignore) | 🟡 `AUTH:67-70`, `HS:224` |
| reply byte `[1]` | echoes the command (`04` or `05`) | 🟡 `AUTH:72` |
| reply byte `[2]` | status: `01` success. On the `04` reply, anything else is a failure. On the `05` reply, `25` means **wrong auth key**; any other non-`01` value is an unspecified failure. | 🟡 `AUTH:74-77,112-119`, `HC:867,887-888` |
| `04` reply `[3..18]` | 16-byte device random | 🟡 `AUTH:84`, `HC:869` |
| `04` reply `[19..66]` | device public key, 48 bytes (§4.2) | 🟡 `AUTH:85`, `HC:870` |
| AES in `05` | **AES-128-ECB, no padding**, one 16-byte block each: first with the auth key, second with the **session key** | 🟡 `AUTH:98-104`, `CRY:45-50`, `HC:875-880` |

The success path of this sequence works on the Helio with the real key: the `04` exchange,
the `05` message built as above, and `10 05 01`. 🟢 `HW:2026-09-30 (hw 0.132.27.2)`. The wrong-key reply (`10 05 25`)
has not been tested yet (§10 item 3).

### 4.4 Deriving the session parameters

From the 48-byte shared secret `s` (§4.2 layout):

- **encrypted-sequence seed** = `s[0..3]` read as **u32 little-endian** (the low 32 bits of the
  shared point's X). 🟡 `AUTH:87`, `BLT:229-231`, `HC:872`
- **session key** = `s[8..23]` (16 bytes, the middle of X's encoding) XOR the auth key,
  byte for byte. 🟡 `AUTH:89-92`, `HC:873-874`. 🟢 `HW:2026-09-30 (hw 0.132.27.2)`: the strap's encrypted replies
  decrypt with it (§3.3). The strap also answered our encrypted requests, which carried the
  seed-derived sequence numbers; 🔴 whether it checks them.

Both are installed **as soon as the `04` reply is processed**, before the `05` message is
sent (the `05` message itself is plaintext). After `10 05 01`, every endpoint that the
services list marks as encrypted uses them (§3.3). 🟡 `AUTH:95`

On `10 05 25`, Gadgetbridge tells the user the key is wrong and disconnects (`AUTH:151-158`).
OpenCircuit should do the same and surface a "key rejected: re-extract it" state (the key is
invalidated by unpairing in Zepp or a hard reset, see `HELIO_KEY_EXTRACTION.md`).

### 4.5 Timing notes

HelioCore waits ~0.4 s after enabling notifications before sending the public key
(`HC:846`). 🔴 whether the delay is needed; waiting for the notify-enabled callback should
suffice.

### 4.6 Worked example C: full handshake (constructed, made-up keys)

Made-up inputs (**not** a real strap or a real key). `OC-vec`

| Input | Value |
|---|---|
| phone private key (as drawn) | `01 02 03 … 18` (bytes `0x01`…`0x18`) |
| phone effective scalar (bits ≥ 162 cleared) | `01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 01 00 00 00` |
| strap private key (simulated) | bytes `0x81`…`0x98`, effective `81 82 … 94 01 00 00 00` |
| auth key | `00 11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff` |
| strap random | `f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 fa fb fc fd fe ff` |

Outputs:

```
phonePub X = a1 e4 ad 02 c2 a4 4e a2 41 52 96 2c 14 0e a0 63 c6 9b 2e 5c 07 00 00 00
phonePub Y = cd 50 73 a0 6d 67 b7 8a 3b c5 f5 19 ab 85 fb 9c f5 85 5d c8 01 00 00 00
strapPub X = a3 31 15 77 49 a9 09 f0 67 ad 23 2a 5c 17 ab 6f 21 72 c3 0c 00 00 00 00
strapPub Y = f4 f5 5b 1a df fc 66 c5 f3 5f 29 c2 5f 89 da 07 73 fd 25 6a 05 00 00 00
shared   X = 31 d2 33 29 56 1a c3 f2 8c 54 4c 35 67 c7 49 dc fb 57 ab 1b 01 00 00 00
shared   Y = 06 e8 17 31 4f 23 79 8d ed fc f2 14 68 60 70 12 e1 9e c7 be 04 00 00 00
(shared is identical whichever side computes it)

encSeq seed      = 0x2933d231            (shared[0..3] = 31 d2 33 29, LE)
session key      = 8c 45 6e 06 23 92 2f ab 73 ce 01 a0 cd dd ee ff
AES(auth, rnd)   = e8 55 41 bb 23 2f 07 09 90 89 75 3d 86 c0 dd f0
AES(sess, rnd)   = e0 f4 c3 cc 1c 86 76 7b dd 16 70 a2 1d 60 d5 4f
```

Strap's `04` reply payload (67 bytes):
`10 04 01 f0 f1 … ff` then strapPub X, then strapPub Y.

Phone's `05` message (33 bytes, handle 2), as one chunk at MTU 247:
`03 07 00 02 00 21 00 00 00 82 00 05 e8 55 41 bb 23 2f 07 09 90 89 75 3d 86 c0 dd f0 e0 f4 c3 cc 1c 86 76 7b dd 16 70 a2 1d 60 d5 4f`.

These vectors are suitable as unit-test fixtures for the Swift port (they are ours, not
copied from any project).

---

## 5. Post-auth session setup

Gadgetbridge's order after `10 05 01` (🟡 `SUP:901-957`, `BTLE:191-195`):

1. request MTU 247 (iOS: nothing to do, the OS negotiates);
2. request the **services list** (§5.2);
3. on the reply: set the time (§5.1), request device info (§5.3), then initialise each
   supported service (battery request, config capabilities, user info, realtime-steps off…);
4. history fetch is started separately (by the user or a schedule).

HelioCore's minimal path skips 1–3 entirely: auth, then fetch over `…0004`/`…0005` with
plaintext writes, and it works on a Helio (🟡 `HC:886-892,902-930`). **Recommended v1
order**: auth → services list → time set → battery → read HEALTH config (§5.5) → fetch. Time
set matters most: once the Zepp app is gone, **nothing else sets the strap's clock**, and
every history timestamp is in the strap's clock (§6.4).

### 5.1 Time (endpoint `0x0047`, plaintext by default)

Use it if the services list contains `0x0047`, otherwise write the same 11 time bytes to
the standard Current Time characteristic `0x2A2B`. 🟡 `SUP:934-940`, `BTLE:180-183`

**Set time** = `05` followed by 11 bytes (12 bytes total): 🟡 `SVC/Time:80-89`,
`GB/service/devices/huami/HuamiUtils.java:152-182`

| Offset (after `05`) | Size | Meaning |
|---|---|---|
| 0 | u16 LE | year |
| 2 | u8 | month 1–12 |
| 3 | u8 | day of month |
| 4 | u8 | hour 0–23 (local) |
| 5 | u8 | minute |
| 6 | u8 | second |
| 7 | u8 | day of week, **Sunday = 0 … Saturday = 6** (not the GATT convention) |
| 8 | u8 | fraction of second in 1/256 |
| 9 | u8 | `08` if daylight-saving time is currently in effect, else `00` |
| 10 | i8 | current UTC offset **including DST**, in quarter-hours (UTC+2 → `08`, UTC−5 → `ec`) |

Reply: `06 <status>` (status `01` observed). The device rejects the 10-byte GATT form with
"out of range". 🟡 `SVC/Time:64-66`, `HuamiUtils.java:153-157`

**Next DST transition** = `07`, then u32 LE Unix seconds of the next transition, then
**i16** LE the offset change in seconds (e.g. `+3600` spring forward, `−3600` fall back).
Skip it if the zone has no future transition. Reply `08 <status>`. 🟡 `SVC/Time:91-114`

Example (constructed): 2026-09-30 12:34:56.000, a Wednesday, Europe/Madrid (UTC+2, DST on)
→ `05 ea 07 09 1e 0c 22 38 03 00 08 08`.

### 5.2 Services list (endpoint `0x0000`, plaintext)

Request `03`. Reply: `04`, u16 LE count, then count × (u16 LE endpoint, u8 encrypted flag
`00`/`01`; other flag values = leave the default). 🟡 `SVC/Services:58-90`. Use it to
(a) know which endpoints exist (e.g. whether `0x004B` and `0x0047` are available), and
(b) override each endpoint's encryption flag from §3.5. 🟢 `HW:2026-09-30 (hw 0.132.27.2)`: request, reply layout
and flags as described; the Helio's list is in §3.5.

### 5.3 Device info and battery

- **Device info** (endpoint `0x0043`, plaintext): request `01`. Reply `02 01`, then u64 LE
  flags, then fields present by flag bit: bit0 = a length-prefixed blob (skip), bit1 =
  serial number (NUL-terminated UTF-8), bit2 = hardware version (NUL-terminated), bit3 =
  firmware version (NUL-terminated), bit4 = 7-byte PnP ID. If the services list lacks
  `0x0043`, read DIS `0x180A`. 🟡 `SVC/DeviceInfo:77-141`. The serial number is a personal
  identifier: never log it or commit it. 🔴 **the width of bit 0's length prefix is not given**,
  and the Helio's flags set bit 0 (§1), so the fields after it can't be located with certainty.
  The Helio lists `0x0043` but has no DIS firmware revision (§10.1), so this endpoint is the only
  BLE route to its firmware version. On the Helio it reported firmware **3.25.0.3** 🟢
  `HW:2026-09-30 13:35`; which prefix width parsed is not recorded in §10.1, so the 🔴 on the
  width stands.
- **Battery** (endpoint `0x0029`, encrypted by default): request `03`. Reply `04` + 20 bytes
  (21 total). Payload byte `[2]` = level in %, byte `[3]` = `00` not charging / `01`
  charging; bytes `[11..18]` hold a last-charge date (u16 year, month, day, h, m, s, i8
  quarter-hour offset) and `[20]` the last charge level. 🟡 `SVC/Battery:47-70`, `GB/service/devices/huami/HuamiBatteryInfo.java:60-103`
  (offsets given here relative to the full reply, i.e. Gadgetbridge's offsets + 1).

### 5.4 User info (endpoint `0x0017`, encrypted by default), optional

Gadgetbridge sends it on every connect if the user profile is complete. 🟡
`SVC/UserInfo:93-146`. Probably feeds on-device calorie/PAI maths; 🔴 whether the strap
records anything differently without it. Layout:

`01` · `4f 07 00 00` (fixed) · u16 LE birth year · u8 month · u8 day · u8 gender (`00` male,
`01` female, `02` other) · u16 LE height cm · u16 LE weight in **kg × 200** · u64 LE user id
(any stable number) · region as UTF-8 then `00` · `09` (fixed, unexplained) · display name as
UTF-8 then `00`. Reply `02 <status>`.

### 5.5 Settings that decide what is RECORDED (config endpoint `0x000A`, encrypted by default)

The strap only records a metric if its monitoring setting is on. The Zepp app sets them;
**read them after auth** and warn the user when one is off, rather than silently fetching
nothing. Not every HEALTH switch is a recording switch: `0x04` does not gate recording (🟢
`HW:2026-09-30 13:35`, §10.1); per the vendor it raises the sampling rate during activity (🟡, the
vendor's switch description, not measured; table below).

**Commands** 🟡 `SVC/Config:104-111,283-388,938-960`

| Command | Bytes |
|---|---|
| capabilities | send `01` → reply `02`, u8 service version (≤ 3 understood), u8 group count, group ids… |
| read | send `03`, u8 include-constraints (`01`/`00`), u8 group, u8 arg count, arg codes… (arg count `00` asks for all args, 🔴) |
| read reply | `04`, u8 status (`01` ok), u8 group, u8 group version, u8 includes-constraints, u8 entry count, then entries |
| write | send `05`, u8 group, u8 group version, `00`, u8 entry count, then entries (value only, no constraints). **One message per group.** |
| write ack | `06`, u8 status |

**Entry** = u8 arg code, u8 type, value. Value encodings (LE throughout): 🟡
`SVC/Config:432-444`, `GB/service/devices/huami/zeppos/services/config/*.java`

| Type | Code | Value | Extra bytes when constraints are included |
|---|---|---|---|
| bool | `0x0b` | 1 byte, `00`/`01` (anything else: stop parsing) | none |
| byte | `0x10` | 1 byte | u8 n, then n allowed values |
| byte list | `0x11` | u8 n, n bytes | u8 m, then m allowed values |
| short | `0x01` | i16 | i16 min, i16 max |
| short list | `0x02` | u8 n, n × i16 | u8 min count, u8 max count, i16 min, i16 max |
| int | `0x03` | i32 | i32 min, i32 max |
| string | `0x20` | UTF-8 up to `00` | u8 max length |
| string list | `0x21` | UTF-8 up to `00` | u8 max length, u8 n, n NUL-terminated strings |
| hh:mm | `0x30` | u8 hour, u8 minute | none |
| timestamp | `0x40` | i64 ms | none |
| int (unbounded) | `0x50` | i32 | none |

An unknown type code makes the rest of the reply unparseable (no length field): keep what
was parsed and stop. 🟡 `SVC/Config:1025-1032`

**HEALTH group = `0x08`** (Gadgetbridge understands versions 1–3 and writes version `03`).
🟡 `SVC/Config:399,516-539`

On the Helio, capabilities reply with service version **3** and groups `00 0b 08 09 0a`, and
the HEALTH group `0x08` reads back as group version **3**. 🟢 `HW:2026-09-30 (hw 0.132.27.2)` (read only; nothing was
written).

| Arg | Type | Meaning | Relevant fetch type(s) |
|---|---|---|---|
| `0x01` | byte | all-day HR monitoring: `00` off, `ff` "smart"/auto, `N` = every N minutes (Gadgetbridge caps at 120) | activity HR, resting/max HR, HRV 🔴 | 
| `0x04` | bool | the vendor's **"Active heart rate monitoring"** switch: it only raises the HR sampling rate during detected activity. It does **not** gate recording: it read `false` in a complete (non-partial) config read, and every one of the 720 minutes of the same session's 12 h activity fetch carried a heart rate. Read it for information; never warn about it. | none: 🟢 does not gate recording `HW:2026-09-30 13:35` (§10.1); the sampling-boost meaning is the vendor's switch description, not measured 🟡 |
| `0x05` | bool | share HR with third parties. 🔴 Probably the Zepp app's **"Heart Rate Push"** switch (Zepp › Device › Helio Strap › Health Monitoring), which the strap needs for standard-HR broadcast (§7) | live HR |
| `0x11` | bool | high-accuracy sleep monitoring (uses HR for sleep; needed for REM staging 🔴) | sleep session |
| `0x12` | bool | sleep breathing-quality monitoring. Gadgetbridge notes it is required for **sleep SpO₂** (`FOP/Spo2Sleep:31-33`); 🔴 likely also for sleep respiratory rate | `0x26`, `0x38` 🔴 |
| `0x13` | bool | stress monitoring | `0x13` 🟡 |
| `0x31` | bool | all-day SpO₂ monitoring | automatic `0x25` 🟡 |
| `0x02` / `0x03` / `0x32` | byte | high-HR / low-HR / low-SpO₂ alert thresholds | — |

HR-interval encoding 🟡 `SVC/Config:1508-1523`. Gadgetbridge v0.90 reportedly **hides** the
HR-interval setting for the Helio Strap because its HR is always on (third-hand, from its
release notes; 🔴). **Temperature** has no known switch in any reference: 🔴 assume it is
always recorded.

Example (constructed): enable stress monitoring → payload `05 08 03 00 01 13 0b 01`.

---

## 6. History fetch

### 6.1 Channels

| Role | Path A (legacy characteristic) | Path B (chunked endpoint) |
|---|---|---|
| control out (phone → strap) | write to `…0004` (plaintext) | message on endpoint `0x004B` (encrypted per services list) |
| control in (strap → phone) | notification on `…0004` | message on endpoint `0x004B` |
| data | notifications on `…0005` (plaintext) | **same**: notifications on `…0005` |

Gadgetbridge uses Path B whenever the services list includes `0x004B`, else Path A
(`SUP:968-976`, `SVC/ActivityFetch:44-52`). HelioCore uses Path A on the Helio and it works
(`HC:902-946`). Control messages have **identical bytes** on both paths. 🟡. Recommendation:
Path A first (simplest, proven on the Helio); Path B only if Path A is refused. 🟢 `HW:2026-09-30 (hw 0.132.27.2)`:
Path A (plaintext writes to `…0004`) carried every fetch of §10.1, even though the Helio also
lists `0x004B` (plaintext there, §3.5). Path B is untested.

Notifications: enable `…0004` before the first command; enable `…0005` before sending the
"fetch data" command; Gadgetbridge disables both when the whole batch is done
(`GB/service/devices/huami/HuamiFetcher.java:170-202`, `FETCH:219`). 🟡

### 6.2 One fetch round

```
Phone                                                          Strap
  |-- 01 <type> <since: 8 bytes> ------------------------------>|  10 B  "start"
  |<- 10 01 01 <len u32> <start: 8 bytes> [00] ----------------|  16 B on the Helio (15 B elsewhere)
  |   if len == 0: skip to ACK (keep), whatever <start> holds    |
  |-- 02 ------------------------------------------------------>|  "fetch data"
  |<- …0005: <ctr> <data…>   (repeated)                         |
  |<- 10 02 01 [crc32 u32]   (3 or 7 bytes) -------------------|  "transfer done"
  |-- 03 <ack mode> ------------------------------------------->|  "ack"
  |<- 10 03 …   ----------------------------------------------|  round finished
```

| Message | Layout | Tag / source |
|---|---|---|
| **start** | `01`, u8 fetch type (§6.5), then the 8-byte **since** timestamp: u16 LE year, month, day, hour, minute (local), u8 second, i8 UTC offset **including DST** in quarter-hours. Gadgetbridge sends second = `00` by default (minute precision; seconds broke the GTR 3). | 🟢 `HW:2026-09-30 (hw 0.132.27.2)` (second `00`); 🟡 `FETCH:145-151`, `SUP:679-688`, `BLT:121-134,380-387`, `GB/service/devices/huami/HuamiFetcher.java:150-156`, `HC:926-928,1258-1266` |
| **start reply** | `10 01 <status>`; status `01` = ok, else the type is unsupported/refused: skip it. Then u32 LE **expected length**, then the 8-byte **start** timestamp of the first record, same format as *since*. Gadgetbridge accepts 15 or 16 bytes (a 16th byte, `00`, was seen on another Zepp OS band); **the Helio sent the 16-byte form** (trailing `00`) every time. **The length's unit depends on the type**: 8-byte **records** for activity, **bytes** for every other type seen on hardware (§6.5 "Length unit"). Either way it excludes the per-packet counter bytes. | 🟢 `HW:2026-09-30 (hw 0.132.27.2)` (16 B, the per-type unit); 🟡 `FETCH:153-221` |
| **empty start reply** | status `01` with **length 0** means the strap has nothing for this type since *since*, **whatever the start timestamp holds**: don't validate it. Two forms seen: a far-future **sentinel** start (e.g. `3a 08 02 06 02 1c 10 f0` = 2106-02-06 02:28:16 at UTC−4, which is 2³² − 86 400 Unix seconds) for a type with nothing in the window, and an **all-zero** start (8 × `00`, not a valid date) on the follow-up round straight after a round that delivered data. Both are then acked like any empty round. | 🟢 `HW:2026-09-30 (hw 0.132.27.2)` (both forms; 🔴 what the sentinel's value means) |
| **fetch data** | the single byte `02` | 🟢 `HW:2026-09-30 (hw 0.132.27.2)`; 🟡 `FETCH:220`, `HC:944` |
| **data packet** | on `…0005`: byte `[0]` = u8 **packet counter** starting at `00` for each round and incrementing by 1 (wrapping); the rest is data. Concatenate the data parts. A packet can be much longer than 20 bytes (a 241-byte packet was seen at the Mac's MTU). | 🟢 `HW:2026-09-30 (hw 0.132.27.2)`; 🟡 `FETCH:123-143`, `HC:955-965` |
| **transfer done** | `10 02 <status>`; status `01` = ok. 7-byte form carries u32 LE **CRC-32** (same CRC as §3.3) of the concatenated data parts, counters excluded. | 🟢 `HW:2026-09-30 (hw 0.132.27.2)`: 7-byte form, and the CRC matched for every type; activity's too 🟢 `HW:2026-09-30 13:35` (60 records / 480 B and 720 records / 5760 B, §10.1); 🟡 `FETCH:223-246` |
| **ack** | `03`, then ack mode (§6.3) | 🟢 `HW:2026-09-30 (hw 0.132.27.2)` (`03 09` only); 🟡 `FETCH:260-277` |
| **ack reply** | `10 03 …`; Gadgetbridge treats it as "round finished" and only then starts the next round/type | 🟢 `HW:2026-09-30 (hw 0.132.27.2)` (`10 03 01` after every ack, including empty rounds); 🟡 `FETCH:173-176` |

Worked example D (constructed, made-up readings): fetch HRV since 2026-09-29 00:00 in UTC+2.
`OC-vec`

```
→ 01 49 ea 07 09 1d 00 00 00 08
← 10 01 01 0c 00 00 00 ea 07 09 1d 00 05 00 08      len = 12, first record 00:05:00 (+02:00)
→ 02
← […0005] 00 8c e4 ba 6a 08 2a b8 e5 ba 6a 08 39   counter 00; two 6-byte HRV records
← 10 02 01 39 62 bb d7                               CRC-32 of the 12 data bytes = 0xd7bb6239
→ 03 09                                              ack, keep on strap
← 10 03 01                                           (status byte 🔴: only "10 03" is checked)
```

The two records decode (§6.5) to 42 ms at 1790633100 (2026-09-28T22:05:00Z) and 57 ms at
1790633400 (22:10:00Z).

**Trace T1** (a hardware trace, not a constructed example; control bytes and lengths only, `HW:2026-09-30 (hw 0.132.27.2)`): a 30-minute activity
window at UTC−4. The length field counts **records**: 30 minutes × 8 bytes = 240 data bytes.

```
→ 01 01 ea 07 09 1e 0b 37 00 f0                     since 2026-09-30 11:55 (−04:00)
← 10 01 01 1e 00 00 00 ea 07 09 1e 0b 37 00 f0 00   length 30 (records); start = since; 16 B
→ 02
← […0005] 00 + 240 data bytes                        one 241-byte packet
→ 03 09                                              ZeppKit before the fix: "overflow", acked at once
← 10 02 01 <crc32>                                   transfer done, 7-byte form, after our ack
← 10 03 01
```

A correct phone waits for the transfer done, checks 240 = 30 × 8 bytes and the CRC, then
acks. A 12-hour activity window announced `720` (720 minutes, so 5760 data bytes are
expected; that round was also aborted early, at 960 bytes). In the re-test all 720 records
(5760 B) arrived and the CRC matched 🟢 `HW:2026-09-30 13:35`.

### 6.3 Ack: keep vs delete (critical)

| Ack mode byte | Meaning | Tag / source |
|---|---|---|
| `01` | "saved on the phone": the strap marks the data as synced and **stops offering it**; Gadgetbridge notes the detailed data then appears to be discarded and is never re-sent | 🟡 `FETCH:266-270` |
| `09` | acknowledged **but kept** marked as unsynced on the strap (non-destructive) | 🟡 `FETCH:266-270`, `HC:969,986` |

Gadgetbridge's rules on Zepp OS (🟡 `FETCH:204-209,236-258`):

- expected length 0 → send `03 09` and wait for the ack reply;
- CRC present and wrong → send `03 09` (keep);
- processing failed, or packet-counter gap (the round is marked invalid) → `03 09`;
- otherwise `03 01`, unless the user chose "keep data on device" → `03 09`.

**OpenCircuit rule**: send `03 09` during development (so Zepp/Gadgetbridge can pull the same
window for side-by-side validation) and, in production, send `03 01` **only after the parsed
round is durably committed** to the local store (mirroring `HistoryCommitGate`), and **only for
a round whose transfer done carried a CRC that matched** (the 7-byte form). A 3-byte transfer
done has no integrity check, so that round is kept (`03 09`); the Helio always sent the 7-byte
form (§10.1). Any failure path → `03 09`.

Unknowns (🔴, §10): whether `01` frees strap storage immediately; how long the strap retains
unsynced data when only `09` is ever sent (it may eventually overwrite the oldest).

Answered on the Helio (🟢 `HW:2026-09-30 (hw 0.132.27.2)`):

- A later fetch whose *since* overlaps data already acked with `09` **re-delivers** it
  (temperature).
- A `03 09` sent **mid-transfer** (before the strap's transfer done) is tolerated: the strap
  still sent its transfer done and `10 03 01`, and the next type fetched normally. The phone
  must therefore ignore a late `10 02` after it has acked.

### 6.4 Rounds, cursors and timestamps

- The strap returns at most a limited window per round. After processing a round, set the
  next *since* to the **last record's time + 1 minute** and start another round of the same
  type while: the round advanced by ≥ 1 s, fewer than ~11 rounds have run, and the new
  *since* is not in the future. 🟡 `REPEAT:64-114`. HelioCore does the same with ≤ 20 rounds
  (`HC:973-981`).
- First-ever cursor: Gadgetbridge starts 100 days back (`FETCH:293-303`). Keep one cursor
  **per fetch type**.
- **Per-minute types** (activity, stress-auto, temperature) carry no timestamps: record *i*
  is at `start + i minutes`, where *start* comes from the start reply. On the Helio, their
  *start* equalled the requested *since*; for event types it was the first record's own time.
  🟢 `HW:2026-09-30 (hw 0.132.27.2)`. Interpret the start
  reply's local fields **with its own quarter-hour offset byte**: absolute instant = local
  fields − offset × 15 min. 🟡 `BLT:161-184`, `FOP/Activity:112-121`. (HelioCore ignores the
  offset byte and uses the phone's zone, `HC:1268-1285`. Wrong whenever the strap's zone
  differs from the phone's, e.g. after travel or a DST change before a time set.)
- **Records with their own timestamp** use a u32 LE **Unix epoch seconds (UTC)** value, often
  followed by an i8 UTC offset in quarter-hours for local display. 🟡 (per type below)

### 6.5 Fetch types

"GB maps to" is where Gadgetbridge stores the value. "Helio" says whether Gadgetbridge
schedules the fetch for the Helio Strap: it queues a type when the coordinator reports
support, and the strap inherits all Zepp OS defaults except display-dependent ones
(`GB/service/devices/huami/HuamiFetcher.java:54-112`,
`GB/devices/huami/zeppos/ZeppOsCoordinator.java:173-249,611-617`).

| Code | Name | Record layout (LE) | Rate / timestamps | Units / scaling | GB maps to | Helio in GB | Tag / source |
|---|---|---|---|---|---|---|---|
| `0x01` | **activity** | **8 bytes/min** on Zepp OS: `[0]` kind, `[1]` intensity, `[2]` steps, `[3]` HR, `[4]` unknown, `[5]` sleep, `[6]` deep-sleep, `[7]` REM (sleep bytes: use low 7 bits) | 1/min from *start* | steps = count in that minute; HR bpm, `ff` or `00` = no reading (HelioCore drops them; GB stores raw); intensity 0–255 (GB divides by 256). CRC is **not** checked by GB for this type; on the Helio it **matches** like every type that has delivered data (60 records / 480 B, and a full 12 h round of 720 records / 5760 B); manual HR `0x02`, manual stress `0x12` and max HR `0x3d` have only answered empty, so their CRC has never been observed. | per-minute activity sample | yes (always) | 🟢 8 bytes/min, length in records `HW:2026-09-30 (hw 0.132.27.2)`; 🟢 CRC `HW:2026-09-30 13:35`; fields 🟡 `FOP/Activity:71-164`, `SUP:984-986`, `HC:1180-1193` |
| `0x02` | manual HR | 6 bytes: u32 ts, i8 tz (¼ h), u8 bpm | event | bpm | manual-HR sample | yes | 🟡 `FOP/HeartRateManual:63-90` (only empty replies on the Helio so far) |
| `0x0d` | PAI | 102 bytes: u8 type (`05` valid, `00` pre-reset: skip), u32 ts, i8 tz, 31 unknown, f32 PAI low, f32 moderate, f32 high, u16 min low, u16 min moderate, u16 min high, f32 PAI today, f32 PAI total, 39 unknown. **We store** the f32 PAI **total** of each kept record as one phone-only `MetricKind.pai` row at the record's own time (`ZeppMetricMapping.paiSamples`, decision 45); the app's PAI tile shows the newest (decision 49). Never written to Apple Health (no PAI type) | daily | PAI points, minutes | PAI sample | yes | 🟢 102-byte record, CRC `HW:2026-09-30 (hw 0.132.27.2)`; fields 🟡 `FOP/Pai:62-129` |
| `0x12` | stress (manual) | 5 bytes: u32 ts, u8 stress | event | 0–100 | stress, type manual | yes | 🟡 `FOP/StressManual:64-95` (only empty replies on the Helio so far) |
| `0x13` | **stress (auto)** | 1 byte/min, `ff` = none (the minute still advances) | 1/min from *start* | 0–100; bands 0–39 relaxed, 40–59 mild, 60–79 moderate, 80–100 high | stress, type automatic | yes | 🟢 1 byte/min, CRC `HW:2026-09-30 (hw 0.132.27.2)`; fields 🟡 `FOP/StressAuto:62-91`, `HC:1195-1199` |
| `0x25` | **SpO₂** (normal: manual + auto) | one leading **version byte `02`** per round, then 65-byte records: u32 ts, u8 value (**bit 7 set = automatic**, value = low 7 bits), 60 unknown bytes. Other versions: reject. | event | % | SpO₂ sample, type auto/manual | yes | 🟢 version `02` + 65-byte records, CRC `HW:2026-09-30 (hw 0.132.27.2)`; fields 🟡 `FOP/Spo2Normal:64-103`, `HC:1201-1212` |
| `0x26` | SpO₂ (sleep) | version byte `02`, then 30-byte records: u32 ts, u8 SpO₂, u8 duration, 6 bytes "high", 6 bytes "low", 8 bytes signal quality, 4 bytes "extend" | per sleep | %; GB notes it often differs by ~1 from `0x25` | **not stored** | **not scheduled** | 🟢 version `02` + 30-byte records, CRC `HW:2026-09-30 (hw 0.132.27.2)`; 🔴 **field layout**: on the Helio every record decoded to the same SpO₂ value, which is implausible (out of v1 scope; parser unchanged). `FOP/Spo2Sleep:48-93` (no queue entry in `HuamiFetcher.java`) |
| `0x2e` | **temperature** | 8 bytes/min: i16 unknown (`0x7fff` observed), **i16 temperature**, i16 unknown, i16 unknown (`0x5a5a` observed in both) | 1/min from *start* | **centi-°C** (÷100), skin at the wrist/arm | skin temperature | yes (no display) | 🟢 8 bytes/min, CRC `HW:2026-09-30 (hw 0.132.27.2)`; fields 🟡 `FOP/Temperature:61-96`, `HC:1168-1178` |
| `0x38` | **sleep respiratory rate** | 8 bytes: u32 ts, i8 tz, u8 rate, u8 unknown (`00`), u8 unknown (`01`, sometimes `02`/`04` near waking) | during sleep | breaths/min | resp-rate sample | yes | 🟢 8-byte records, CRC `HW:2026-09-30 (hw 0.132.27.2)`; fields 🟡 `FOP/SleepRespiratoryRate:62-90`, `HC:1225-1233` |
| `0x3a` | **resting HR** | 6 bytes: u32 ts, i8 tz, u8 bpm | ~daily (Zepp shows it per day) | bpm | resting-HR sample | yes | 🟢 6-byte record, CRC `HW:2026-09-30 (hw 0.132.27.2)`; fields 🟡 `FOP/HeartRateResting:63-91`, `HC:1214-1222` |
| `0x3d` | **max HR** | 6 bytes: u32 ts, i8 tz, u8 bpm | ~daily 🔴 | bpm | max-HR sample | yes | 🟡 `FOP/HeartRateMax:63-90` (only empty replies on the Helio so far) |
| `0x48` | **sleep session** | **594-byte** records, see §6.6 | per night | minutes | sleep-session blob; stages overlaid on activity | yes | 🟢 594-byte record, CRC `HW:2026-09-30 (hw 0.132.27.2)`; fields 🟡 `FOP/SleepSession:59-85` |
| `0x49` | **HRV** | 6 bytes: u32 ts, u8 unknown (🔴 probably the tz byte, as in the 6-byte HR records), u8 HRV | a few per day/night 🔴 | **ms**; statistic **RMSSD** 🟡: Amazfit documents that "Amazfit devices measure HRV using the RMSSD method" (https://us.amazfit.com/pages/amazfit-technology-page-health-technology; a product-line statement, the Helio Strap is not named), and a third-party Helio review says the same. Not compared with Zepp's display on our strap (§10 item 9); a capture that contradicts it wins | HRV value | yes (no display) | 🟢 6-byte records, CRC `HW:2026-09-30 (hw 0.132.27.2)`; fields 🟡 `FOP/Hrv:59-85`, `HC:1236-1245`; statistic 🟡 Amazfit product-line documentation (2026-10-01) |
| `0x2c` | statistics | opaque files; fetched only so the strap frees memory | — | — | discarded | yes | 🟡 `FOP/Statistics` |
| `0x05` / `0x06` | workout summary / detail | binary summary + track; **out of scope for v1**, not specified here | per workout | — | workouts | yes | 🟡 `FOP/SportsSummary`, `FOP/SportsDetails` |
| `0x07` | debug logs | — | — | — | — | no | 🟡 `GB/…/fetch/HuamiFetchDataType.java:24` |

**Length unit of the start reply** (§6.2). The announced length counts **8-byte records
(minutes) for activity** and **bytes for every other type seen on hardware**: temperature
(`0x2e`), stress-auto (`0x13`, 1 byte per minute, so the two units coincide there), HRV
(`0x49`), SpO₂ (`0x25`), resting HR (`0x3a`), sleep respiratory rate (`0x38`), sleep session
(`0x48`), PAI (`0x0d`) and sleep SpO₂ (`0x26`). 🟢 `HW:2026-09-30 (hw 0.132.27.2)`. Manual HR (`0x02`), manual stress
(`0x12`) and max HR (`0x3d`) have only answered "empty" so far: **bytes 🟡**. Activity proved
that the unit can differ by type, so confirm each of these the first time it delivers data.
Convert to bytes before the checks below: expected data bytes = length × 8 for activity,
= length otherwise. Then an overflow, a length mismatch at transfer done, or a CRC mismatch
rejects the round (ack `09`).

Length rules to enforce before parsing (a violation = reject the round, ack `09`), in bytes:
activity multiple of 8; stress-auto any; manual/max/resting HR and HRV multiple of 6; temperature
and resp-rate multiple of 8; SpO₂ (length − 1) multiple of 65; sleep SpO₂ (length − 1)
multiple of 30; sleep session multiple of 594; PAI multiple of 102; manual stress multiple
of 5. 🟡 (the per-type sources above)

**Activity `kind` byte** (Zepp OS table, 🟡 `GB/devices/huami/HuamiExtendedSampleProvider.java:35-42,151-170`):
`0x40` (64) outdoor running · `0x73` (115) not worn · `0x76` (118) charging · `0x78` (120)
sleep. All other values are unmapped in Gadgetbridge and shown as generic activity; only
"walking" is named for the Helio (issue #5843, 2026-03-06). 🔴 full table.

**Sleep staging without a session record**: when no `0x48` session covers a minute,
Gadgetbridge falls back to thresholds on the activity record's REM/deep bytes (REM if REM > 55,
else deep if deep > 42, else light), which it calls arbitrary (`HuamiExtendedSampleProvider.java:127-147`).
🔴 Prefer the session record; otherwise feed per-minute HR/motion into OpenCircuit's own
`SleepStaging`.

**A later sleep with no session record** (🟡, one night, owner's strap, fw 3.25.0.3, decision 73):
after a long mid-night awakening, the strap sent no second `0x48` record for the sleep that
followed. Its sync delivered one record per night, and the later sleep was present only as `0x01`
minutes of kind `0x78` after the night's record had ended. So a record can stop at the first wake
and leave the rest of the night to the activity minutes. Synthetic shape: record 23:00–02:00,
kind-`0x78` minutes 05:30–07:00, nothing else. OpenCircuit v1 uses those minutes only to complete a
night that has a record (`HelioSleepSelection.activityBlocks` and `nights(sessions:activityBlocks:)`,
ZeppKit): a run of kind-sleep minutes outside every staged session's in-bed span, 5 or fewer
non-sleep minutes inside it kept as an awake gap, 20 min or longer and ended at least 20 min before
the sync's newest activity minute, becomes a sleep of generic stage (no REM/deep bytes read, no
`SleepStaging`) that joins its night by the stitch rules of §21.6, only after the in-bed end of the night's last
record and never at the cost of the night. One that would stand alone is not
stored. 🔴 whether the strap ever writes a second record for one night, and whether the activity
REM/deep bytes stage these minutes usefully.

### 6.6 Sleep session record (`0x48`), 594 bytes

🟡 `GB/devices/huami/HuamiSleepSessionSampleProvider.java:70-195`

| Offset | Type | Meaning |
|---|---|---|
| `0x000` | u32 | session timestamp (Unix s) |
| `0x004` | u32 | "midnight" reference: local midnight (as Unix s) of the day the session belongs to |
| `0x008`, `0x009` | u8, u8 | both `01` in observed data, unexplained |
| `0x00A` | u16 | sleep start, minutes |
| `0x00C` | u16 | sleep end, minutes |
| `0x015` | u8 | average HR during sleep, bpm |
| `0x016` | u8 | sleep score |
| `0x054` | u8 | number of stages *n* (0 = no staging; skip the record) |
| `0x056` + 5·*i* | u16, u16, u8 | stage *i*: start minute, end minute, stage type |
| `0x24A` | u16 | total REM, minutes |
| `0x24C` | u16 | total light, minutes |
| `0x24E` | u16 | total deep, minutes |
| `0x250` | u16 | total awake, minutes |

**Minute fields** are minutes counted from `midnight − 24 h` (the previous local midnight):
absolute = `midnight − 86400 + minutes × 60`. The source comments call the base "noon of
the previous day", but the arithmetic uses midnight − 24 h; 🔴 until a capture decides.
**Stage types**: `04` light · `05` deep · `07` awake · `08` REM · anything else = generic
sleep. The stage table fits at most 100 entries before `0x24A` (🔴 inference). Gadgetbridge
uses each stage's start and the session end, ignoring stage end fields (🟡); OpenCircuit
should use both and flag gaps.

**Stage end minutes are inclusive, and the record's span is the stages' span.** 🟡 One fetched
record (owner's strap, fw 3.25.0.3, HelioVerify, CRC ok; decisions 70 and 70e, #311 and #312):
- the first stage starts at the record's sleep start (`0x00A`);
- every next stage starts at the previous stage's end minute + 1, and the last stage's end
  minute + 1 is the record's sleep end (`0x00C`). So a stage covers its end minute: its span
  ends at **end minute + 1 minute**;
- the per-stage minutes counted that way equal the record's four totals (`0x24A`–`0x250`)
  exactly, and the four totals sum to sleep start → sleep end. Read as exclusive, every total
  comes up short by its stage count and a 1-minute gap opens between consecutive stages (about
  5% of that night).

Synthetic example (not from the record): sleep start 1380 (23:00), sleep end 1860 (07:00);
stages `1380–1499` light, `1500–1559` deep, `1560–1619` REM, `1620–1859` light. Spans:
23:00–01:00, 01:00–02:00, 02:00–03:00, 03:00–07:00, with no gaps; totals REM 60, light 360,
deep 60, awake 0, summing to 480 = 1860 − 1380.

OpenCircuit: `ZeppSleepSession.Stage.segmentEnd` (end minute + 1 minute) is the one place
ZeppKit turns a stage end into a span end. The overlap trim stays, so a record that already
ends a stage at the next start can't produce an overlap. The record shows no lead-in (sleep
start = first stage start), so the record's span is the in-bed envelope: a session's In Bed span
is the union of its stage span and its record span when the record span is valid (it starts
before it ends, overlaps the stage span, and the union is at most 20 h), else the stage span
(`HelioSleepSelection.inBedSpan`). The record itself carries no lead-in. Promote to 🟢 after
more nights show the same shape.

The app adds one (decision 77, #328; §21.6): an in-bed lead-in before a night's first in-bed start,
estimated from the strap's own STORED heart rate and steps. It is OpenCircuit's estimate, not part
of the record or of the record's span, and nothing above describes it.

---

## 7. Live data

### 7.1 Standard heart rate (`0x180D` / `0x2A37`)

- **With auth** (Gadgetbridge's path): enable notify on `0x2A37`, then send `04 01` (start) on
  endpoint `0x001D`, then `04 02` ("continue") **every second** to keep it running; `04 00`
  stops it. Reply `05 <status>` (`00` observed as success). 🟡 `SVC/HeartRate:36-47,112-183`.
  🟢 `HW:2026-09-30 (hw 0.132.27.2)`: after auth, this start plus the 1 s `04 02` gave **one `0x2A37` notification per
  second**. (The `05` reply's status was not recorded.)
- The same endpoint pushes **sleep events**: `06 01` fell asleep, `06 00` woke up. 🟡
  `SVC/HeartRate:74-88` (useful as a sleep-window hint).
- **Without auth (Tier 0)**: Amazfit documents a **"Heart Rate Push"** switch (Zepp › Device ›
  Amazfit Helio Strap › Health Monitoring) that makes the strap serve HR to third-party
  devices over "the standard Bluetooth protocol" (support.amazfit.com, "How to set the heart
  rate push function?", © 2025, fetched 2026-09-30). HelioCore finds `0x2A37` and has a parser for it but never enables notifications on it
  (`HC:618,1105,1125`), so it is no evidence either way. 🔴 whether an
  **unauthenticated** central gets `0x2A37` notifications with Heart Rate Push on (§10).
- Parse `0x2A37` per the Bluetooth HRS spec: flags bit0 → u8/u16 HR; bit3 energy expended
  present; bit4 RR intervals present (u16, 1/1024 s). Gadgetbridge only accepts the
  2-byte u8 form (`SVC/HeartRate:158-167`); HelioCore only the u8 form (`HC:1247-1252`).
  🔴 whether the Helio ever sends RR intervals.

### 7.2 Realtime steps (endpoint `0x0016`)

`05 01`/`05 00` enable/disable (ack `06 <status> <enabled>`); notifications `07` + 13 bytes,
steps = u16 LE at offset 1 of those 13. Gadgetbridge turns it **off** on connect because the
setting persists across connections. 🟡 `SVC/Steps:36-110`. Not needed for v1.

### 7.3 Battery

Use the battery endpoint (§5.3). `0x2A19` only if discovery shows it exists. 🔴

---

## 8. What Gadgetbridge marks unsupported / experimental for the Helio Strap

- The whole device is flagged **experimental** (`AmazfitHelioStrapCoordinator.java:33`).
- Device "sources" (firmware-matching ids) are an explicit **TODO/empty**
  (`AmazfitHelioStrapCoordinator.java:43-45`): firmware updates through Gadgetbridge are not
  supported.
- **Manual HR measurement** is disabled for all Zepp OS devices ("sometimes never finishes",
  `ZeppOsCoordinator.java:178-180`).
- **Sleep SpO₂ (`0x26`)** is parsed but never stored nor scheduled (§6.5).
- **Activity types** beyond walking are unmapped (issue #5843, open, 2026-03-06).
- **Workout HR** is persisted at 1/min only; the strap records ~1 Hz during workouts
  (issue #5617, open, opened 2025-12-14; maintainer: "can be implemented, but needs some work").
- **VO₂ max** only comes from workouts, which are hard to start on a screenless strap
  (issue #5986, 2026-04-08). The same thread reports that HRV/SpO₂/PAI/sleep stages were
  missing on the first Gadgetbridge syncs and appeared on later syncs; the maintainer's
  explanation was that data the official app had already synced is not re-offered. This is
  consistent with ack `01` semantics (§6.3).
- Live-activity and speed-zone screens, sedentary reminders: broken or unsupported (issue
  #5799, 2026-02-15). Not relevant to OpenCircuit.

---

## 9. Pitfalls, defensive handling, and where the references disagree

| # | Topic | Gadgetbridge | HelioCore | OpenCircuit should |
|---|---|---|---|---|
| 1 | Fetch control transport | `0x004B` encrypted when listed, else `…0004` | always `…0004` plaintext | start with `…0004`; fall back to `0x004B` (§6.1) |
| 2 | Start-reply timezone | honours the reply's offset byte | uses the phone's zone | honour the offset byte (§6.4) |
| 3 | Ack timing | after CRC check + successful processing | `03 09` immediately, before parsing, no CRC check | CRC check → parse → durable commit → ack (§6.3) |
| 4 | Activity record size | fixed 8 on Zepp OS | 8 if length divisible by 8, else 4 | fixed 8 (4 would be ambiguous whenever a round is a multiple of 8). 🟢 `HW:2026-09-30 (hw 0.132.27.2)`: 8, with the start reply counting records (§6.5) |
| 5 | HR-type `ff`/`00` | stored raw | dropped | drop (no reading), never write 0/255 bpm |
| 6 | Chunk acks | sent | never sent | send (§3.4) |
| 7 | MTU | 23 until auth, then asks for 247 | hard-coded 247 | use the OS-negotiated `maximumWriteValueLength` |
| 8 | Incoming encrypted messages | decrypted | **dropped** | decrypt (§3.3) |
| 9 | Packet-counter gap | round invalid → ack `09` | logged, continues | treat as invalid round → ack `09`, retry |
| 10 | Rounds per type | ≤ ~11 | ≤ 20 | bounded loop; persist cursor per type |
| 11 | Curve name | B-163 constants | comment says sect163k1, constants are B-163 | sect163r2 (§4.1) |
| 12 | Default key on missing/short key | silently uses a built-in default | refuses | refuse; clear UI error |
| 13 | Private-key RNG | `java.util.Random` | `SecRandomCopyBytes` | `SecRandomCopyBytes` |

Other defensive points:

- **Handle interleaving**: Gadgetbridge drops chunks whose handle differs from the message in
  progress, so a lost *last* chunk stalls reassembly until something resets it. On a new
  *first* chunk, discard any incomplete message and start over. 🔴 (recommendation)
- **Re-auth resets everything**: new handle counter (0), new session key, new sequence seed;
  never reuse them across connections (`SUP:297-299`). Gadgetbridge notes that initialising
  twice changes the session key mid-flight and breaks decryption (`SUP:909-913`).
- **Config writes** carry Gadgetbridge's own group version (HEALTH `03`), not necessarily the
  version the device reported (`SVC/Config:944-947`). 🔴 whether a v1/v2 device accepts that;
  prefer echoing the version from the read reply.
- **Start-reply length**: accept 15 or 16 bytes (`FETCH:190-195`; Gadgetbridge's check
  effectively accepts any 16th byte); treat other lengths as a failed round. The Helio sends
  16 (🟢 `HW:2026-09-30 (hw 0.132.27.2)`).
- **Empty start replies**: length 0 ends the type for this fetch whatever the start timestamp
  says; an all-zero start is normal there, not a malformed reply (🟢 `HW:2026-09-30 (hw 0.132.27.2)`, §6.2). Validating
  that timestamp turns every "nothing more" into a bogus failure and a retry.
- **Per-type length unit**: never assume the start reply's length is in bytes. Activity counts
  records (§6.5); an implementation that assumes bytes rejects every activity round.
- **Competing central**: while the Zepp app is installed and running, it reconnects to the
  strap and may win the connection. Auth failures other than `25` right after connect may
  mean another central holds the strap. 🔴 (plan-of-record §7; no protocol-level signal
  known).
- **Timestamps you can't trust**: after a battery drain the strap clock may be wrong until the
  time is set; drop records dated in the future or before the strap's first sync.
- **Temperature sentinels**: the first and last two i16 fields hold constants; 🔴 whether the
  temperature field itself ever holds a "no reading" value (treat `0x7fff`/`0x8000` and
  anything outside ~20–45 °C as missing; HelioCore filters 20–45 for display, `HC:1007-1008`).

---

## 10. Promote to 🟢: capture checklist (Juan's strap)

Record firmware (DIS `0x2A26` or endpoint `0x0043`) with every run. The Helio has no
`0x2A26` (§10.1), so use `0x0043`. Keep captures in
`desktop/captures/` (gitignored); commit findings only. Use `03 09` (keep) for every ack.

1. **Advertisement**: name exactly as broadcast (suffix or not); manufacturer data bytes;
   advertised service UUIDs; whether a second hyphen-suffixed identity appears.
2. **GATT dump**: every service and characteristic with properties; confirm `…0016`,
   `…0017`, `…0004`, `…0005` sit under `0xFEE0`; whether `0x180F/0x2A19` exists; the write
   types `…0016` and `…0004` accept.
3. **Auth** against the real key: `10 04 01` reply length is 67; `10 05 01` success; then a
   deliberately wrong key returns `10 05 25`. Promotes §4.
4. **Services list**: full endpoint table with encryption flags (is `0x004B` present? which
   are encrypted?). Promotes §3.5.
5. **One encrypted round-trip** (battery on `0x0029`): decrypts; check whether the device's
   trailer is `seq ‖ CRC` and whether its sequence numbers are its own or follow ours.
   Promotes §3.3.
6. **Chunk acks**: does the strap set `0x04` on its last chunk; does it notify acks on
   `…0016`; does anything break if the phone never acks.
7. **Time set** via `0x0047` (reply `06 01`), then read back through a fetch start reply.
8. **HEALTH config read**: record the group version and every arg value; confirm arg `0x05`
   toggles with Zepp's "Heart Rate Push".
9. **Fetch each type** in §6.5 over Path A for a 24 h window: record length rules, versions,
   first-record time vs *since*, and compare values against Gadgetbridge (or Zepp) for the
   same window. Specifically: HRV unknown byte (tz?), HRV statistic (compare to Zepp's
   displayed HRV; §6.5 holds RMSSD 🟡 on Amazfit's product-line documentation), temperature
   constants, sleep-session minute base (midnight vs noon).
10. **Ack semantics**: fetch a type, ack `09`, fetch again with the same *since*: same data
    re-delivered? Then (once, on a window already validated) ack `01` and fetch again.
11. **Tier 0 live HR**: with Heart Rate Push on, connect **without** auth and subscribe to
    `0x2A37`; then with it off. Note RR-interval presence (flag bit 4).
12. **Coexistence**: with the Zepp app installed but force-quit, does it steal the
    connection? After uninstalling Zepp, does the key keep working across strap reboots?

Device controls (§11–§15). Before any **write** in items 16–19, write down the strap's alarms
as the Zepp app shows them, so they can be restored by hand.

13. **Services list, controls rows**: are `0x001A`, `0x000F`, `0x0018`, `0x001E` present, and
    with which encryption flags? Promotes the new §3.5 rows.
14. **Find-device capabilities**: send `01` on `0x001A` and record the full reply (expected
    `02 01 <version>`). Record the version byte. Promotes §11.2.
15. **Find device, continuous vs one-shot**: send `03` once and nothing else. Time the vibration
    with a stopwatch: does it stop by itself, and after how long? Is `07` (§11.3) sent when it
    stops? Then send `03`, wait 5 s, send `06`: does it stop at once? Then `03`, `06` 500 ms
    later: one short buzz? Promotes §11.3 and §11.4.
16. **Find device before auth**: after connecting, send `03` on `0x001A` in plaintext **before**
    the auth handshake. Record any reply or disconnect, and whether the strap vibrates.
    Expected: nothing. Promotes §11.6.
17. **Alarms read**: send `09` on `0x000F` with a known set of alarms made in Zepp (including one
    disabled, one one-shot, one with smart wake if Zepp offers it). Check that the reply length
    is 2 + 10 × count, that the fields match §12.3, and what the 5 tail bytes hold. Promotes §12.3.
18. **Alarm write**: make a once-alarm in a free slot for 2 minutes ahead (§15.2 sequence).
    Check the ack status byte; check it fires, how long it vibrates, and whether tapping stops
    it; check whether any message reaches the phone when it fires or is dismissed. Then delete it
    and check the ack. Check whether the Zepp app (if still installed) shows it; re-read to see
    what became of the fired once-alarm. Promotes §12.2 (ack status), §12.3 (once alarms) and
    §12.5.
19. **Alarm capabilities**: send `01` on `0x000F` and record the reply. It is read-only in every
    reference, but its layout is unknown. Does it report the slot count? Promotes §12.2 and
    §12.4.
20. **Config groups and haptic args**: record the config capabilities reply (§5.5) and a
    constraints-included read of group `0x03` (all §13.4 args) and group `0x08` args `02 03 14 32 41
    42 43 44 45 46 51`. Which are present on the Helio, and with which allowed values? Promotes
    §13.4.
21. **Strap-originated find phone**: is there any gesture (e.g. a multi-tap) that makes the strap
    send `11` on `0x001A`? Promotes §11.5.

Parity addendum (§16–§21). Items 22–24 need nothing but an idle link; leave the Zepp app unable
to connect (phone Bluetooth off) so that every message seen is the strap's.

22. **Idle link**: after auth and the §5 setup, keep the link up and idle for at least 2 hours
    (overnight is better), the Mac awake. Log every unsolicited chunked message (time, endpoint,
    first byte, length, never the payload) and every disconnect (time, reason). Does the strap
    drop an idle link, and after how long? Does it send pings (`03` on `0x0015`), and how often?
    Promotes §16.2 rows 12–13 and §16.3.
23. **Sleep events**: the same idle link through a night, and on another day through a nap.
    Record the arrival time of any `06 01` / `06 00` on `0x001D`, then compare with that night's
    `0x48` record (§6.6). Then on another night disconnect before sleep and reconnect after
    waking: are the events delivered late (queued) or lost? Promotes §16.2 rows 1–2 and §16.4.
24. **GATT extras and battery**: does `…0010` exist, and with which properties; does `0x2A19`
    support notify? With the link idle, put the strap on its charger and take it off: does
    anything arrive (on `…0017`, `0x2A19` or `…0010`)? Promotes §16.2 rows 6–7.
25. **Config writes** (§17). First write down every HEALTH and WORKOUT setting as the Zepp app
    shows it, and restore them all at the end. Read every listed group with constraints and arg
    count `00` (`03 01 <group> 00`): record each group's version and the arg codes and type codes
    present, not their values. Then one ordinary write (e.g. relax reminder `14` on, with stress
    monitoring `13` already on): record the `06` reply bytes, then re-read. Then three rejection
    probes, each followed by a re-read: (a) a high-HR alert value (`02`) outside the allowed
    list; (b) relax reminder on while stress monitoring is off; (c) a write whose version byte is
    one more than the version read. Record exactly what came back (an ack status, nothing, or a
    value silently kept). Also record whether HEALTH arg `01` is present and its allowed values.
    Promotes §17.1, §17.3, §17.4, §17.7 and §17.9.
26. **Workouts** (§18). No capture can reveal the phone's start/pause/resume/end commands:
    `0x0019` is encrypted with a session key that only the two ends can derive (§18.1). What can
    be observed: (a) with an idle link held as in item 22 and workout detection on, walk briskly
    until the strap auto-detects a workout: does anything arrive on `0x0019` (`11 01`, `11 04`,
    something else) when it starts and ends? (b) Start a workout in the Zepp app, then turn the
    phone's Bluetooth off and connect HelioVerify: does the strap send anything on `0x0019`?
    Later, reconnect Zepp and record how long the workout kept running and whether Zepp could
    still end it. Promotes §16.2 rows 8–9, §18.3 and §18.4.
27. **Workout detection switch** (§19). In the Zepp app, turn Workout Detection **off**, let Zepp
    release the strap, and read WORKOUT group `09` with constraints and arg count `00`. Then turn
    it **on** in Zepp (note the sensitivity Zepp shows) and read again. Diff the two replies: which
    arg changed (an empty `40` list, or an arg not in §19.1)? Record the group version, the args
    present with their type codes, and the allowed lists of `40` and `42`. Restore Zepp's original
    setting. Promotes §19.1 and §19.2.
28. **Strap alerts** (§20). During the idle-link sessions of items 22–23, note the time of every
    buzz the wearer feels (an alarm, an HR, SpO₂ or relax alert) and check the log for any message
    within a minute of it. The one alert that needs no setting change and can be provoked: hold an
    idle link while the strap's battery drains past 20 %; it buzzes there (§13.4). Does anything
    arrive on `…0017`, `0x2A19` or `…0010`? Promotes §20.1.
29. **Naps** (§21). On a day with a normal night, take a 30–60 minute nap in the afternoon, more
    than an hour after waking, and check that the Zepp app shows it as a nap. Then fetch `0x48`
    over the last 24 h (ack `09`). Record the number of 594-byte records and, for each, only its
    structure: the bytes at `0x008` and `0x009`, whether the "midnight" field (`0x004`) is the same
    for the nap and the night, and whether any other byte outside the stage table and the HR /
    score fields differs systematically. Don't record times or values. Separately, on one night,
    fetch `0x48` while asleep (from an automated run) and again after waking with the same *since*:
    is a partial record delivered, and does it come back later with the same session timestamp
    and different content? Promotes §21.3 and §21.4.

### 10.1 Results from a real strap (2026-09-30)

Juan ran HelioVerify against his Helio Strap: hardware revision 0.132.27.2, firmware 3.3.6.5
per his Zepp account (the strap itself reports 3.25.0.3: see the re-test below), macOS
CoreBluetooth, local time UTC−4 (offset byte `f0`), every ack `03 09`, no time or setting
written. Source tag for everything below: `HW:2026-09-30 (hw 0.132.27.2)`, except the re-test
section, which is `HW:2026-09-30 13:35`. Only control bytes and lengths are recorded here; no
health value, serial number or MAC is, and the only setting value is HEALTH arg `0x04` (a
sampling switch, recorded to settle §5.5).

| §10 item | Result | Promoted |
|---|---|---|
| 1 Advertisement | Not recorded in this run. The strap matched HelioVerify's Helio Strap name matcher (§1), and the controls, which run only on that model, worked (item 15). | — |
| 2 GATT dump | Present: `…0016`, `…0017`, `…0004`, `…0005`, `0x2A37`, `0x2A19`, `0x2A2B`, `0x2A27`. **No DIS firmware revision `0x2A26`**, so the firmware version was not printed from DIS (the device-info endpoint gave it in the re-test). Parent services, properties and write types not recorded. | §1, §2 |
| 3 Auth | The real key authenticated. The wrong-key test (`10 05 25`) was **not run**. | §4.3 success path, §4.4 session key |
| 4 Services list | 28 endpoints (listed in §3.5). `0x004B` is present. Battery `0x0029`, connection `0x0015` and `0x004B` are plaintext on this strap. | §3.5, §5.2 |
| 5 Encrypted round-trip | Replies on `0x000A` and `0x001A` decrypted, and their trailer CRC matched `CRC-32(P ‖ S)`. (Battery could not serve: it is plaintext here.) Whether the device's sequence numbers are its own or follow ours was not recorded. | §3.3 |
| 6 Chunk acks | Not recorded. | — |
| 7 Time set | **Not run** (HelioVerify's `--set-time` is off by default). | — |
| 8 HEALTH config read | Config service version 3, groups `00 0b 08 09 0a`; HEALTH group `0x08` version 3. Argument values are personal settings and are not recorded here, except arg `0x04` in the re-test. Arg `0x05` vs Zepp's "Heart Rate Push": not tested. | §5.5 |
| 9 Fetch each type | Path A, 30-minute and 12-hour windows. Start replies are 16 bytes. **Activity's length counts records**; every other type counts bytes and its CRC matched (table below). Values were not compared with Zepp. | §6.1, §6.2, §6.4, §6.5 |
| 10 Ack semantics | After `03 09`, fetching an overlapping temperature window again **re-delivered** the data. A mid-transfer `03 09` was tolerated. Ack `01`: **not run**. | §6.3 |
| 11 Tier 0 live HR | Without auth: **not run**. With auth (§7.1 start + keep-alive): one `0x2A37` notification per second. | §7.1 |
| 12 Coexistence | **Not tested.** | — |
| 13 Services list, controls rows | `0x001A` and `0x0018` present and **encrypted**; `0x000F` present and **plaintext**; `0x001E` **absent**. All as the §3.5 defaults say, and `0x001E` is not used for the strap anyway. | §3.5 controls rows, §11.1, §12.1, §13.1 |
| 14 Find-device capabilities | `02 01 02`: version **2**, continuous. (ZeppKit reports a version only for exactly `02 01 <v>`.) | §11.2 |
| 15 Find device, continuous vs one-shot | `03` → the strap acked `04` and vibrated; `06` stopped it. The 0.5 s buzz (`03`, then `06` 500 ms later) worked too. Juan felt both. Not recorded: whether a lone `03` stops by itself and after how long, whether `07` is sent, and how long the 0.5 s buzz really lasts. | §11.3, §11.4 (the version), §13.2 |
| 16 Find device before auth | **Not run** (ZeppKit refuses encrypted sends before auth by design). | — |
| 17 Alarms read | `09` → an `0a` list that passed the length rule (2 + 10 × count) and ZeppKit's record checks (count ≤ 10, unique slots < 10, hour < 24, minute < 60, day bit 7 clear). Alarm times are personal and are not recorded; fields were not compared with Zepp, and the tail bytes were not recorded. | §12.2 (`09`, `0a`), §12.3 (record size) |
| 18 Alarm write | **Not run**: nothing was written. | — |
| 19 Alarm capabilities | **Not sent.** | — |
| 20 Config groups and haptic args | Groups `00 0b 08 09 0a` (item 8): **no SOUND & VIBRATION group `03`**. A constraints-included read of HEALTH args `02 03 14 32 41–46 51` came back and parsed. Values and allowed values are personal settings and are not recorded. | §13.4 |
| 21 Strap-originated find phone | **Not tested.** | — |

**Fetch rounds** (item 9):

| Type | Window | Announced length → data received | Unit | CRC |
|---|---|---|---|---|
| activity `0x01` | 30 min | `30` → one 241-byte packet: counter + 240 bytes = 30 × 8 | **records** | not reached: ZeppKit aborted the round with a false overflow before the check (fixed since). Ok in the re-test |
| activity `0x01` | 12 h | `720` → ZeppKit aborted at 960 bytes | **records** | not reached. Ok in the re-test: 720 records, 5760 B |
| temperature `0x2e` | 30 min / 12 h | `240` → 240 B / 5760 B | bytes | ok |
| stress-auto `0x13` | 12 h | 720 B (1 byte per minute) | bytes (= records here) | ok |
| HRV `0x49` | — | 2136 B = 356 × 6 | bytes | ok |
| SpO₂ `0x25` | — | 6566 B = 1 + 101 × 65 | bytes | ok |
| resting HR `0x3a` | — | 6 B | bytes | ok |
| sleep respiratory rate `0x38` | — | 3528 B = 441 × 8 | bytes | ok |
| sleep session `0x48` | — | 594 B | bytes | ok |
| PAI `0x0d` | — | 102 B | bytes | ok |
| sleep SpO₂ `0x26` | — | 421 B = 1 + 14 × 30 | bytes | ok, but every record decoded to the same SpO₂ value: **the §6.5 field layout for `0x26` is 🔴** (out of v1 scope; parser unchanged) |

- For the per-minute types the start timestamp equalled the requested *since*; for event
  types it was the first record's own time.
- **Empty start replies** (status `01`, length 0) came in two forms (§6.2): the far-future
  sentinel for types with nothing in the window (`0x3d`, `0x02`, `0x12`, and `0x26`'s second
  round), and the all-zero start on the follow-up round straight after a round that delivered
  data (`0x2e`, `0x13`). ZeppKit rejected the all-zero form as malformed and retried once
  (fixed since: length 0 is empty whatever the timestamp).
- The strap coped with ZeppKit's mid-transfer `03 09` on the activity round: it still sent
  its transfer done and `10 03 01`, and the next type fetched normally.

**Re-test at 13:35** (`HW:2026-09-30 13:35`: HelioVerify at `293cd90`, read-only, every ack
`03 09`):

- **Activity CRC**: a start reply announced `3c 00 00 00`, i.e. 60 records; 60 records (480 B)
  arrived and the CRC matched. A 12 h run gave 720 records (5760 B), CRC ok. In that same
  12 h run all 7 fetched types matched their CRCs, with no retries and no errors. Promotes
  the activity CRC in §6.2 and §6.5.
- **Firmware**: the strap's own device-info read (endpoint `0x0043`, §5.3) reports firmware
  **3.25.0.3**. The hardware revision (0.132.27.2) was already known. Promotes §1.
- **HEALTH arg `0x04`**: it read `false` in a complete (non-partial) config read, yet in the
  12 h activity fetch of the same session all 720 minutes carried a heart rate. So `0x04` does
  **not** gate recording: it is the vendor's "Active heart rate monitoring" switch, which only
  raises the HR sampling rate during detected activity. Promotes §5.5.

**Still untested** (keep their tags): wrong-key auth (`10 05 25`); ack `01` (delete); Tier 0
live HR without auth; Zepp-app coexistence; time set (`0x0047`, `06 01`); the HRV statistic
(RMSSD vs SDNN; §6.5 holds RMSSD 🟡 on Amazfit's product-line documentation, which doesn't name
the strap, and no value has been compared with Zepp's). Also not yet observed: the width of the device-info bit-0 prefix (§5.3; not
recorded in the re-test); the advertisement; chunk acks; write types;
Path B (`0x004B`); arg `0x05` vs "Heart Rate Push"; the device's sequence numbers; any value
compared against Zepp (HRV unknown byte, temperature constants, sleep-session minute base);
the `0x26` layout. Controls (items 13–21): find device before auth; how long a lone `03`
buzzes and whether `07` is sent; the real length of the 0.5 s buzz; any alarm write and its ack
status; alarm capabilities `01`; find phone `11`; smart wake and snooze.

---

## 11. Find device (endpoint `0x001A`)

This section and §12–§15 are the **device-controls addendum** (2026-09-30). The Helio Strap has
a vibration motor and no display (§1). Amazfit documents three phone-triggered or scheduled
vibrations: "Find Device" (60 s, continuous), up to 10 alarms (60 s, stopped by tapping the
strap) and a set of health alerts (§13.4). 🟡 `AMZ-S`, `AMZ-M p.2-3,10-12`. HelioCore implements
none of this (no match for vibration, alarm or find anywhere in `HC`), so every protocol fact
below comes from Gadgetbridge alone, plus two Helio tester reports in its tracker.

### 11.1 Channel

| Fact | Tag / source |
|---|---|
| Find device and find phone share endpoint **`0x001A`**. | 🟡 `SVC/FindDevice:34`; 🟢 find device on the Helio `HW:2026-09-30 (hw 0.132.27.2)` (find phone untested) |
| It is **encrypted by default**. As always, the services list (§5.2) can override that. | 🟡 `SVC/FindDevice:60`, `SVC/Services:83-85`; 🟢 listed as encrypted on the Helio `HW:2026-09-30 (hw 0.132.27.2)` |
| Gadgetbridge sends only the capabilities request (§11.2) at session setup, and only if the services list contains `0x001A`. It sends start/stop commands whenever the user asks, **without** checking the services list. OpenCircuit must be stricter (§14). | 🟡 `GB/service/devices/huami/zeppos/ZeppOsSupport.java:947-951`, `SVC/FindDevice:139,149-154` |

### 11.2 Capabilities and version

Send `01`. The strap replies with three bytes, `02 <b1> <version>`. 🟡 `SVC/FindDevice:36-37,73-82`

| Byte | Meaning |
|---|---|
| `[0]` = `02` | capabilities reply |
| `[1]` | `01` in every example Gadgetbridge records; not interpreted. 🔴 probably a status byte |
| `[2]` | **find-device service version**. Gadgetbridge records version `01` on a Mi Band 7 and `02` on an Active 2 and a GTR 4. |

A reply that isn't exactly 3 bytes is ignored, and the version stays 0. **Version ≥ 2 means the
strap supports continuous find** (§11.4). 🟡 `SVC/FindDevice:76-81,86,199-201`. The Helio
replies `02 01 02`: **version 2, continuous**. 🟢 `HW:2026-09-30 (hw 0.132.27.2)`

### 11.3 Messages

| Bytes | Direction | Meaning | Tag / source |
|---|---|---|---|
| `01` | phone → strap | capabilities request (§11.2) | 🟢 `HW:2026-09-30 (hw 0.132.27.2)`; 🟡 `SVC/FindDevice:36,139` |
| `02 …` | strap → phone | capabilities reply (§11.2) | 🟢 `HW:2026-09-30 (hw 0.132.27.2)`; 🟡 `SVC/FindDevice:37,73-82` |
| **`03`** | phone → strap | **start** "find device": the strap starts vibrating | 🟢 `HW:2026-09-30 (hw 0.132.27.2)` (felt); 🟡 `SVC/FindDevice:38,179-185` |
| `04` | strap → phone | the strap acknowledges a **start**. No further bytes are read. 🔴 whether it also acknowledges a stop. | 🟢 start ack `HW:2026-09-30 (hw 0.132.27.2)`; 🟡 `SVC/FindDevice:39,83-94` |
| **`06`** | phone → strap | **stop** "find device" | 🟢 `HW:2026-09-30 (hw 0.132.27.2)` (felt); 🟡 `SVC/FindDevice:40,180` |
| `07` | strap → phone | the strap stopped "find device" on its own side. Gadgetbridge only logs it. 🔴 whether it is sent after a tap on the strap, after the strap's own timeout, or both. | 🟡 `SVC/FindDevice:41,106-108` |
| `11` | strap → phone | the strap asks the phone to ring ("find phone", §11.5) | 🟡 `SVC/FindDevice:42,95-105` |
| `12 01` | phone → strap | acknowledgement of `11` (`01` = success) | 🟡 `SVC/FindDevice:43,187-191` |
| `13` | strap → phone | the strap ends "find phone" | 🟡 `SVC/FindDevice:44,109-113` |
| `14` | phone → strap | the phone ends "find phone" (the user found it) | 🟡 `SVC/FindDevice:45,193-197` |
| `15 <mode>` | strap → phone | find-phone mode: `00` vibrate only, `01` ring | 🟡 `SVC/FindDevice:46,114-126` |

Opcodes `05`, `08`–`10` and everything above `15` are not used by any reference. Ignore unknown
opcodes; never send them.

### 11.4 One-shot vs continuous, and how long the strap buzzes

- **Continuous** (version ≥ 2): one `03` makes the strap vibrate until it is told to stop with
  `06` (or until it stops on its own, see below). 🟡 `SVC/FindDevice:86-92`,
  `GB@bbd9868e` (the commit that added version-based continuous-find detection, 2025-04-03).
- **One-shot** (version < 2): each `03` plays **one** burst, using the strap's "find band"
  vibration pattern (type `09`, §13.1). To keep it going, Gadgetbridge waits for the `04` ack and
  then sends another `03` after a delay. The delay is the total length of the find-band pattern
  (on + off times, multiplied by its repeat count), capped at 10 s. When the pattern is the
  device default, Gadgetbridge doesn't know its length and uses 10 s. It stops the cycle when the
  user presses stop, and then sends `06`. 🟡 `SVC/FindDevice:83-94,149-154`,
  `GB/service/devices/huami/HuamiUtils.java:46-70`
- **Helio evidence** (🟡, one Gadgetbridge tester each):
  - Gadgetbridge's find device on a Helio Strap is "continuous until stopped … a repeating series
    of vibrations that continues indefinitely until you tap 'Found It!'" (`GB#6715`, comment of
    2026-09-06).
  - With Gadgetbridge's call handling (a single `03` when the call rings and `06` when it is
    answered or ends; **no** re-send loop), the tester got "continuous vibration for incoming calls
    until hung up" (`GB#6755`, 2026-09-12). A single `03` therefore keeps the Helio vibrating for at
    least a ring's length. That strongly suggests the Helio is a version ≥ 2 (continuous) device.
    🟢 It is: the Helio reports version 2 (§11.2, `HW:2026-09-30 (hw 0.132.27.2)`).
- **Duration**: Amazfit says "Find Device" in the Zepp app makes the strap "vibrate continuously
  for 60 seconds" (`AMZ-M p.3`). 🔴 **whether the 60 s limit is enforced by the strap or by the
  Zepp app** sending `06`. The Gadgetbridge tester's "indefinitely" argues for the app, but it
  would also be true if the strap were one-shot and Gadgetbridge's 10 s re-send loop were running.
  §10 item 15 decides.
- **Gadgetbridge pitfall (don't copy)**: Gadgetbridge's settings code reads the find-device version
  from a stored preference that its find-device code never writes, so its *settings* always
  treat a Zepp OS device as one-shot (and offer a "find band" vibration pattern). Its find loop
  uses the version from the live reply and is unaffected. `SVC/FindDevice:48-49,77,199-201`
  (no preference update anywhere in that file), `GB/devices/huami/zeppos/ZeppOsCoordinator.java:584-586,606-608`.

**OpenCircuit rule** (🔴 recommendation):
- Always send `06` when finding ends: when the user stops it, and **after 60 s of phone-side time**
  at the latest. Never rely on the strap's own timeout.
- Version ≥ 2: send one `03`.
- Version < 2, or no well-formed capabilities reply: send `03`, and on each `04` send another
  `03` 10 s later, until 60 s have passed. Then send `06`.
- If the link drops while finding, the strap may keep vibrating until its own timeout (unknown).
  On the next authenticated connection, if a find was active when the link dropped, send `06`
  once.
- Treat `07` from the strap as "finding stopped" and update the UI.

### 11.5 Find phone (strap → phone)

Some Zepp OS devices can ask the phone to ring. The strap sends `11`. Gadgetbridge replies at
once with `12 01`, because a device only sends its mode after that acknowledgement. It then
waits 1.5 s for an optional `15 <mode>` (`00` vibrate only, `01` ring) before it starts ringing
(ring if no mode arrives). `13` from the strap, or `14` from the phone, ends it. 🟡
`SVC/FindDevice:95-126,187-197`. 🔴 **whether the Helio can send `11` at all**: it has no screen or
button, and Amazfit documents no gesture for it (`AMZ-M`). §10 item 21. v1: answer `11` with
`12 01` and show a local notification. That is harmless and needs no UI beyond it.

### 11.6 Before authentication

Endpoint `0x001A` is encrypted by default (§11.1), and before auth there is no session key.
Every reference sends find-device commands only after auth and the services list (§5). 🟡
`GB/service/devices/huami/zeppos/ZeppOsSupport.java:900-951`. 🔴 whether the strap would accept a
**plaintext** `03` before auth (§10 item 16). **Rule: find device requires a completed auth.**
Without the key there is no find device and no buzz (the plan of record's "key required"
decision). ZeppKit's refusal to send encrypted messages before the session is confirmed already
enforces this.

### 11.7 Worked example E: find device start and stop (constructed, made-up key)

This continues worked examples B and C: the same session key
`8c 45 6e 06 23 92 2f ab 73 ce 01 a0 cd dd ee ff`. After example B the encrypted-sequence
number is `0x2933d232`. Start is the connection's 4th message (handle `0x04`); stop is the 5th
(handle `0x05`). `0x001A` is encrypted (the default). `OC-vec`

| Step | Start (`03`) | Stop (`06`) |
|---|---|---|
| message key = session key XOR handle | `88 41 6a 02 27 96 2b af 77 ca 05 a4 c9 d9 ea fb` | `89 40 6b 03 26 97 2a ae 76 cb 04 a5 c8 d8 eb fa` |
| `P ‖ S` | `03` `32 d2 33 29` | `06` `33 d2 33 29` |
| CRC-32 over `P ‖ S` | `0xe374a1e5` → `e5 a1 74 e3` | `0x932849f0` → `f0 49 28 93` |
| padded plaintext (1 + 4 + 4 = 9 → 16) | `03 32 d2 33 29 e5 a1 74 e3` + 7 × `00` | `06 33 d2 33 29 f0 49 28 93` + 7 × `00` |
| AES-128-ECB(message key) | `8f 01 cd 1e ad c4 db 8b e8 24 03 ae 5b ff 55 45` | `75 74 e9 d5 fa 93 f4 4d a0 fb 8c 33 b2 52 53 cd` |
| next sequence number | `0x2933d233` | `0x2933d234` |

At MTU 247 each is one 27-byte chunk; at MTU 23 each takes two chunks (the first chunk has room
for 9 data bytes, §3.2):

```
MTU 247, start (27 B): 03 0f 00 04 00 | 01 00 00 00 | 1a 00 | 8f 01 cd 1e ad c4 db 8b e8 24 03 ae 5b ff 55 45
MTU 247, stop  (27 B): 03 0f 00 05 00 | 01 00 00 00 | 1a 00 | 75 74 e9 d5 fa 93 f4 4d a0 fb 8c 33 b2 52 53 cd

MTU 23, start:  chunk 0 (20 B): 03 09 00 04 00 | 01 00 00 00 | 1a 00 | 8f 01 cd 1e ad c4 db 8b e8
                chunk 1 (12 B): 03 0e 00 04 01 | 24 03 ae 5b ff 55 45
```

The total-length field is `01`: the plaintext length (§3.3). The strap then replies `04` on
`0x001A` (its own handle and encryption). If the services list had flagged `0x001A` plaintext,
the start would instead be one 12-byte chunk: `03 07 00 04 00 01 00 00 00 1a 00 03`.

A **short buzz** (§13.2) is exactly this pair with the stop sent 500 ms after the start.

---

## 12. Alarms (endpoint `0x000F`)

### 12.1 Channel

| Fact | Tag / source |
|---|---|
| Alarms use endpoint **`0x000F`**, **plaintext by default** (the services list may override). | 🟡 `SVC/Alarms:47,72`; 🟢 listed as plaintext on the Helio `HW:2026-09-30 (hw 0.132.27.2)` |
| The Helio stores **up to 10 alarms**. Each vibrates for 60 s and is stopped by tapping the front of the strap repeatedly. They are made in Zepp › Device › Helio Strap › Alarm. | 🟡 `AMZ-M p.2,3,12`, `AMZ-S` |
| Gadgetbridge reads the alarm list at session setup when `0x000F` is in the services list. | 🟡 `SVC/Alarms:105-118`, `GB/service/devices/huami/zeppos/ZeppOsSupport.java:947-951` |
| A Helio tester reports alarms work with Gadgetbridge. | 🟡 `GB#6715` (2026-09-04: the motor "works fine for alarms and the 'Find device' feature") |

### 12.2 Commands

| Bytes | Direction | Meaning | Tag / source |
|---|---|---|---|
| `01` | phone → strap | capabilities request. **Defined but never sent by Gadgetbridge**; the reply (`02 …`) layout is unknown. | 🔴 `SVC/Alarms:49-50` |
| `03 01 <record>` | phone → strap | **create or replace** the alarm in the slot named inside the 10-byte record (§12.3). Gadgetbridge uses this for new alarms *and* for every change to an existing one, including enable/disable. The `01` is not explained; 🔴 it is probably the number of records that follow. Always send `01` and one record. | 🟡 `SVC/Alarms:51,144-171` |
| `04 <status>` | strap → phone | create ack | 🟡 `SVC/Alarms:52,83-85` |
| `05 01 <slot>` | phone → strap | **delete** the alarm in `<slot>` (same unexplained `01`) | 🟡 `SVC/Alarms:53,172-179` |
| `06 <status>` | strap → phone | delete ack | 🟡 `SVC/Alarms:54,86-88` |
| `07 …` | phone → strap | "update". It exists, but its layout is unknown and Gadgetbridge never sends it. **Never send it.** | 🔴 `SVC/Alarms:55` |
| `08 <status>` | strap → phone | update ack | 🟡 `SVC/Alarms:56,89-91` |
| `09` | phone → strap | **read all alarms** | 🟢 `HW:2026-09-30 (hw 0.132.27.2)`; 🟡 `SVC/Alarms:57,114-118` |
| `0a <count> <record>…` | strap → phone | alarm list: `count` (u8), then `count` × 10-byte records. The payload must be exactly 2 + 10 × `count` bytes; otherwise discard the whole reply. | 🟢 `HW:2026-09-30 (hw 0.132.27.2)` (length rule held); 🟡 `SVC/Alarms:58,96-99,184-196` |
| `0f` | strap → phone | **the alarms changed on the strap**. Gadgetbridge re-reads the list with `09`; any further bytes are ignored. | 🟡 `SVC/Alarms:59,92-95` |

The ack **status** byte is only logged by Gadgetbridge. 🔴 `01` = success, by analogy with every
other Zepp OS ack in this document. Treat anything else, or no ack, as a failure.

**Enable/disable** has no command of its own. Re-send the whole record with `03 01` and the
enabled bit changed. 🟡 `SVC/Alarms:151-157`

### 12.3 One alarm record (10 bytes)

The record is identical in the create command (after `03 01`) and in each entry of the `0a` list.
🟡 `SVC/Alarms:61-69,158-171,234-246`. On the Helio, the read list's records were 10 bytes and
passed the range checks below (slot, hour, minute, day bit 7). 🟢 `HW:2026-09-30 (hw 0.132.27.2)` for the size; the field
meanings stay 🟡 until compared with the Zepp app (§10 item 17).

```
 +-------+------+------+--------+--------+-------------------------+
 | flags | slot | hour | minute | repeat | 5 bytes, meaning unknown |
 +-------+------+------+--------+--------+-------------------------+
   [0]     [1]    [2]     [3]      [4]          [5..9]
```

| Offset | Field | Encoding | Tag / source |
|---|---|---|---|
| `[0]` | flags | bit 0 (`0x01`) **smart wake**; bit 1 (`0x02`) unknown, never set by Gadgetbridge; bit 2 (`0x04`) **enabled**; bits 3–7 not used by any reference | 🟡 `SVC/Alarms:67-69,151-157,239-240` |
| `[1]` | slot | position 0–9. It is the alarm's identity: there is no other id. | 🟡 `SVC/Alarms:62,162,238`, `GB/devices/huami/HuamiCoordinator.java:155-157` |
| `[2]` | hour | 0–23, the **strap's local wall-clock time** (whatever §5.1 last set) | 🟡 `SVC/Alarms:63,163` |
| `[3]` | minute | 0–59 | 🟡 `SVC/Alarms:64,164` |
| `[4]` | repeat | day bitmask, **Monday = bit 0** … **Sunday = bit 6**: `01` Mon, `02` Tue, `04` Wed, `08` Thu, `10` Fri, `20` Sat, `40` Sun. `00` = **once** (no repeat); `1f` = Mon–Fri; `7f` = every day. Bit 7 is never set. | 🟡 `SVC/Alarms:65,165,243`, `GB/model/Alarm.java:32-41` |
| `[5..9]` | unknown | Gadgetbridge writes five `00`s. It notes that `[8]` is `00` in what it sends but `01` in what the device returns. Ignore them on read; write `00`s. | 🟡 `SVC/Alarms:166-170` |

**Pitfall:** this day mask is **Monday-first**, while the time command's day-of-week byte (§5.1)
counts **Sunday = 0**. Don't share a helper between them.

**Once alarms**: the record has no date. Gadgetbridge sends the hour and minute only; the strap
presumably fires at the next occurrence. 🔴 whether a fired once-alarm is then disabled, deleted
or kept by the strap (§10 item 18: re-read after it fires).

**Fields a display-less strap has no use for, or that don't exist:**
- **Label / title**: no field in the record. There is no way to send one. 🟡 (absent from the layout)
- **Snooze**: no field. Gadgetbridge's view is that Zepp OS alarms always snooze and that no flag
  disables it (`GB/devices/huami/zeppos/ZeppOsCoordinator.java:319-322`, said of the watches).
  Amazfit documents only "tap to stop" for the Helio (`AMZ-M p.2,12`). 🔴 whether the strap
  snoozes at all.
- **Sound**: none; the strap has only the motor.
- **Smart wake**: Gadgetbridge offers the bit on every slot of every Zepp OS device
  (`ZeppOsCoordinator.java:325-327`). Amazfit's Helio documents don't mention smart wake. 🔴
  whether the Helio honours the bit. The smart-wake window is not in the known fields (🔴 maybe
  in `[5..9]`).

### 12.4 Capacity

- **10 slots, numbered 0–9.** Amazfit documents 10 (`AMZ-M p.12`). Gadgetbridge hard-codes 10 for
  every Zepp OS device and silently drops anything beyond (`HuamiCoordinator.java:155-157`,
  `SVC/Alarms:120-131`). 🟡
- **The strap does not report its capacity** through any path a reference uses. The `01`
  capabilities reply (§12.2) might, but its layout is unknown. 🔴
- Defensive rule: if a list reply has `count` > 10, a slot ≥ 10, or the same slot twice, treat
  alarms as **unsupported for this connection** and write nothing (§14).

### 12.5 Strap → phone messages

| Event | Message | Tag |
|---|---|---|
| alarms edited on the strap side (e.g. by another central, or a once-alarm expiring 🔴) | `0f` on `0x000F` | 🟡 `SVC/Alarms:92-95` |
| an alarm **fires** | **none known** | 🔴 |
| an alarm is **dismissed** (tap) | **none known** | 🔴 |

So the phone cannot know that an alarm rang or was dismissed. Don't build features on it. §10
item 18 checks for any unexpected message during a fire.

### 12.6 Worked example F: set a 06:30 weekday alarm (constructed)

Precondition: a read (§15.2 step 2) returned one alarm, in slot 3, so the lowest free slot is 0.
The new alarm is slot 0, enabled, no smart wake, 06:30, Monday–Friday.

```
record  = 04 00 06 1e 1f 00 00 00 00 00
          |  |  |  |  |  +------------- 5 unknown bytes, written as 00
          |  |  |  |  +---------------- repeat 0x1f = Mon|Tue|Wed|Thu|Fri
          |  |  |  +------------------- minute 0x1e = 30
          |  |  +---------------------- hour 6
          |  +------------------------- slot 0
          +---------------------------- flags 0x04 = enabled, no smart wake
payload = 03 01 04 00 06 1e 1f 00 00 00 00 00      (12 bytes)
```

Plaintext (the default for `0x000F`), handle `0x06`: `OC-vec`

```
MTU 247 (23 B): 03 07 00 06 00 | 0c 00 00 00 | 0f 00 | 03 01 04 00 06 1e 1f 00 00 00 00 00

MTU 23:  chunk 0 (20 B): 03 01 00 06 00 | 0c 00 00 00 | 0f 00 | 03 01 04 00 06 1e 1f 00 00
         chunk 1 ( 8 B): 03 06 00 06 01 | 00 00 00
```

Expected reply on `0x000F`: `04 01` (create ack; status `01` 🔴). Then re-read: example G. To
**disable** this alarm later, send `03 01 00 00 06 1e 1f 00 00 00 00 00` (flags `00`). To
**delete** it, send `05 01 00` and expect `06 01`.

If the services list flags `0x000F` as encrypted, encrypt as in §3.3. The values below use the
session of example C with sequence number `0x2933d234` (right after example E), handle `0x06`.
`OC-vec`

| Step | Bytes |
|---|---|
| message key = session key XOR `0x06` | `8a 43 68 00 25 94 29 ad 75 c8 07 a6 cb db e8 f9` |
| `P ‖ S` | `03 01 04 00 06 1e 1f 00 00 00 00 00` `34 d2 33 29` |
| CRC-32 over those 16 bytes | `0xe7a148e8` → `e8 48 a1 e7` |
| padded plaintext (12 + 4 + 4 = 20 → 32) | the 16 bytes above, `e8 48 a1 e7`, 12 × `00` |
| AES-128-ECB(message key) | `29 21 7f fc d3 8d a4 6a aa de c6 76 68 0b e7 b8 1e 23 15 f1 6c 90 5e e2 98 9b 17 90 c0 78 3d 6c` |
| one chunk at MTU 247 (43 B) | `03 0f 00 06 00 0c 00 00 00 0f 00` + the 32 ciphertext bytes |
| next sequence number | `0x2933d235` |

### 12.7 Worked example G: read back a list of 2 alarms (constructed)

The re-read after example F (§15.2 step 7):

```
→ 09
← 0a 02
     04 00 06 1e 1f 00 00 00 01 00
     01 03 09 0f 60 00 00 00 01 00
```

Length check: 2 + 2 × 10 = 22 bytes ✓. Decoded:

| Slot | Enabled | Smart wake | Time | Repeat |
|---|---|---|---|---|
| 0 | yes (flags `04`) | no | 06:30 | `1f` Mon–Fri |
| 3 | **no** (flags `01`: only the smart-wake bit) | yes | 09:15 | `60` Sat + Sun |

Slot 0 is example F's alarm. Free slots: 1, 2, 4–9. Byte `[8]` of each record is `01`, as
Gadgetbridge says the device returns; a parser must ignore it.

---

## 13. Vibration and other haptics

What the phone can make the motor do, from most to least useful for OpenCircuit.

### 13.1 Vibration patterns (endpoint `0x0018`)

| Fact | Tag / source |
|---|---|
| Endpoint **`0x0018`**, **encrypted by default**. | 🟡 `SVC/VibrationPatterns:44,50`; 🟢 listed as encrypted on the Helio `HW:2026-09-30 (hw 0.132.27.2)` (never written) |
| **Set** = `03`, u8 **type**, u8 **source** (`01` custom pattern follows, `00` use the device's built-in default), u8 **test** (`01` = also play it now, `00` = store only), u8 **n** = number of on/off pairs, then n × (u16 LE **on** ms, u16 LE **off** ms). With source `00`, n is `00` and nothing follows. | 🟡 `SVC/VibrationPatterns:113-136` |
| Reply `04 <status>` (only logged). | 🟡 `SVC/VibrationPatterns:47,59-68` |
| Gadgetbridge caps a pattern at **10 s** in total (on + off), dropping any pair that would exceed it. It attributes the limit to the official app. | 🟡 `SVC/VibrationPatterns:117-120`, `GB/service/devices/huami/HuamiUtils.java:72-100` |
| **There is no read command.** Gadgetbridge can't read the strap's patterns back and marks that as unresolved. | 🟡 `SVC/VibrationPatterns:71-77` |
| Gadgetbridge **writes every type on every connect**, with source `00` (device default) for any type the user has not customised in Gadgetbridge. Connecting Gadgetbridge therefore resets any custom pattern made in Zepp. **Don't copy that.** | 🟡 `SVC/VibrationPatterns:71-77,104-110`, `GB/devices/huami/HuamiCoordinator.java:438-483` |

**Type codes** 🟡 `GB/service/devices/huami/HuamiVibrationPatternNotificationType.java:24-33`, and
which of them Gadgetbridge configures on Zepp OS (`GB/devices/huami/zeppos/ZeppOsCoordinator.java:570-593`):

| Type | Meaning | Gadgetbridge sets it on Zepp OS | Plausible on the Helio |
|---|---|---|---|
| `00` | app notifications | always | 🔴 no: the strap is not sent notifications (§13.3) |
| `01` | incoming call | always | 🔴 no, same reason |
| `02` | incoming SMS | always | 🔴 no, same reason |
| `04` | goal reached | always | 🔴 only if the strap has goal alerts (§13.4) |
| `05` | alarm | always | 🔴 probably: the strap fires alarms itself |
| `06` | idle / inactivity alert | always | 🔴 only if the strap has inactivity alerts (§13.4) |
| `08` | event reminder | if the reminders capability reports slots | 🔴 unknown |
| `09` | find band | when find device is one-shot (always, given the §11.4 pitfall) | 🔴 only for one-shot find |
| `0a` | to-do list | never (not implemented) | — |
| `0c` | schedule | never (not implemented) | — |

🔴 **Whether the Helio implements `0x0018` at all** is unknown (§10 item 13). 🔴 Whether a set
with test = `01` also **stores** the pattern: assume it does.

Layout illustration (constructed; **v1 must not send it**, see §15): alarm type, custom, play
now, two pairs of 400 ms on / 200 ms off →
`03 05 01 01 02 90 01 c8 00 90 01 c8 00`.

### 13.2 "Vibrate now"

No reference has a dedicated "vibrate now" or motor-test opcode for Zepp OS. Two ways exist:

| Method | How | Tag / source | Use in OpenCircuit |
|---|---|---|---|
| **Find-device pulse** | send `03` on `0x001A`, then `06` 500 ms later | 🟢 on the Helio `HW:2026-09-30 (hw 0.132.27.2)`: a short buzz, felt. 🟡 Gadgetbridge's notification buzz (`SVC/FindDevice:166-171`, `GB@4e786b26`), which a Helio tester reports gives a "single vibration" (`GB#6755`, 2026-09-12) | **Yes.** The only transient buzz. The length of the buzz for a given delay is 🔴 (what the strap plays between start and stop). |
| Pattern test | §13.1 set with test = `01` | 🔴 not reported on the Helio; may persist | **No.** It can overwrite a stored pattern that can't be read back. |

### 13.3 Notifications and calls on a strap without a display

- Zepp OS normally sends notifications on endpoint `0x001E` (encrypted by default), and the watch
  shows and buzzes them. 🟡 `SVC/Notification:59,98`
- **Gadgetbridge never uses `0x001E` for the Helio Strap.** For a device without a display (except
  the Helio Ring), it turns each phone notification into a find-device pulse (§13.2), and an
  incoming call into find-device start, with stop when the call is answered or ends. The
  user-facing "send app notifications" switch still applies. 🟡
  `GB/service/devices/huami/zeppos/ZeppOsSupport.java:414-438`, added in `GB@4e786b26`
  (2026-09-12, `GB#6755`, closing `GB#6715`). A Helio tester confirmed both behaviours
  (`GB#6755`). Gadgetbridge's website now lists "calls and notifications (vibrating the strap)"
  for the Helio (gadgetbridge.org, Amazfit gadgets page, fetched 2026-09-30).
- The Helio Ring (also no display) is excluded from that path and is sent real notifications on
  `0x001E`. 🟡 same lines. OpenCircuit's controls are specified for the **strap only**.
- Gadgetbridge hides the vibration-pattern and "sound and vibration" settings for devices without
  a display (`ZeppOsCoordinator.java:483-505`).
- **For OpenCircuit**: an iOS app can't observe other apps' notifications or calls, so relaying
  them isn't possible the way Gadgetbridge does it on Android. 🔴 whether the strap vibrates for
  iPhone notifications through ANCS on its own: Amazfit documents no notification feature for
  the Helio (`AMZ-M`). The pulse can still be used for OpenCircuit's **own** events (e.g. a sync
  finished, a health alert computed on the phone).

### 13.4 Strap-side haptic alerts configured through the config endpoint

These are **persistent settings** on the strap (§5.5 transport: endpoint `0x000A`, encrypted by
default; one write message per group). The strap evaluates them itself and vibrates without the
phone. Value types are §5.5's type codes. 🟡 `SVC/Config:390-402,467-576` unless stated.

**Constraint bytes follow the value** in a read with constraints included (e.g. a byte entry
is: arg, `10`, value, n, n allowed values). 🟡
`GB/service/devices/huami/zeppos/services/config/ConfigByte.java:27-41`. This fills in where §5.5 was
silent. 🟢 `HW:2026-09-30 (hw 0.132.27.2)`: a constraints-included read of the HEALTH alert args parsed cleanly with this
placement.

| Group | Arg | Type | Meaning | Encoding | Helio evidence |
|---|---|---|---|---|---|
| HEALTH `08` | `02` | byte | **high heart-rate alert** threshold | `00` = off, otherwise bpm. The allowed values come from the constraints; Gadgetbridge's own list is 100–150 in steps of 10 (`GB-res/values/arrays.xml:3073-3081`) | 🟡 Amazfit: alerts when HR stays above/below the limit for 10 consecutive minutes at rest, not during sleep (`AMZ-M p.10`, `AMZ-S`). 🟢 read and parsed on the Helio `HW:2026-09-30 (hw 0.132.27.2)` |
| HEALTH `08` | `03` | byte | **low heart-rate alert** threshold | `00` = off, else bpm (Gadgetbridge: 40/45/50, `arrays.xml:3110-3115`) | same as above; 🟢 read and parsed on the Helio `HW:2026-09-30 (hw 0.132.27.2)` |
| HEALTH `08` | `14` | bool | **relax (stress) reminder** | `00`/`01` | 🟡 Amazfit: alerts when stress stays above the limit for 10 min at rest; needs stress monitoring (arg `13`, §5.5) on (`AMZ-M p.11`); 🟢 read and parsed on the Helio `HW:2026-09-30 (hw 0.132.27.2)` |
| HEALTH `08` | `32` | byte | **low SpO₂ alert** threshold | `00` = off, else % (Gadgetbridge: 80/85/90, `arrays.xml:3124-3129`) | 🟡 Amazfit: alerts when SpO₂ stays below the value for 10 min, not during sleep; needs all-day SpO₂ (arg `31`) on (`AMZ-M p.10`); 🟢 read and parsed on the Helio `HW:2026-09-30 (hw 0.132.27.2)` |
| HEALTH `08` | `41` | bool | **inactivity (sedentary) alert** | `00`/`01` | 🔴 not in Amazfit's Helio documents; a Helio user reported the sedentary reminder "not working" with Gadgetbridge (`GB#5799`, 2026-02-15). 🟢 read and parsed on the Helio `HW:2026-09-30 (hw 0.132.27.2)`; whether it buzzes is 🔴 |
| HEALTH `08` | `42` / `43` | hh:mm | inactivity alert active window start / end | u8 hour, u8 minute | 🟢 read and parsed on the Helio `HW:2026-09-30 (hw 0.132.27.2)` |
| HEALTH `08` | `44` | bool | inactivity alert quiet window enabled | `00`/`01` | 🟢 read and parsed on the Helio `HW:2026-09-30 (hw 0.132.27.2)` |
| HEALTH `08` | `45` / `46` | hh:mm | quiet window start / end | u8 hour, u8 minute | 🟢 read and parsed on the Helio `HW:2026-09-30 (hw 0.132.27.2)` |
| HEALTH `08` | `51` | bool | **goal-reached alert** | `00`/`01` | 🔴 not in Amazfit's Helio documents; 🟢 read and parsed on the Helio `HW:2026-09-30 (hw 0.132.27.2)`; whether it buzzes is 🔴 |
| HEALTH `08` | `52`–`57` | see note | goals: steps (`52`: short if the HEALTH version is 1, int otherwise), calories (`53`, short), weight (`54`: short below version 3, int from 3), sleep (`55`, short), standing time (`56`, short), fat-burn time (`57`, short) | LE | 🔴 (`SVC/Config:528-533,595-625`) |
| SOUND & VIBRATION `03` | `09` | bool | vibrate for alerts | `00`/`01` | 🟢 group `03` is **not** in the Helio's config capabilities (groups `00 0b 08 09 0a`, `HW:2026-09-30 (hw 0.132.27.2)`): unavailable |
| SOUND & VIBRATION `03` | `12` | byte | **vibration intensity** | `00` normal, `01` enhanced (`SVC/Config:1634-1637`) | 🟢 unavailable: no group `03` on the Helio (above) |
| SYSTEM `0a` | `0a` | byte | do-not-disturb mode | `00` off, `01` scheduled, `02` automatic, `03` always (`SVC/Config:1538-1543`) | group `0a` is listed on the Helio (🟢 `HW:2026-09-30 (hw 0.132.27.2)`); 🔴 whether this arg exists there, and whether it silences alarms or alerts |
| SYSTEM `0a` | `0b` / `0c` | hh:mm | DND schedule start / end | u8 hour, u8 minute | 🔴 |
| WORKOUT `09` | `41` | bool | workout-detection alert | `00`/`01` | group `09` is listed on the Helio (🟢 `HW:2026-09-30 (hw 0.132.27.2)`); 🔴 the arg and its meaning (probably a buzz when an auto-detected workout starts) |

Other args in group `03` (`02` volume, `06` crown vibration, `07` alert tone, `08` cover to mute,
`0a` text-to-speech) are watch features. Ignore them.

Group versions: Gadgetbridge understands SOUND & VIBRATION version `02`, SYSTEM `01`, WORKOUT
`01` and HEALTH `01`–`03`. It discards a read reply whose version differs (HEALTH excepted).
So the args above are only known at those versions. 🟡 `SVC/Config:319-327,390-402`.
Echo the version from the read reply when writing (§9).

**Haptics with no known config key** (Amazfit, `AMZ-M p.2-5`): power-on/off buzz, pairing
success/failure buzz, **low-battery buzz at 20 %, 10 % and 5 %**, firmware-update done/failed
buzz, and the workout pace/speed/high-HR alerts (configured per workout in the Zepp app). None
of them can be triggered or configured by OpenCircuit.

**Gadgetbridge behaviour not to copy:** on the first HEALTH read reply of each connection it
**writes the user's fitness goals** to the strap (`SVC/Config:356-360`). That is a persistent write
that the user didn't ask for.

Worked example H (constructed): read the four HR/SpO₂/stress alert args with constraints, then
set the high-HR alert to 120 bpm. `OC-vec`

```
→ 03 01 08 04 02 03 14 32                 read, constraints on, HEALTH, 4 args
← 04 01 08 03 01 04                        ok, HEALTH v3, constraints included, 4 entries
     02 10 00 07 00 64 6e 78 82 8c 96      high HR: byte, value 00 (off); 7 allowed: 0,100,110,120,130,140,150
     03 10 00 04 00 28 2d 32               low HR:  byte, value 00 (off); 4 allowed: 0,40,45,50
     14 0b 00                              relax reminder: bool, off (bools carry no constraints)
     32 10 5a 04 50 55 5a 00               low SpO₂: byte, value 0x5a = 90 %; 4 allowed: 80,85,90,0
→ 05 08 03 00 01 02 10 78                  write HEALTH v3 (echoed), 1 entry: arg 02, byte, 0x78 = 120
← 06 01                                    write ack
```

120 is in the allowed list, so the write is valid. A value outside the list must be refused on
the phone and never sent.

### 13.5 What is 🔴 unknown for the Helio specifically

- whether the 60 s limit is strap-side; whether `07` is sent; how long a 500 ms pulse actually buzzes (§11). (Answered: the version byte is 2, §11.2.)
- which pattern types the strap uses, and whether a test also stores (§13.1). (Answered: `0x0018` exists and is encrypted, §10.1.)
- whether the smart-wake bit and any snooze exist; what happens to a once-alarm after it fires; the alarm ack status values; the alarm capabilities reply (§12);
- which §13.4 args beyond the HEALTH alert args the strap reports (those read and parsed, and group `03` does not exist, §10.1), and whether the inactivity and goal alerts buzz at all;
- whether the strap can send find-phone `11` (§11.5);
- whether any command works before auth (§11.6).

---

## 14. Capability detection

**Rule: a control is shown only when the connected strap has positively reported support for
it in this connection. If support is absent, unknown or malformed, hide the control and never
send its commands.** Gadgetbridge is looser: it sends find device without checking the services
list (§11.1) and assumes 10 alarm slots.

| Feature | Show it only when | If absent |
|---|---|---|
| **Find device** | auth completed (§4) **and** the services list (§5.2) contains `0x001A` | hide; send nothing on `0x001A` |
| Continuous vs one-shot | capabilities reply `02 01 <v>` of exactly 3 bytes: v ≥ 2 → continuous | no well-formed reply → one-shot emulation (§11.4), still with the 60 s phone-side stop |
| **Buzz** (pulse, §13.2) | same as find device | hide |
| **Alarms** (view) | services list contains `0x000F` **and** a well-formed `0a` reply to `09` arrived in this connection (length, count ≤ 10, unique slots < 10) | hide the alarm screen. Never show "no alarms" when the list could not be read: that is a different statement |
| **Alarms** (edit) | the view condition, **and** the time has been set this connection (§5.1): alarms fire in strap-local time | read-only view |
| Smart wake toggle | 🔴 no capability known | don't offer it in v1; preserve the bit on alarms that already have it |
| **Vibration patterns** | services list contains `0x0018` | v1: **not exposed at all**, whatever the list says (no read-back, §15) |
| **Haptic alert settings** (§13.4) | the group is listed in the config capabilities reply (§5.5) **and** the arg is present in a read reply **with the expected type code**. Read with constraints on, and offer only the allowed values. | hide that one setting. Never write an arg the strap didn't report. Gadgetbridge does the same, `GB/devices/huami/zeppos/ZeppOsSettingsCustomizer.java:77-107`, `SVC/Config:1148` |
| Find phone (`11` from the strap) | always handled when `0x001A` is listed (answer `12 01`) | nothing |
| Notifications endpoint `0x001E` | never used for the strap (§13.3) | — |

Device gate: all of §11–§15 applies to a device identified as `Amazfit Helio Strap` (§1). The
Helio Ring shares the protocol, but Gadgetbridge routes it differently (§13.3). Keep the ring out
of scope until it is tested.

---

## 15. State safety

### 15.1 Persistent vs transient

| Command | Endpoint | Effect on strap state | Tag |
|---|---|---|---|
| find start `03` / stop `06`, pulse | `0x001A` | **transient**: stops within 60 s at most (phone-side rule, §11.4) | 🟡 |
| find-phone ack `12 01`, stop `14` | `0x001A` | transient | 🟡 |
| capabilities `01` (find, alarms, config); alarm read `09`; config read `03` | various | **read-only** | 🟡 |
| alarm create/replace `03 01 …` | `0x000F` | **persistent**: overwrites whatever the slot held, including an alarm the user made in Zepp | 🟡 |
| alarm delete `05 01 <slot>` | `0x000F` | **persistent and destructive** | 🟡 |
| alarm update `07` | `0x000F` | unknown: **never send** | 🔴 |
| vibration pattern set `03 …` | `0x0018` | **persistent, and cannot be read back**: the user's Zepp pattern is lost for good | 🟡 |
| vibration pattern test (test = `01`) | `0x0018` | 🔴 may also persist: treat as persistent | 🔴 |
| config write `05 …` | `0x000A` | **persistent**; can also change what the strap *records* (§5.5) | 🟡 |

**Never at session setup.** Connecting must not write alarms, patterns or config. Gadgetbridge
does all three on connect or on the first edit: it rewrites every one of its alarm slots
(creating or deleting each, `SVC/Alarms:120-182`), resets vibration patterns
(`SVC/VibrationPatterns:71-77`) and writes fitness goals (`SVC/Config:356-360`). OpenCircuit must
only write in response to an explicit user edit of that one item.

### 15.2 Alarm read-before-write sequence (🔴 recommendation, built from the facts above)

1. **Preconditions**: authenticated; `0x000F` in the services list; time set this connection
   (§5.1); no other alarm write in flight.
2. **Read**: send `09`, wait for `0a` (time out after a few seconds). Validate: length
   = 2 + 10 × count, count ≤ 10, every slot < 10 and unique. On failure: stop, write nothing,
   show "couldn't read alarms".
3. **Show the strap's list as the truth.** Keep no local alarm list that could be "synced" over it.
4. **User edits one alarm.** Build exactly one message for that slot:
   - new alarm → the **lowest free slot**; none free → refuse ("the strap already has 10 alarms");
   - change or enable/disable → `03 01` + the full record with only the edited fields changed,
     flags bits 0 and 2 as the user set them; unknown flag bits and bytes `[5..9]` written as `0`
     (the path Gadgetbridge has exercised);
   - delete → `05 01 <slot>`.
5. **Race check**: if a `0f` arrived after step 2, discard the edit's base, re-read (step 2) and
   ask the user to confirm again.
6. **Write, then wait for the ack** (`04` or `06`). Status other than `01`, or no ack → report
   failure; don't retry blindly.
7. **Re-read** (`09`) and confirm the slot holds what was written; display the re-read list.
8. Never touch a slot the user didn't edit; never write more than one alarm per user action.

### 15.3 Config write sequence (🔴 recommendation)

Read the group's args with constraints on (§13.4 example H) → validate the new value against the
allowed values or min/max → write **one** arg, echoing the group version from the read → expect
`06 01` → re-read the arg and show the strap's value.

### 15.4 Find device safety

- Always pair a start with a stop (§11.4): the user's stop button, the 60 s phone timer, and a
  stop on the next reconnect if the link dropped mid-find.
- No automatic find device or pulse at connect, sync or in the background without an explicit
  user action or setting. It is a physical interruption to the wearer.


---

## 16. What the strap sends on its own

This section and §17–§21 are the **parity addendum** (2026-10-01). §16 lists every message
the strap may send on an **authenticated, idle link**: after the §5 setup, with no fetch and no
command of ours in flight. It is written for the background-sync work (#233). New sources
here are `SVC/Workout` (endpoint `0x0019`), Gadgetbridge's Bluetooth-Classic transport, cited
only for contrast as `GB/service/devices/huami/zeppos/ZeppOsBtbrSupport.java`, and the legacy
(pre-Zepp OS) Huami device-event list `GB/service/devices/huami/HuamiDeviceEvent.java`.

### 16.1 What Gadgetbridge subscribes to, and when

| Characteristic | Subscribed | Carries | Tag / source |
|---|---|---|---|
| `…0017` chunked-read | **at connect, before auth, for the whole connection** | every chunked message from the strap, on every endpoint (§3) | 🟡 `BTLE:128-147`, `SUP:1069-1074,1131-1142,1167-1181` |
| `…0004` / `…0005` | around a history-fetch batch only, then disabled | fetch control and data (§6) | 🟡 `SUP:959-965`, `GB/service/devices/huami/HuamiFetcher.java:170-202` |
| `0x2A37` | only while live HR is on: the user's live-HR screen, a one-shot HR test, or a Sleep as Android session | live HR (§7.1) | 🟡 `SVC/HeartRate:112-149`, `SUP:731-740` |
| `…0002` raw sensor | only while raw-sensor streaming is on (a Sleep as Android feature) | accelerometer | 🟡 `SUP:998-1012` |
| `…0023` / `…0024` | only during a file transfer | files (not needed) | 🟡 `GB/service/devices/huami/zeppos/services/filetransfer/ZeppOsFileTransferImpl.java:118-119` |
| `…0016` chunked-write | **never**. Gadgetbridge has a handler for chunk acks arriving there (§3.4) but no code path enables notifications on it | — | 🟡 `SUP:1074-1076,1144-1156` (no `notify` call for it anywhere in the Zepp OS code) |
| `0x2A19` battery, `…0010` legacy device events | **never** | — | 🟡 (no subscription in the Zepp OS code) |

So on an idle Gadgetbridge link, the strap can reach the phone **only through chunked messages
on `…0017`** (plus `0x2A37` while live HR is on). Everything in §16.2 arrives that way.

At session setup (§5), only one of Gadgetbridge's service initialisers changes what the strap
sends unprompted: it **turns realtime steps off** (`05 00` on `0x0016`), because that stream stays
enabled across connections. 🟡 `SVC/Steps:53-57`. The others send requests (battery, config,
alarms, find-device capabilities) or write state (time, user info, vibration patterns, fitness
goals; §15.1), and none of them subscribes to anything.

### 16.2 Catalogue of unsolicited messages

"Queued" asks whether the strap holds the message while no phone is connected and delivers it
on the next connection. **Neither reference says so for any message**, and none of these
messages carries a timestamp, so a late delivery could not be told from a live one. Every
"queued" cell is therefore 🔴 unknown.

| # | Message | Endpoint (Helio encryption) | When the strap sends it | Needs | What Gadgetbridge does | Tag / source |
|---|---|---|---|---|---|---|
| 1 | **fell asleep** `06 01` | `0x001D` heart rate (plaintext) | 🔴 when the strap's own sleep detection decides you fell asleep. Latency, and whether naps (§21) also trigger it, are unknown | the `…0017` subscription. No known setting or subscription; 🔴 whether it depends on a HEALTH sleep switch (`0x11`, §5.5) | raises a "fell asleep" device event. That runs only the user's configured device actions (e.g. an Android broadcast) and **never starts a fetch** | 🟡 format `SVC/HeartRate:40-43,74-88`; event handling `GB/deviceevents/GBDeviceEventSleepStateDetection.java:53-89` (fetched from the pinned commit); 🔴 whether the Helio sends it at all |
| 2 | **woke up** `06 00` | `0x001D` (plaintext) | 🔴 as row 1, on waking | as row 1 | "woke up" device event, as row 1 | as row 1 |
| 3 | other `06 xx` | `0x001D` | — | — | logged as unexpected | 🟡 `SVC/HeartRate:84-86` |
| 4 | **live HR** (standard HRS frames) | `0x2A37` notification | about once a second, only after `04 01` on `0x001D` **and** while the phone keeps sending `04 02` (§7.1). 🔴 whether "Heart Rate Push" (a persistent setting, §5.5 arg `0x05`) makes the strap stream to any subscriber without `04 01` | the `0x2A37` subscription plus the 1 s keep-alive | if a frame arrives while Gadgetbridge did not ask for live HR, it sends `04 00` and unsubscribes (a fail-safe) | 🟢 1/s with the keep-alive `HW:2026-09-30 (hw 0.132.27.2)`; 🟡 `SVC/HeartRate:151-172` |
| 5 | **realtime steps** `07` + 13 bytes (steps = u16 LE at offset 1 of the 13) | `0x0016` steps (plaintext) | 🔴 on step changes, only while enabled | `05 01` on `0x0016`, which **persists across connections** (ack `06 <status> <enabled>`) | normally off: Gadgetbridge sends `05 00` at every connect and `05 01` only for its live-activity screen | 🟡 `SVC/Steps:36-40,53-57,73-80,98-110` |
| 6 | **battery** `04` + 20 bytes (§5.3) | `0x0029` (plaintext) | 🔴 **no unsolicited battery message is known**. Gadgetbridge only ever sees it as the reply to its `03` request at session setup; its handler would accept one at any time | — | updates the battery level and charging flag | 🟡 `SVC/Battery:46-70` |
| 7 | **charging / not worn** | — | **no message known.** The strap's own state shows up only in history: activity minutes of kind `0x76` (charging) and `0x73` (not worn), §6.5 | — | — | 🟡 (absent from both references); the legacy Huami bands had a device-event characteristic `…0010` with events "fell asleep" `01`, "woke up" `02` and "start non-wear" `06` (`GB/service/devices/huami/HuamiDeviceEvent.java:20-25`, `GB/devices/huami/HuamiService.java:52`), but the Zepp OS code never subscribes to it. 🔴 whether the Helio exposes `…0010` |
| 8 | **workout opened on the device** `20 <b1> <gps> <type> …` | `0x0019` workout (**encrypted**) | when a workout is opened on the device's own screen. Byte `[2]` = `01` if the workout needs GPS, byte `[3]` = the workout type code (§18.2); byte `[1]` is not read | — | if GPS is needed: sends a phone-GPS status, then locations while the user allows it (§18.5) | 🟡 `SVC/Workout:46,86-103,152-166`; 🔴 for the Helio, which has no screen (§18.1) |
| 9 | **workout started** `11 01` / **ended** `11 04` | `0x0019` (encrypted) | when a workout starts / ends | — | optional: starts / stops a recording in the OpenTracks app; on end, stops sending GPS | 🟡 `SVC/Workout:45-49,104-118,168-187`; 🔴 whether the Helio sends them for phone-started (§18) or auto-detected (§19) workouts; other status bytes are logged as unexpected |
| 10 | **alarms changed** `0f` | `0x000F` alarms (plaintext) | §12.5 | — | re-reads the alarm list | 🟡 §12.5 |
| 11 | **find stopped on the strap** `07`; **find phone** `11`, `13`, `15 <mode>` | `0x001A` (encrypted) | §11.3, §11.5 | — | §11.5 | 🟡 §11.3, §11.5 |
| 12 | **connection ping** `03` | `0x0015` connection (plaintext) | 🔴 "sometimes"; no interval is documented | — | answers `04` on the same endpoint | 🟡 `SVC/Connection:34-35,54-58` |
| 13 | **MTU announce** `02` + u16 LE (= MTU − 3) | `0x0015` (plaintext) | 🔴 unknown trigger | — | adopts the new MTU for its own chunking (if high MTU is allowed and the value is ≥ 23) | 🟡 `SVC/Connection:49-53`, `SUP:1113-1128` |
| 14 | config reply / ack `04 …` / `06 …` | `0x000A` (encrypted) | as replies only. 🔴 whether the strap pushes a `04` when a setting changes on its side (e.g. from the Zepp app) | — | stores whatever arrives; no special unsolicited handling | 🟡 `SVC/Config:124-146` |
| 15 | chunk ack `04 …` | `…0016` | §3.4 | an `…0016` subscription, which Gadgetbridge never makes (§16.1) | logged only | 🟡 §3.4 |
| 16 | **"new data available"** | — | **no such message exists in either reference.** No strap message makes Gadgetbridge fetch; every fetch starts on the phone. HelioCore fetches when its app opens. | — | — | 🟡 (absent from every Zepp OS service handler and from `HC:1115-1131`) |
| 17 | anything on an endpoint no reference knows | the Helio lists 12: `0x000C*`, `0x0022`, `0x0025`, `0x0028`, `0x0030*`, `0x0031`, `0x0032`, `0x0036*`, `0x0048`, `0x0049`, `0x004D*`, `0x0081*` (`*` = encrypted) | 🔴 | — | Gadgetbridge logs "unhandled" | 🟢 the list `HW:2026-09-30 (hw 0.132.27.2)`; 🟡 `SUP:1174-1180` |

Endpoints `0x0048` and `0x0049` coincide numerically with fetch types `0x48`/`0x49` (§6.5).
They are unrelated namespaces, like the characteristic/endpoint coincidence in §3.5.

### 16.3 Idle links: does the strap drop them, and how do the references keep them?

| Fact | Tag / source |
|---|---|
| **No reference documents an idle timeout for the BLE link.** | 🔴 (§10 item 22) |
| Gadgetbridge's BLE path sends **nothing periodic**: no keep-alive and no ping of its own. It only answers the strap's ping (row 12). | 🟡 `SVC/Connection:68-70` (`sendPing` is never called on the BLE path) |
| Gadgetbridge's **Bluetooth-Classic** transport (not usable on iOS) does keep its link alive: it writes a ping whenever 24 minutes have passed without a write, and notes that the strap's pong alone is not enough and that the official app re-requests data now and then. Evidence that Zepp OS devices can drop a silent link; 🔴 whether the BLE link behaves the same. | 🟡 `GB/service/devices/huami/zeppos/ZeppOsBtbrSupport.java:367-369,394-408` |
| Gadgetbridge re-establishes the BLE link with Android's **auto-connect** (the OS reconnects whenever the strap is in range). Every reconnect re-runs the whole setup: chunk encoder/decoder and fetcher reset, MTU back to 23, fresh auth (§4), services list, init (§5). | 🟡 `BTLE:115-118,128-147`, `SUP:292-305` |
| A Gadgetbridge contributor used a Helio Strap for about two weeks with Sleep as Android, where a running sleep session makes Gadgetbridge fetch SpO₂ (`0x25`) every 60 s. Sleep sessions normally run all night, so the Helio appears to tolerate a link held for hours with periodic traffic (🔴 inference: the report doesn't mention disconnects either way). | 🟡 `GB#6488` (2026-07-29) |
| HelioCore connects when its app opens and does nothing on a disconnect but update its UI: no reconnect, no keep-alive. | 🟡 `HC:644-720,1086-1088` |
| Amazfit asks the user to keep the device connected during a workout and says the end of a workout cannot reach the strap without the link (§18.4). It also documents "Heart rate push" to other devices (§7.1). Both need long-lived links. | 🟡 `AMZ-M p.4,10,12` |

**OpenCircuit mapping** (🔴 recommendation): the iOS equivalent of auto-connect is a pending
`connect(_:options:)`, which never times out, plus CoreBluetooth state restoration; that is what
the background-sync branch already does (`BACKGROUND_SYNC.md` §B.5 on `feat/helio-background`).
Re-run §4–§5 after every reconnect. Never reuse a session key, handle counter or sequence
number (§9).

### 16.4 Wake sources for a suspended iOS app

An iOS app with the `bluetooth-central` background mode is woken for **any notification on a
characteristic it subscribed to** while the link is up, and for a pending connect that
completes. That is Apple's CoreBluetooth behaviour, not something the references show. So
every row of §16.2 that arrives on `…0017` *would* wake the app. The question is whether the
strap sends it, and whether we must change a persistent strap setting to make it send.

| Message (§16.2 row) | Arrives without changing any persistent strap setting? | Reliable enough to schedule work on? | Verdict |
|---|---|---|---|
| sleep events `06 01` / `06 00` (1, 2) | **yes**: nothing is written to the strap; only the `…0017` subscription that every session already has | 🔴 not shown to be sent by the Helio; timing, nap behaviour and queuing unknown | **opportunistic hint only.** On `06 00`, schedule a short sleep fetch (`0x48` + activity). The night's session record may not exist yet (§21.4), so keep the per-type cursor and fetch again later. Never write a sleep sample to Health from the event itself: it carries no time |
| live HR `0x2A37` (4) | the stream itself needs `04 01` plus a `04 02` from the phone **every second**. That isn't a persistent setting, but a suspended app can't keep sending it. The "Heart Rate Push" route would need a persistent setting | n/a | **no** |
| realtime steps `07` (5) | **no**: needs `05 01`, which persists across connections | n/a | **no** (never send `05 01` in the background) |
| battery (6) | no unsolicited form known | — | **no** |
| charging / not worn (7) | no message known | — | **no** |
| workout `20` / `11 01` / `11 04` (8, 9) | yes, if sent at all | 🔴 unknown whether the Helio sends them | **no** (rare and unproven) |
| alarms changed `0f` (10), find `07`/`11` (11) | yes | rare, user-driven | **no** (handle them when they come) |
| connection ping `03` (12) | yes | 🔴 cadence unknown | **no**, but always answer `04` |
| MTU announce (13) | yes | rare | **no** |
| "new data available" (16) | does not exist | — | **no**: the strap never says it has data |

**Bottom line:** no strap message is a dependable wake source. Background sync must rest on
BGTasks and on the reconnect event (pending connect / restoration), and must fetch on a phone
schedule. Sleep events are worth handling as a hint once §10 item 23 shows that the Helio sends
them.

### 16.5 Handling rules (🔴 recommendation)

- Subscribe to `…0017` before auth (§2) and keep it for the whole connection. Don't subscribe to
  `…0016`, `0x2A19`, `…0010` or `0x2A37` for background work.
- Dispatch by endpoint, then by first byte. Handle rows 1–2 and 8–15 of §16.2. Answer a ping `03`
  on `0x0015` with `04`. On an MTU announce, chunk at the smaller of the announced size and
  `maximumWriteValueLength(for:)`.
- An unsolicited message must **never** trigger a write that changes strap state. The only
  replies allowed are the ping answer, the find-phone ack `12 01` (§11.5) and chunk acks (§3.4).
- If `0x2A37` frames arrive that we did not ask for, do what Gadgetbridge does: send `04 00` on
  `0x001D` and unsubscribe.
- Never send `05 01` on `0x0016`. If a session finds realtime steps flowing (row 5 arriving
  unasked), send `05 00` once: it only undoes a state someone else set and records nothing.
- Unknown endpoint or first byte: log the endpoint, the first byte and the length, **never the
  payload** (it may hold health data). Reply nothing.
- Timestamp every event on arrival, and treat it as "at or before now", never as "now": queuing
  is unknown.

---

## 17. Config writes (#228, #229, #230)

§5.5 gives the config transport and §15.3 a one-line write recommendation. This section makes the
write path complete: the message, the version echo, the ack, what a rejection may look like, the
re-read, validation against the strap's constraints, and the dependencies between settings.
Every write here is **persistent** (§15.1), and some change what the strap records (§5.5).

### 17.1 Channel and groups

| Fact | Tag / source |
|---|---|
| Endpoint `0x000A`, **encrypted** on the Helio (and by default). | 🟢 `HW:2026-09-30 (hw 0.132.27.2)`; 🟡 `SVC/Config:104,116` |
| The Helio's config capabilities list groups `00` AGPS, `0b` BLUETOOTH, `08` HEALTH, `09` WORKOUT and `0a` SYSTEM. There is no SOUND & VIBRATION group `03`. | 🟢 `HW:2026-09-30 (hw 0.132.27.2)` |
| Gadgetbridge sends the capabilities request at session setup, then **reads every listed group it knows**, with constraints, asking for the args it knows in that group. | 🟡 `SVC/Config:148-151,283-307,363-371` |
| A read with **arg count `00`** asks for every arg in the group. Gadgetbridge sends it only behind a debug switch, because the reply may contain types it can't parse. | 🟡 `SVC/Config:364-367` (this settles the 🔴 on "arg count `00`" in §5.5's read row) |
| Gadgetbridge offers a setting only if its arg came back in a read reply **with the expected type code**. So a strap that lacks an arg is expected to leave it out of the reply. 🔴 whether the strap omits it silently or answers with an error status. | 🟡 `SVC/Config:1147-1148`, `GB/devices/huami/zeppos/ZeppOsSettingsCustomizer.java:198-205` |

### 17.2 The write message

```
 +------+-------+---------+------+-------+--------------------------------------+
 | 0x05 | group | version | 0x00 | count | count × entry (arg, type, value) ... |
 +------+-------+---------+------+-------+--------------------------------------+
   [0]    [1]      [2]       [3]    [4]     [5..]
```

| Field | Meaning | Tag / source |
|---|---|---|
| `[0]` = `05` | write ("set") | 🟡 `SVC/Config:110,944` |
| `[1]` group | one group per message. To change args in two groups, send two messages. | 🟡 `SVC/Config:938-967` |
| `[2]` version | the group's version. Gadgetbridge puts its own constant here; OpenCircuit echoes the read reply (§17.3) | 🟡 `SVC/Config:946` |
| `[3]` = `00` | unexplained; always `00` | 🟡 `SVC/Config:947` |
| `[4]` count | number of entries that follow | 🟡 `SVC/Config:948` |
| entry | u8 arg code, u8 type code (§5.5), then the **value only**. A write never carries constraint bytes. | 🟡 `SVC/Config:949-954` |

**Value encodings in a write** (little-endian), as Gadgetbridge's setter builds them. 🟡
`SVC/Config:856-924`

| Type | Code | Bytes written |
|---|---|---|
| bool | `0b` | `00` or `01` |
| byte | `10` | 1 byte |
| byte list | `11` | u8 n, then n bytes |
| short | `01` | i16 |
| int | `03` | i32 |
| string | `20` | UTF-8, then `00` |
| string list | `21` | **one** UTF-8 string (the chosen value), then `00` |
| hh:mm | `30` | u8 hour, u8 minute |
| short list `02`, timestamp `40`, unbounded int `50` | — | Gadgetbridge has no setter for these: **never write them** |

Gadgetbridge sometimes puts several args of one group in one message (its fitness goals write
six HEALTH args at once, `SVC/Config:233-263`). OpenCircuit writes **one arg per message**: one
user action, one arg, one ack (§17.8).

### 17.3 Group-version echo

| Fact | Tag / source |
|---|---|
| Gadgetbridge always writes **its own constant** for the group (HEALTH `03`, WORKOUT `01`, SYSTEM `01`, BLUETOOTH `01`, AGPS `01`), never the version the strap reported. | 🟡 `SVC/Config:390-402,946` |
| Gadgetbridge drops a read reply whose version differs from its constant, except HEALTH, where any version ≤ 3 is accepted and remembered. Since it only offers settings it parsed, it writes a non-HEALTH group only when the strap's version equals its constant. For a HEALTH v1 or v2 strap it writes `03`. 🔴 whether such a strap accepts that. | 🟡 `SVC/Config:318-327`, §9 |
| Some **type codes depend on the group version**: the HEALTH steps goal (`52`) is a short at version 1 and an int from 2; the weight goal (`54`) is a short below 3 and an int from 3. | 🟡 `SVC/Config:595-625` |
| The Helio's HEALTH group is version **3**, so for HEALTH the echo and Gadgetbridge's constant agree. The Helio's WORKOUT, SYSTEM, BLUETOOTH and AGPS versions were not recorded. | 🟢 HEALTH `HW:2026-09-30 (hw 0.132.27.2)`; 🔴 the others (§10 item 25) |

**OpenCircuit rule** (🔴 recommendation, stricter than Gadgetbridge):
- Write byte `[2]` = the version from **the latest read reply for that group in this connection**.
  No read in this connection → read first.
- Write each entry's type code **as the read reply reported it for that arg**, never a hard-coded
  one. If it differs from the type this spec gives for the arg, the setting is unsupported.
- Write only to group versions whose args this spec describes: HEALTH 1–3, WORKOUT 1, SYSTEM 1.
  For any other version, show the value read-only.

### 17.4 The ack, and what a rejected write looks like

| Fact | Tag / source |
|---|---|
| The strap answers a write with `06 <status>`. Gadgetbridge **only logs** the status; it never checks it and never re-reads. | 🟡 `SVC/Config:111,131-133` |
| The ack carries no group and no arg, so it can only be matched to a write by order. | 🟡 (layout) |
| Status `01` = success. | 🔴 by analogy with every other Zepp OS ack in this document; never observed for config on the Helio (§10.1: nothing was written) |
| **A rejected write is not described by either reference.** Three outcomes are possible: (a) `06` with a status other than `01`; (b) no `06` at all; (c) `06 01`, but the re-read shows the old value. | 🔴 (§10 item 25) |
| A read reply with a status other than `01` is dropped by Gadgetbridge. | 🟡 `SVC/Config:135-139` |

**OpenCircuit rule** (🔴): allow **one config write in flight** on `0x000A`, and don't interleave
reads of other groups with it. Wait up to 5 s for `06`. Treat (a), (b) and (c) alike as
**"the strap did not take the change"**: show the strap's re-read value and an error, and never
retry by itself. A late `06` that arrives after the timeout is ignored.

### 17.5 Re-read

After the ack (or the timeout), read the same arg again with constraints:
`03 01 <group> 01 <arg>`. 🔴 recommendation; the read itself is 🟡 (§5.5).

- The entry is present, with the expected type, and holds the written value → success. Refresh
  the allowed values from the reply's constraints.
- It holds the old value → rejected (§17.4 c).
- It is missing, or its type changed → treat the setting as **unsupported for this connection**
  and hide it (§14).
- The reply's version differs from the version just written → stop writing to that group for this
  connection, and re-read the whole group.

### 17.6 Constraint validation

Read with constraints on (`03 01 …`). The constraint layouts are those of §5.5's type table, and
they sit after the value (§13.4). 🟡 `GB/service/devices/huami/zeppos/services/config/*.java`.
Gadgetbridge does **not** check a value against them when it writes. It only uses them to build
its pick lists and min/max fields (`SVC/Config:1246-1282,1302-1440`), so validation is
OpenCircuit's own rule (🔴):

| Type | Valid write | Notes |
|---|---|---|
| bool | `00` or `01` | no constraints are sent |
| byte | a member of the allowed list | an **empty** allowed list (n = 0) gives no basis for a value: don't write |
| byte list | every element a member of the allowed list; no duplicates | no count limit is sent; 🔴 whether the strap has one |
| short / int | min ≤ value ≤ max | |
| string | UTF-8 length ≤ max length, no `00` inside | 🔴 whether the max length counts the terminator: stay one byte under it |
| string list | one of the possible values (when the list is non-empty), length ≤ max | |
| hh:mm | hour 0–23, minute 0–59 | no constraints are sent |
| short list, timestamp, unbounded int | — | never written (§17.2) |

A value that fails these checks is refused on the phone and never sent (as in §13.4).

### 17.7 Dependencies between settings

| Child setting | Needs | Evidence | Tag |
|---|---|---|---|
| relax reminder HEALTH `14` | stress monitoring HEALTH `13` on | Amazfit: the relax reminder can be enabled only after automatic stress monitoring is on (`AMZ-M p.11`). Gadgetbridge greys out the relax switch while stress monitoring is off (`GB-res/xml/devicesettings_heartrate_sleep_alert_activity_stress_spo2.xml:94-108`) | 🟡 |
| low-SpO₂ alert HEALTH `32` | all-day SpO₂ HEALTH `31` on | Amazfit: the low-SpO₂ alert can be enabled only after automatic SpO₂ is on (`AMZ-M p.10`). Gadgetbridge greys out the threshold while all-day SpO₂ is off (same XML, `:116-132`) | 🟡 |
| high / low HR alerts HEALTH `02` / `03` | all-day HR at **1 minute or "smart"**, on Zepp OS devices with a display. Gadgetbridge treats a device **without** a display (the Helio) as measuring HR continuously and never greys the alerts out there | `GB/capabilities/HeartRateCapability.java:97-114,144-151`. Amazfit says the Helio measures HR continuously all day (`AMZ-M p.10`) | 🟡 |
| "activity monitoring" HEALTH `04` and the HR-alert switch | all-day HR not `00` (off) | `HeartRateCapability.java:136-143,161-168` | 🟡 |
| stress monitoring HEALTH `13` | on these newer devices, **not** on the HR interval | `HeartRateCapability.java:152-155,169-172` | 🟡 |
| sleep SpO₂ (fetch type `0x26`) | sleep breathing quality HEALTH `12` on | §5.5 | 🟡 |
| inactivity window and quiet window HEALTH `42`–`46` | inactivity alert HEALTH `41` on | grouped on one screen by Gadgetbridge, with no explicit dependency (`ZeppOsSettingsCustomizer.java:152-158`) | 🔴 |
| workout detection args WORKOUT `40` / `42` | workout detection on | §19 | 🔴 |

**What the strap does** when a child is set while its parent is off, or when a parent is turned
off under an enabled child, is in neither reference. Gadgetbridge's dependencies are UI-only: it
never writes the child when the parent changes, so the child keeps its stored value. 🔴 (§10 item
25 tests one case.)

**OpenCircuit rule** (🔴):
- Offer to enable a child only when the parent read **on** in this connection. Otherwise show it
  as unavailable, with the reason ("turn on stress monitoring first").
- Never write the parent as a side effect of a child edit. One user action, one arg.
- When the user turns a parent off, write only the parent. Show the child as inactive while
  keeping its stored value visible.

### 17.8 Write sequence (🔴 recommendation; replaces §15.3's one-liner)

1. **Preconditions**: authenticated; `0x000A` in the services list; the group listed in this
   connection's config capabilities; no other config traffic in flight. Don't write during a
   history fetch: there is no evidence of a conflict, but serialising costs little.
2. **Read** the arg, and every parent from §17.7, with constraints: `03 01 <group> <n> <args…>`.
3. **Validate**: the arg is present with the expected type code; the group version is known
   (§17.3); the new value passes §17.6; the dependencies of §17.7 hold. Any failure → don't send;
   say why.
4. **Write** one entry: `05 <group> <version as read> 00 01 <arg> <type as read> <value>`.
5. **Wait** for `06` (§17.4).
6. **Re-read** (§17.5) and show the strap's value as the truth.
7. **Log** the group, arg, old value, new value and the ack status. These are settings, not health
   data, but they are still personal: keep them on the device.

### 17.9 HEALTH arg `01`: the all-day HR interval byte

| Value | Meaning | Tag / source |
|---|---|---|
| `00` | off | 🟡 `SVC/Config:1508-1523`, `GB/capabilities/HeartRateCapability.java:42-53` |
| `ff` (−1) | "smart" (automatic) | same |
| `fe` (−2) | continuous | same (Gadgetbridge's interval list has it; written as the signed byte) |
| `01`–`78` | every N minutes, N = 1–120. Gadgetbridge offers 1, 5, 10, 15, 20, 30, 45 and 60 | same; `SUP:370-386` caps at 120 |

The strap's allowed list (constraints, §17.6) decides what is valid on a given strap. Gadgetbridge
**hides this setting for display-less devices**, the Helio included, because their HR is always on
(`ZeppOsSettingsCustomizer.java:266-280`, `GB#5796`, `GB#5804`). 🔴 whether the Helio reports arg
`01` at all and which values it allows (§10 item 25).

**Gadgetbridge pitfall (don't copy):** its interval-change handler converts seconds to minutes
with integer division and clamps at 0. "Continuous" (−2 s) therefore becomes `00`, which turns HR
monitoring **off**. 🟡 `SUP:370-386` with `HeartRateCapability.java:45,134`. Encode `fe`.

### 17.10 Worked example I: all-day HR every 10 minutes (constructed)

The strap's reply and its allowed list are invented for this example. `OC-vec` for the framing.

```
→ 03 01 08 01 01                              read, constraints on, HEALTH, 1 arg: 01
← 04 01 08 03 01 01                           ok, HEALTH v3, constraints included, 1 entry
     01 10 ff 09 00 ff fe 01 05 0a 0f 1e 3c   HR interval: byte, value ff (smart);
                                              9 allowed: off, smart, continuous, 1, 5, 10, 15, 30, 60 min
   check: 0x0a (10) is in the allowed list ✓; no dependency
→ 05 08 03 00 01 01 10 0a                     write HEALTH v3 (echoed), 1 entry: arg 01, byte, 10 min
← 06 01                                       ack, success
→ 03 01 08 01 01                              re-read
← 04 01 08 03 01 01 01 10 0a 09 00 ff fe 01 05 0a 0f 1e 3c     value 0a ✓
```

The write is encrypted on `0x000A`. Using the session of worked example C, with the connection's
7th message (handle `0x07`) and sequence number `0x2933d235`: `OC-vec`

| Step | Bytes |
|---|---|
| message key = session key XOR `0x07` | `8b 42 69 01 24 95 28 ac 74 c9 06 a7 ca da e9 f8` |
| `P ‖ S` | `05 08 03 00 01 01 10 0a` `35 d2 33 29` |
| CRC-32 over those 12 bytes | `0x6e18eeb8` → `b8 ee 18 6e` |
| padded plaintext (8 + 4 + 4 = 16: no padding) | `05 08 03 00 01 01 10 0a 35 d2 33 29 b8 ee 18 6e` |
| AES-128-ECB(message key) | `4f 4a df 2a 4a 15 fd 33 64 35 03 94 64 75 56 75` |
| next sequence number | `0x2933d236` |

```
MTU 247 (27 B): 03 0f 00 07 00 | 08 00 00 00 | 0a 00 | 4f 4a df 2a 4a 15 fd 33 64 35 03 94 64 75 56 75

MTU 23:  chunk 0 (20 B): 03 09 00 07 00 | 08 00 00 00 | 0a 00 | 4f 4a df 2a 4a 15 fd 33 64
         chunk 1 (12 B): 03 0e 00 07 01 | 35 03 94 64 75 56 75
```

### 17.11 Worked example J: all-day SpO₂ on, then the low-SpO₂ alert (constructed)

```
→ 03 01 08 02 31 32                     read HEALTH args 31 and 32 with constraints
← 04 01 08 03 01 02
     31 0b 00                           all-day SpO₂: bool, off
     32 10 00 04 00 50 55 5a            low-SpO₂ alert: byte, 00 (off); 4 allowed: off, 80, 85, 90 %
   the user asks for a 90 % alert → refused: needs arg 31 on (§17.7)
   the user turns all-day SpO₂ on:
→ 05 08 03 00 01 31 0b 01               write HEALTH v3, arg 31, bool, on
← 06 01
→ 03 01 08 02 31 32                     re-read the arg and its child
← 04 01 08 03 01 02 31 0b 01 32 10 00 04 00 50 55 5a
   now the 90 % alert may be offered, as a separate user action:
→ 05 08 03 00 01 32 10 5a               arg 32, byte, 0x5a = 90 (in the allowed list ✓)
← 06 01
```

### 17.12 Worked example K: the high-HR alert threshold (constructed)

This complements worked example H (§13.4), which set 120 bpm.

```
→ 03 01 08 01 02
← 04 01 08 03 01 01 02 10 78 07 00 64 6e 78 82 8c 96     high HR: 0x78 = 120; allowed off, 100–150 step 10
   the user picks 125 → refused on the phone: 0x7d is not in the allowed list; nothing is sent
   the user picks 130:
→ 05 08 03 00 01 02 10 82               arg 02, byte, 0x82 = 130 ✓
← 06 02                                 (a constructed non-01 status: §17.4 (a))
   → treated as rejected: re-read
→ 03 01 08 01 02
← 04 01 08 03 01 01 02 10 78 07 00 64 6e 78 82 8c 96     still 120 → show "the strap kept 120 bpm"
   to turn the alert off: 05 08 03 00 01 02 10 00
```

No dependency applies on the Helio (§17.7: display-less, HR always on). On a Zepp OS device with
a display, first check that HEALTH arg `01` reads `01` or `ff`.

---

## 18. Workouts (#227)

Scope: **controlling a workout from the phone** and what flows over the link while one runs. The
strap's own workout records (fetch types `0x05` summary and `0x06` detail, §6.5) exist but are
**out of scope** (#226 closed: OpenCircuit doesn't import the strap's workout data). This section
doesn't specify them.

### 18.1 How a Helio workout is controlled, and what is unknown

| Fact | Tag / source |
|---|---|
| The Helio has no screen or button, so **every workout is started from the Zepp app**: Workout › Start Workout › pick the sport › "Start". The app's sports page then pauses, resumes and (with a long press) ends it. | 🟡 `AMZ-M p.3-4`, `AMZ-S` |
| Amazfit says the strap supports "more than 27 sports modes", including running, walking, cycling, indoor sports and HYROX. | 🟡 `AMZ-M p.3` |
| A workout can also start **without** the phone, by automatic workout detection (§19). | 🟡 `AMZ-M p.5` |
| **Neither reference can start, pause, resume or end a workout from the phone.** Gadgetbridge's workout service only *reacts* to workouts the device starts on its own screen (`20`, `11 01`, `11 04`, §16.2 rows 8–9). It has no command in the other direction except phone GPS (§18.5). Its predecessor for pre-Zepp OS bands is the same. HelioCore has no workout code at all. | 🟡 `SVC/Workout:44-49,86-123`, `GB/service/devices/huami/HuamiSupport.java:1925-1945`; `HC` (no match for workout or sport) |
| Gadgetbridge's maintainer confirms this for the Helio: it reads VO₂ max only from workouts, and a Helio user can't start one without the Zepp app. | 🟡 `GB#5986` (comments of 2026-04-17) |
| So **the start, pause, resume and end commands are unknown** 🔴. The workout endpoint `0x0019` is encrypted on the Helio (§3.5), with a session key that needs one side's ECDH private key (§4.4). A passive capture of the Zepp app's traffic (a BLE sniffer or an Android HCI snoop log) therefore shows only ciphertext and **cannot reveal them**. | 🟢 encryption `HW:2026-09-30 (hw 0.132.27.2)`; 🔴 the commands |
| Gadgetbridge can upload **workout templates** (structured intervals with pace, cadence, HR, speed or stroke-rate alerts) as a file to a watch's sport app, through the file-transfer endpoint `0x000D`. The user then starts them on the watch's screen. The Helio lists `0x000D`. 🔴 whether it accepts templates at all; a template doesn't start a workout either way. | 🟡 `GB/service/devices/huami/zeppos/workouts/ZeppOsWorkoutTemplateUploader.kt`, `ZeppOsWorkoutCodes.kt:62-68`; 🟢 `0x000D` listed `HW:2026-09-30 (hw 0.132.27.2)` |

**Consequence for #227 (decision for Juan).** Starting the strap's own workout mode from
OpenCircuit can't be built from this spec, because the commands aren't in any source we may
read. Two routes exist:
1. **A phone-side workout** (buildable now, 🔴 recommendation): OpenCircuit runs the workout
   itself. Live HR comes from §7.1 at 1 Hz (🟢 on the Helio), with the phone's own location for
   outdoor sports, and the result is written to HealthKit as a workout. The strap stays in normal
   all-day mode. It records its usual per-minute activity, but makes no workout record, no
   strap-side training effect or VO₂ max, and no per-workout buzz alerts.
2. **The strap's workout mode**: needs a new source for the commands (§10 item 26 lists what can
   and can't be observed). Until then, §18.2–§18.6 give what is known around it.

### 18.2 Sport type codes

One byte, the same code space in the `20` message (§16.2 row 8), in the workout-detection
categories (§19) and in the strap's workout records. 🟡 `GB/service/devices/huami/zeppos/ZeppOsActivityType.java:24-150`
(125 codes; the names here are plain-English descriptions):

`01` outdoor running · `02` treadmill · `03` walking · `04` outdoor cycling · `05` free training ·
`06` pool swimming · `07` open-water swimming · `08` indoor cycling · `09` elliptical ·
`0a` outdoor cycling (a second code) · `0f` hiking · `11` tennis · `15` jump rope ·
`17` rowing machine · `18` indoor fitness · `28` indoor walking · `29` curling · `2c` ice skating ·
`2d` indoor ice skating · `30` BMX · `31` HIIT · `32` core training · `33` aerobic combo ·
`34` strength training · `35` stretching · `36` stair climber · `37` flexibility · `39` stepper ·
`3b` gymnastics · `3c` yoga · `3d` pilates · `40` fishing · `41` sailing · `42` rowing (on water) ·
`43` skateboarding · `45` roller skating · `46` rock climbing · `47` ballet · `48` belly dance ·
`49` square dance · `4a` street dance · `4b` ballroom dance · `4c` dance · `4d` zumba ·
`4e` cricket · `4f` baseball · `50` bowling · `51` squash · `55` basketball · `56` softball ·
`57` gateball · `58` volleyball · `59` table tennis · `5b` handball · `5c` badminton ·
`5d` archery · `5e` horse riding · `5f` kendo · `60` karate · `61` boxing · `62` judo ·
`63` wrestling · `64` tai chi · `65` muay thai · `66` taekwondo · `67` martial arts ·
`68` kickboxing · `6d` aerobics · `6f` mass gymnastics · `70` latin dance · `71` jazz dance ·
`72` cardio combat · `73` hula hoop · `74` frisbee · `75` darts · `76` kite flying ·
`77` tug of war · `7a` beach volleyball · `81` parkour · `82` cross training · `83` race walking ·
`84` driving · `8a` dragon boat · `8c` kayaking · `8f` spinning · `90` air walker · `91` wall ball ·
`92` folk dance · `93` jujitsu · `94` fencing · `95` horizontal bar · `96` parallel bars ·
`97` billiards · `98` sepak takraw · `99` dodgeball · `9a` water polo · `9b` finswimming ·
`9c` artistic swimming · `9d` snorkeling · `9e` ice hockey · `9f` swing · `a0` shuffleboard ·
`a1` table football · `a2` shuttlecock · `a3` motion-sensing game · `a4` futsal · `a5` hip hop ·
`a6` pole dance · `a7` battle rope · `a8` breaking · `a9` hacky sack · `aa` bocce · `ab` jai alai ·
`ac` flowriding · `ad` chess · `ae` checkers · `af` weiqi (go) · `b0` bridge · `b1` board game ·
`b8` bouldering · `b9` modern dance · `bc` floorball · `bd` esports · `bf` soccer · `ce` e-bike.

| Fact | Tag / source |
|---|---|
| **Which of these the Helio supports is not listed anywhere.** A Helio user's Zepp-started workouts included outdoor running, a "floor climbing machine" and yoga, and Gadgetbridge met an **unmapped code `0xdf`** in that sync: so the list above is incomplete for the Helio (HYROX and the climbing machine are plausible candidates for codes missing from it, 🔴). | 🟡 `GB#6218` (2026-05-31) |
| Treat an unknown code as "other workout"; never drop it. | 🔴 recommendation |
| **Pitfall:** pre-Zepp OS bands used a different status numbering on their workout characteristic (start `02`, pause `03`, resume `04`, end `05`, `GB/service/devices/huami/HuamiWorkoutStatus.java:20-23`). On Zepp OS `11 04` means **end**. Don't mix the two. | 🟡 |

### 18.3 What the link carries during a workout

| Flow | What is known | Tag / source |
|---|---|---|
| strap → phone, workout status | `11 01` started, `11 04` ended on `0x0019`, when the device runs the workout itself (§16.2 row 9). 🔴 whether the Helio sends them for a phone-started or auto-detected workout; no pause/resume status is known | 🟡 `SVC/Workout:45-49,104-118` |
| strap → phone, live values | The Zepp app shows and speaks live metrics (it announces "whole kilometers, pace, and heart rate") and switches itself to paused when "auto pause" detects a stop. So the strap streams *something* during a workout. **Its format is unknown.** | 🟡 `AMZ-M p.4`; 🔴 the format |
| live HR, independent of workouts | the §7.1 stream (`04 01`, then `04 02` every second) works whether or not a workout runs. That is all route 1 of §18.1 needs | 🟢 `HW:2026-09-30 (hw 0.132.27.2)` |
| strap's own record | the strap records the workout at about 1 Hz (an exported Zepp file shows one HR value per second) and keeps it for a later fetch (`0x05`/`0x06`, out of scope) | 🟡 `GB#5617` (comment of 2025-12-14) |

### 18.4 When the link drops mid-workout

| Fact | Tag / source |
|---|---|
| Amazfit tells the user to keep the device connected during the workout. It adds that the workout's detailed metrics are computed in real time **on the device**, so the link must be up **when the workout is ended**: "Otherwise, the device cannot be notified to end the workout." | 🟡 `AMZ-M p.4` |
| So a dropped link does **not** end the workout: the strap keeps recording until it is told to end. 🔴 whether it ends on its own after some time, or when its battery runs low. | 🟡 (inference from the above); 🔴 the timeout |
| Gadgetbridge has no handling: it reacts to `11 04` when (if) it arrives. | 🟡 `SVC/Workout:178-187` |

**OpenCircuit rule** (🔴 recommendation, for route 2): persist "a strap workout may be running"
across process deaths, like the find-stop flag of the background branch. On every reconnect while
it is set, ask the user whether to end the workout or keep it running. Never assume it ended.
Route 1 has no such state: the strap isn't in workout mode.

### 18.5 Must the phone send GPS or anything else?

| Fact | Tag / source |
|---|---|
| The Helio has no GPS of its own (no GPS feature or setting in Amazfit's documents). It does compute VO₂ max, which needs an **outdoor** run or cross-country run of at least 10 minutes and uses "heart rate and speed". So for outdoor sports the strap must get speed or position from the phone during the workout. | 🟡 `AMZ-M p.3-8`; 🔴 the inference about speed from the phone |
| The only phone → strap workout message in any reference is **phone GPS** on `0x0019`. Gadgetbridge sends it after a device-started workout announced that it needs GPS (`20` with byte `[2]` = `01`), and only if the user allowed it. | 🟡 `SVC/Workout:44,125-166` |
| Layout: `04`, `00` (unexplained), then a u32 LE **flags** word, then the optional parts in this order: bit `0x00000001` → a 1-byte **GPS status**: `01` acquired, `02` searching, `04` disabled; bit `0x00040000` → a 31-byte **position**. | 🟡 `SVC/Workout:140-150`, `GB/service/devices/huami/HuamiUtils.java:103-150`, `GB/service/devices/huami/HuamiPhoneGpsStatus.java:23-25` |
| Position (31 bytes, LE): i32 longitude × 3 000 000; i32 latitude × 3 000 000; i32 speed (Gadgetbridge writes whole m/s × 10, i.e. it truncates to whole m/s first; 🔴 the unit is probably 0.1 m/s); i32 altitude in cm; i64 fix time in Unix **milliseconds**; i32 `ff ff ff ff` (always); i16 `00 00` (🔴 perhaps bearing); u8 `00`. | 🟡 `HuamiUtils.java:130-147` |
| Gadgetbridge's sequence: on "needs GPS" it sends status **searching** (no position) and starts phone location at 1 s. It then sends each fix; the first fix after a gap of more than 5 s also carries status **acquired**. If phone GPS is disabled, it sends status **disabled** once. It stops location when the workout ends. | 🟡 `SVC/Workout:125-138,152-166,178-187` |
| 🔴 whether the Helio uses this message at all, and whether the Zepp app sends it (or speed only) for a Helio outdoor run. | 🔴 |

Nothing else is known to be required: the profile (§5.4, user info) feeds the strap's maths
(TE and VO₂ max use "personal information", `AMZ-M p.6-7`) and is already sent at setup.

### 18.6 Who computes the final metrics

The strap does. Amazfit says the detailed workout metrics, training effect, training load, recovery
time and VO₂ max are calculated by the device (`AMZ-M p.4-8`). The strap keeps its own record, and
the Zepp app syncs it. OpenCircuit doesn't fetch it (#226). With route 1 of §18.1, OpenCircuit
computes its own workout totals from the live HR and phone location, and must label them as its
own.

### 18.7 Per-workout alerts

| Alert | Who acts | Configured | Tag / source |
|---|---|---|---|
| **High heart rate**: the strap vibrates when HR exceeds the maximum set for this workout | strap | per workout, on the Zepp app's exercise preparation page; the settings vary by sport | 🟡 `AMZ-M p.4-5` |
| **Pace alert** and **speed reminder**: the strap vibrates when the speed is below the set minimum | strap | same | 🟡 `AMZ-M p.4-5` |
| voice announcements, metronome, auto-pause | **the app**, not the strap | same | 🟡 `AMZ-M p.4` |

🔴 **How these settings reach the strap is unknown**: probably inside the unknown start command, or
as a workout-group setting. The WORKOUT config group (`09`) args Gadgetbridge knows are GPS,
workout detection (§19), pool length and HR zones; none is a per-workout alert (`SVC/Config:541-552`).
For route 1, OpenCircuit can still buzz on its own HR limit with the find-device pulse (§13.2).
That fires only while the link is up and the app is running, and needs no persistent setting.

### 18.8 Worked example L: an outdoor run, as far as it can be constructed

What can be built today is route 1 (§18.1) plus, for reference, the phone-GPS message that a
strap-mode outdoor run would use. **No start command appears below, because none is known; no
bytes have been invented for it.** `OC-vec` for the GPS framing.

```
(route 1: phone-side outdoor run)
→ [0x001D] 04 01                     start live HR (§7.1); enable notify on 0x2A37 first
→ [0x001D] 04 02                     every second while the run lasts
← [0x2A37] 00 8f                     HRS frame, u8 HR = 143 bpm (made-up)
   … phone location from the phone's own GPS …
→ [0x001D] 04 00                     run ended: stop live HR, unsubscribe 0x2A37
   → write an HKWorkout (running, outdoor) with OpenCircuit's own totals

(route 2, for reference only: phone GPS to a strap that asked for it)
   START COMMAND: UNKNOWN (§10 item 26)
→ [0x0019] 04 00 01 00 00 00 02      flags 0x00000001 (status only), status 02 = searching
→ [0x0019] 04 00 01 00 04 00 01  18 74 56 ff  60 22 3a 07  1e 00 00 00  e8 fd 00 00
           c0 c0 5e f6 a0 01 00 00  ff ff ff ff  00 00  00
                                     flags 0x00040001 (status + position), status 01 = acquired;
                                     lon −3.703800° (−11 111 400), lat 40.416800° (121 250 400),
                                     speed 30 (3 m/s), altitude 65 000 cm,
                                     fix time 1 790 839 800 000 ms = 2026-10-01T07:30:00Z
← [0x0019] 11 01                     workout started (only if the Helio sends it, §18.3)
   END COMMAND: UNKNOWN
← [0x0019] 11 04                     workout ended
```

The 38-byte position message, encrypted on `0x0019` with the session of worked example C, as the
connection's 8th message (handle `0x08`), sequence number `0x2933d236`: `OC-vec`

| Step | Bytes |
|---|---|
| message key = session key XOR `0x08` | `84 4d 66 0e 2b 9a 27 a3 7b c6 09 a8 c5 d5 e6 f7` |
| CRC-32 over `P ‖ S` (`P` = the 38 bytes above, `S` = `36 d2 33 29`) | `0x3370b66e` → `6e b6 70 33` |
| padded plaintext (38 + 4 + 4 = 46 → 48) | `P`, `36 d2 33 29`, `6e b6 70 33`, `00 00` |
| AES-128-ECB(message key) | `88 54 5c 90 c5 6b 79 b8 aa bc 1a 6a 8b 74 d9 5c dd cd 04 84 ce c7 15 fe 8a 67 69 60 69 1d 29 89 5f 3d 07 75 38 ba bf 17 e5 01 a5 f5 c2 c4 39 30` |
| one chunk at MTU 247 (59 B) | `03 0f 00 08 00 26 00 00 00 19 00` + the 48 ciphertext bytes |
| next sequence number | `0x2933d237` |

---

## 19. Workout detection (#229)

Amazfit: with **Workout Detection** on (Zepp › Device › Helio Strap › Workout Detection), the
strap recognises activity "by continuously monitoring the high heart rate", so a workout no longer
needs to be started in the app. Its **sensitivity** is adjustable: higher detects faster, lower
takes longer. Amazfit warns that detection "will greatly reduce the battery life". 🟡 `AMZ-M p.5`

### 19.1 The WORKOUT group (`09`) args

All are written through §17 (endpoint `0x000A`, encrypted). Gadgetbridge knows WORKOUT **version
1** only (`SVC/Config:400`). The Helio lists group `09` (🟢 `HW:2026-09-30 (hw 0.132.27.2)`), but its
version wasn't recorded (🔴, §10 item 25).

| Arg | Type | Meaning | Values | Tag / source |
|---|---|---|---|---|
| `40` | byte list `11` | **detection categories**: the sports the strap may auto-detect | sport codes from §18.2. Gadgetbridge knows `03` walking, `28` indoor walking, `01` outdoor running, `02` treadmill, `04` outdoor cycling, `06` pool swimming, `09` elliptical, `17` rowing machine. The constraints' allowed list is the authority | 🟡 `SVC/Config:548,1302-1329,1617-1626` |
| **`41`** | bool `0b` | **detection alert**: Gadgetbridge's label is "Alert: notify when a workout is detected". On a watch that is an on-screen prompt; on the Helio 🔴 probably a buzz when detection starts a workout | `00` off, `01` on | 🟡 `SVC/Config:549`, `GB-res/xml/devicesettings_workout_detection.xml:21-27` (the label is in Gadgetbridge's `values/strings.xml:661-662`, fetched from the pinned commit) |
| `42` | byte `10` | **detection sensitivity** | `00` high, `01` standard, `02` low (only these three are mapped; the constraints decide what the strap accepts) | 🟡 `SVC/Config:550,1417-1418,1628-1632` |
| `05` | short list `02` | HR zones (6 bpm bounds; a watch reported count 6–6 and range 30–220) | Gadgetbridge parses it and never writes it | 🟡 `SVC/Config:552`, `GB/service/devices/huami/zeppos/services/config/ConfigShortList.java` |
| `20`–`23`, `30`, `31` | byte / bool / hh:mm | GPS and AGPS settings | watch features with no meaning on the Helio | 🟡 `SVC/Config:542-547` |
| `51` | byte | pool length | unexplained ("TODO") in Gadgetbridge | 🔴 `SVC/Config:551` |

### 19.2 What Gadgetbridge does on the Helio

| Fact | Tag / source |
|---|---|
| Since `GB@9c85d599` (2026-01-04, "Enable workout detection sensitivity for Helio Strap"), Gadgetbridge shows a workout-detection screen for the Helio with **only the alert (`41`) and the sensitivity (`42`)**. It deliberately hides the categories (`40`) for the strap. | 🟡 `GB/devices/huami/zeppos/straps/AmazfitHelioStrapCoordinator.java:52-65`, `GB/devices/huami/zeppos/ZeppOsCoordinator.java:464-480,659-665`, `GB/devices/huami/zeppos/ZeppOsSettingsCustomizer.java:207-214` |
| As for every config setting, each of the two is shown only if the strap's read reply contained it with the expected type (§17.1), so the Helio presumably reports `41` and `42` (🔴 until §10 item 25). | 🟡 `ZeppOsSettingsCustomizer.java:181-185,198-205` |
| **There is no detection on/off arg in Gadgetbridge.** Zepp's single "Workout Detection" switch therefore maps to something Gadgetbridge doesn't model: an empty category list (`40` with n = 0), or a WORKOUT arg it doesn't know. 🔴 (§10 item 27 decides) | 🟡 (absent from `SVC/Config:541-552`) |

### 19.3 Constraints and rules

- Read group `09` with constraints (§17.8 step 2). Offer only the args present with the type codes
  above. For `40` and `42`, offer only values in the reply's allowed lists (§17.6).
- **Detection on/off** (🔴 recommendation): don't offer a switch until §10 item 27 identifies the
  arg. Until then, show the alert and the sensitivity only, as Gadgetbridge does.
- Don't write `40` on the Helio, even if the strap reports it: Gadgetbridge hides it on purpose, and
  an incomplete list could silently turn detection off for a sport. Show it read-only.
- Detection costs battery (Amazfit). Say so next to the setting.
- An auto-detected workout probably makes the strap enter its workout mode (🔴 whether it sends
  `11 01`/`11 04`, §16.2 row 9, §10 item 26). OpenCircuit doesn't import the strap's workout
  records (#226), so detection only affects what the strap and the Zepp app record. The per-minute
  activity samples (§6.5) are recorded either way.

### 19.4 Worked example M: sensitivity to "standard", alert on (constructed)

The values and allowed lists are invented. The group version echoed is the one read (here 1).

```
→ 03 01 09 03 40 41 42                    read WORKOUT, constraints on, 3 args
← 04 01 09 01 01 02                       ok, WORKOUT v1, constraints included, 2 entries (no 40)
     41 0b 00                             detection alert: bool, off
     42 10 00 03 00 01 02                 sensitivity: byte, 00 (high); allowed high, standard, low
→ 05 09 01 00 01 42 10 01                 write WORKOUT v1, arg 42, byte, 01 = standard ✓
← 06 01
→ 05 09 01 00 01 41 0b 01                 a separate user action: alert on
← 06 01
→ 03 01 09 02 41 42                       re-read
← 04 01 09 01 01 02 41 0b 01 42 10 01 03 00 01 02
```

---

## 20. Strap alert events (#230)

The strap evaluates these alerts **on its own** and vibrates without the phone (§13.4):

| Alert | Fires when (Amazfit) | Configured by | Tag / source |
|---|---|---|---|
| high / low HR | HR above / below the limit for 10 consecutive minutes **at rest**, not during sleep | HEALTH `02` / `03` (§13.4, §17) | 🟡 `AMZ-M p.10` |
| low SpO₂ | SpO₂ below the value for 10 minutes in a row, not during sleep; needs all-day SpO₂ | HEALTH `32` (needs `31`) | 🟡 `AMZ-M p.10` |
| relax reminder | stress above the limit for 10 minutes in a quiet state, not during sleep; needs stress monitoring | HEALTH `14` (needs `13`) | 🟡 `AMZ-M p.11` |
| inactivity, goal reached | not in Amazfit's Helio documents | HEALTH `41`–`46`, `51` | 🔴 (§13.4) |
| workout high HR, pace, speed | during a workout only (§18.7) | per workout, unknown path | 🟡 `AMZ-M p.4-5` |
| low battery (20 %, 10 %, 5 %) | always | none | 🟡 `AMZ-M p.2` |

### 20.1 Does the strap tell the phone?

**No message is known for any of them.** 🔴 (§10 item 28)

| Evidence | Tag / source |
|---|---|
| No Zepp OS service in Gadgetbridge handles anything that could be an alert event. The only unsolicited messages it knows are those of §16.2. None of them names an alert, and none carries a threshold, a value or a time. | 🟡 `SVC/HeartRate:67-92`, `SVC/Config:124-146`, the rest of §16.2's sources |
| Asked by a Helio user whether it could send a phone notification when the strap's sedentary reminder fires, Gadgetbridge's maintainer answered "Unfortunately no, Gadgetbridge is currently not able to do this." | 🟡 `GB#5799` (comment of 2026-02-17) |
| The pre-Zepp OS device-event list (`…0010`) has no HR, SpO₂ or stress alert event either. Its events are fell asleep, woke up, goal reached `03`, non-wear, buttons, calls, alarms, find phone, silent mode, a 30-minute tick, MTU, workout and music control. | 🟡 `GB/service/devices/huami/HuamiDeviceEvent.java:20-37` |
| Amazfit describes every one of these alerts as "the device will alert/remind you" and mentions no phone notification. | 🟡 `AMZ-M p.10-11` |
| HelioCore has no alert code. | 🟡 `HC` (no match) |

The message format therefore can't be given. If the strap does send something, it would arrive as
a chunked message on `…0017` (§16.1), so the logging rule of §16.5 (endpoint, first byte and
length of anything unknown) is how it would be found.

### 20.2 What OpenCircuit can do instead (🔴 recommendation)

- **Don't promise "the strap told us".** The phone doesn't know when the strap buzzed.
- To show the user "your strap probably alerted you", **re-derive the condition from fetched
  history** with the strap's rule and the threshold read from config. For example: high-HR alert
  `02` = 120 and ten consecutive activity minutes (§6.5) with HR > 120, no sleep stage and low
  intensity. Label it as inferred. The same works for low SpO₂ (`0x25` samples) and stress
  (`0x13` minutes) with the thresholds above. Sleep exclusion uses §6.6 and §21.
- **Phone-side alerts** need no strap alert at all. While the link is up and live HR runs (§7.1),
  OpenCircuit can evaluate its own rule and buzz with the find-device pulse (§13.2). That's
  transient and persistent-setting-free, but only works while the app is running.

---

## 21. Naps (#231)

### 21.1 What Amazfit says

The Helio records **night sleep and naps**. Sleep that overlaps the user's **sleep plan** (set in
the Zepp app) is the day's **main sleep**; with no plan, the window is **00:00–08:00**. Sleep
**more than 60 minutes apart** from the main sleep is recorded as a **nap**. Sleep **shorter than
20 minutes** is not recorded. 🟡 `AMZ-M p.9`

### 21.2 What the references say

| Fact | Tag / source |
|---|---|
| **Neither reference mentions naps.** Gadgetbridge's Huami and Zepp OS code has no nap concept; HelioCore doesn't fetch sleep sessions (`0x48`) at all. | 🟡 `GB/devices/huami/HuamiSleepSessionSampleProvider.java` (whole file), `FOP/SleepSession:45-106`; `HC:908,1156-1163` (its fetch list has no `0x48`) |
| A `0x48` round may hold **several 594-byte records**. Gadgetbridge splits them and stores each one keyed by its own session timestamp (offset `0x000`), so any number of sessions per day fits its storage. | 🟡 `FOP/SleepSession:59-84` |
| Gadgetbridge overlays the stages of **every** session record in the requested window onto the activity minutes, the same way for each record. Nothing in the record is read as "nap" or "main sleep". | 🟡 `HuamiSleepSessionSampleProvider.java:70-95` |
| Nothing else about naps appears in either source: no nap fetch type in Gadgetbridge's list of types (§6.5), and no nap arg in its config groups. | 🟡 `GB/service/devices/huami/operations/fetch/HuamiFetchDataType.java`, `SVC/Config:467-577` |

### 21.3 How a nap probably appears (🔴 until §10 item 29)

- **As its own `0x48` record** (🔴 most likely): the record format holds one sleep span (start and
  end minutes, §6.6) with its own stages. A day with a nap would then deliver two records, possibly
  with the **same "midnight" reference** (`0x004`), because both belong to the same day.
- **Candidate flag bytes**: `0x008` and `0x009` are "both `01` in observed data, unexplained"
  (§6.6). A main-sleep / nap marker is one plausible meaning. 🔴 pure hypothesis: compare a nap
  record with a night record.
- **In the activity minutes** (`0x01`, §6.5): the per-minute sleep bytes and the "sleep" kind `0x78`
  carry no nap marker that any reference knows. A nap shows up there as sleep minutes in the
  daytime.
- The hardware run of 2026-09-30 got exactly one 594-byte record in a 12-hour window (§10.1). That
  says nothing about naps.
- **A later sleep of the same night** (🟡, one night, owner's strap, fw 3.25.0.3; decision 73): no
  second `0x48` record arrived for a sleep after a long mid-night awakening. That sleep was present
  only as kind-`0x78` activity minutes after the night's record ended (§6.5). Whether a daytime nap
  gets a record of its own is still open; if it doesn't, a nap too may exist only in the activity
  minutes.

### 21.4 When a session record exists, and re-fetching it

- Whether the strap writes a session record only after the session ends, or also while it is
  in progress, was 🔴 unknown for Zepp OS. For the Helio Strap it is also while it is in progress
  (🟢, observed below). On another vendor's band, Gadgetbridge has fetched an
  in-progress sleep file at 04:25 and never received the completed night. Its maintainer's fix
  idea was to stop marking such a file synced (`GB#6484`, Xiaomi, 2026-07-28 to 2026-08-26). Also, a nap can
  only be told apart from a main sleep once the main sleep is known (§21.1).
- Gadgetbridge's cursor for `0x48` moves past each round's last record (§6.4). A record the strap
  later **rewrites with the same session timestamp** would therefore never be fetched again.
  🔴 whether the strap ever does that.

**OpenCircuit rule** (🔴 recommendation):
- Keep acking `0x48` rounds with `09` (keep, §6.3). Start each sleep fetch from the start of the
  **latest session that ended less than 24 h ago**, not from after it: with `09`, overlapping data
  is re-delivered (🟢 for temperature, §6.3).
- Store sessions keyed by their session timestamp (`0x000`), and **replace** a stored session when a
  record with the same key arrives with different content.
- After a `06 00` wake event (§16.2), expect the night's record to be late or partial. Fetch again
  later.

**Observed: the Helio Strap exposes an in-progress `0x48` record** (🟢 own strap, 2026-10-05 and
2026-10-06; #274). On two mornings a sync read the night's sleep record while the sleep was still
going on: the record's end trailed the sync that read it by a few minutes, and the strap's wake
event (`06 00`) came hours later. A later sync delivered the same session again, ending at the real
wake. So a stored night's end is not proof that the night is over, and a record can grow between
fetches. OpenCircuit's rule (decision 58): the newest stored night reaches Apple Health from the
store only 3 h after its end, and a later copy that overlaps the written night and ends at least
10 min later replaces it.

How long a night keeps being re-delivered:
- The app asks for sleep sessions from the earlier of its own sleep cursor and the temperature cursor
  minus 24 h (`HelioFetchPlan.plan`). The sleep cursor is the last record's session timestamp plus
  one minute, on the assumption that the strap filters `0x48` by that timestamp; whether it compares
  `since` against it at all is 🔴 (above). A session timestamp is not the night's end: a record
  rewritten hours after the wake carries a later one.
- The temperature cursor is the last temperature minute fetched, held back to the later of the
  latest night's end and now minus 36 h (`HelioFetchPlan.temperatureCursor`). The strap records skin
  temperature only while asleep, so the cursor does not follow the clock (🟢 own strap, 25 device
  pulls: within a few minutes of the newest night's end in 21, later than it in 4).
- So the **last** night is re-delivered by every full sleep round until the next night's
  temperature minutes move the cursor (🟢: inside the window in all 25 pulls).
- The night before it is re-delivered only when its session record's timestamp falls at or after
  the temperature cursor minus 24 h (🟡: follows from the plan, and is not guaranteed).
- An older night is not re-delivered.
- Observed once (🟢 own strap, the first sync after installing the build with decision 58): the
  first full sleep round re-delivered both the last night and the night before it; each extended
  its short written copy once and was rewritten in Apple Health once, and nothing further followed.

### 21.5 Telling a nap from the night (🔴 recommendation)

Until §10 item 29 finds a marker in the record, apply Amazfit's rule on the phone:

1. Take every session of the local day, in strap-local time (§6.4).
2. The **main sleep** is the session that overlaps the sleep-plan window. OpenCircuit can't read
   Zepp's sleep plan (no known config arg), so use **00:00–08:00**, as the strap does without a
   plan, and let the user change it. If several overlap, take the longest.
3. Any other session that starts or ends **more than 60 minutes** from the main sleep is a **nap**.
   One within 60 minutes belongs to the main sleep (merge the two). OpenCircuit departs from this
   for one shape (decision 71, #278): two **overnight sleeps of one night** (each passes the
   overnight gate and ends in its key's wake window, and both file under the same night key) are
   one night whatever the gap between them, so a long awakening in the middle of the night
   (asleep 23:00–02:00, awake until 05:00, asleep 05:00–07:00) never splits the night into a night
   and a nap. The 60-minute rule still decides every other sleep (an evening doze, a daytime or
   late-morning sleep).
4. Drop sessions under 20 minutes. The strap shouldn't send them; if one arrives, it's a sign that
   the rule above is wrong. Log it.
5. HealthKit has no nap type: write a nap's stages as ordinary `sleepAnalysis` samples
   (`HEALTHKIT_MAPPING.md`, `0x48` row). Mark the nap as such only in OpenCircuit's own model,
   e.g. to keep it out of "last night".

### 21.6 Status in OpenCircuit (#231)

Implemented on the phone as §21.5 describes; still 🔴 until §10 item 29 checks it against a real
nap. `HelioSleepSelection.naps(from:mainSleeps:now:)` (ZeppKit) is the rule, and the app stores its
naps as `StoredNap` rows next to the ring's (`HelioStoreSink.storeNaps`). Where it goes beyond
§21.5:

- **Main sleeps**: the nights already stored, by either device, count as main sleeps. So after a
  morning switch from the ring, a strap sleep-in more than 60 min after the ring's night is a nap,
  and one within 60 min is part of that night (no nap, no strap night). A day whose 00:00–08:00
  window no stored night covers takes the longest strap sleep in that window as its main sleep, so a
  night that wasn't stored (in progress, or a failed save) never becomes a nap. The window is fixed:
  there is no setting for it yet.
- **Candidates**: only sleeps the app didn't take as a night. A sleep is a night or a nap, never
  both, and the nights are stored before the naps are judged.
- **Settling**: a nap is judged only once 60 min have passed since it ended, so a later session that
  would stitch onto it (28f) has had its chance. A night stored later still prunes an auto nap it
  overlaps, and a strap night also the strap's auto naps within 60 min of it (decision 76l, below).
- **One night, whatever the gap** (decision 71, #278): the stitch that runs before the nap split
  (`HelioSleepSelection.stitch`) also joins the overnight sleeps of one night key, judged on the
  night joined so far, as long as the joined night is no longer than 20 h. Neither part of such a
  night is a nap, and the awake gap between them stays a gap (no segment is written for it), except
  where decision 74 fills it (next item). Known
  gap kept: a first part that ends before midnight, more than 60 min before the rest, is no
  overnight sleep and is not joined. Second known gap (71h): a night an earlier build split as
  "earlier part = strap nap, later, longer part = the night already in Apple Health" stays split
  after the update, because the joined night ends where the written night ends and so doesn't
  extend it. Nothing is counted twice or lost, and the current stitch never makes that split.
- **A later sleep from the activity minutes** (decision 73, #278): sleep the strap marks only in its
  `0x01` minutes (kind `0x78`) outside every staged session (§6.5) becomes an activity sleep block,
  owned per block, and goes into the same stitch as the session sleeps. A block is kept only when
  that stitch joins it into a night holding a session record (28f's 60 min or the overnight join
  above). A block that stands alone (a daytime sleep, an evening doze, a night with no record) is
  never a night; it is counted (`activity blocks: joined=N alone=M` on the sleep-round diagnostics
  line) and, since decision 76, judged as a nap (next item). A block that may still be going on (its last sleep minute less than
  20 min before the sync's newest minute) is judged on the next sync. The temperature watermark, and
  with it the start of the activity re-fetch, stays at the end of the latest session night, so every
  sync sees each block after the record whole. **Only after the night's last record** (decisions
  73f, 73i): a block is used only when it starts at or after the in-bed end of the LAST session
  fragment of the night it would join. A block before a record (a lead-in) or between two records of
  one night (including one between an evening session and the night) is never joined and is counted
  alone. Later syncs fetch activity only from the last record's end, so a block written anywhere
  earlier would be deleted by the next extension's union delete. **A block never costs a night**
  (73g): a night holding blocks that fails the overnight gates (28c/28d) or is longer than 20 h,
  while its sessions alone make an overnight sleep, goes back to the sessions' own night, and its
  blocks are counted alone (a lie-in after the record that ends past noon, for one). Known gap
  (decision 73j, quoted): "73j (known gap, documented, not fixed; 🔴 shape). A block already written after a night's last fragment can still be deleted if the strap later delivers a NEW `0x48` record for that night that starts after the block, because the block is then no longer after the last fragment. This needs a second record for one night, which the owner's strap has not been seen to write (decision 73's preamble). The general guard, "an extension must hold every in-bed span already written" (review-73b option b), changes 58b for every strap night. It is a follow-up, not part of this build."
- **A nap from the activity minutes** (decision 76, #327): the strap writes one `0x48` record per
  night (decision 73) and none for a daytime nap, which it leaves only as kind-`0x78` minutes. Build
  88 diagnostics showed `naps: stored=0` with `alone=1` blocks on some syncs. A block that stands
  alone (`HelioSleepSelection.ActivityJoin.aloneNights`, owned per block) is now a nap candidate in
  the same `naps(from:mainSleeps:now:)` call as the session sleeps, unchanged: 20 min or longer,
  more than 60 min from every main sleep, and judged only 60 min after it ended. With the 20 min a
  block must wait before it is used at all (its last sleep minute 20 min before the sync's newest
  minute), a nap is stored by the first sync at least 60 min after it ended. A block within 60 min
  after the night's last record still joins the night (a sleep-in, not a nap). **The record
  decides** (decision 76l, review-327c): when a strap night is stored (`saveHelioNight`), every auto
  nap the strap owned all of whose window ends 60 min or less before the night's stored in-bed start,
  starts 60 min or less after its in-bed end, or overlaps it, is pruned (§21.5's "more than 60 min
  from every main sleep", applied after the fact). So whatever order the syncs ran in, once the
  night's record is stored no strap auto nap lies within 60 min of it. A ring night, a ring nap (time
  the ring owned), a nap the person added or edited, and a night saved by an edit never prune by
  nearness; overlap prunes as before for any device. What a pruned nap wrote to Apple Health is
  removed: inside the night by the night's own mirror (its union delete), outside it by the next nap
  flush (#327 S1/S2: the nap's written span, one second clear of every stored night and nap, this
  app's samples only; the span is kept until its delete succeeds and dropped 14 days after it ended).
  The prune is idempotent (decision 80b, #331 item 10): a nap's written span is scheduled only once
  the prune's delete is saved, and the prune also runs when a re-delivery of a strap night is kept out
  by the merge (`.keptFullerStoredNight`), judged on the STORED night's window and sleep, so a prune
  whose save failed is retried by the next re-delivery the merge judges (an edited night, a refused
  key collision and another device's night never retry). What the merge keeps is unchanged.
  **The hold** (decision 76j, now an optimisation that avoids a Health write followed by a delete): a
  nap candidate that holds a block is judged against the chain of sleep that follows it, built the
  way `stitch` builds a night: the sync's kind-sleep runs (up to 5 other minutes inside a run, the
  rule `activityBlocks` uses, `sleepRuns`) from the one that starts within 60 min after the nap's end,
  then each next run that starts within 60 min of the chain's end so far. The nap is held (counted
  `unsettled`) while the chain's last run may still be going on (its last sleep minute less than 20
  min before the sync's newest minute) or the chain ended less than 60 min before the newest minute.
  A nap with no run starting within 60 min after it is not held. **The remaining cost**: a nap within
  60 min of the coming night can still be stored, and written to Apple Health by the nap flush, by a
  sync that runs before the night's record arrives, once the doze has settled (60 min after its end)
  and the hold sees nothing after it: the sleep that follows starts more than 60 min after the doze
  or after a first fragment (an awakening over 60 min; a first fragment under 20 min is no block and
  doesn't join the doze), or it ended more than 60 min before the sync. The sync that delivers the
  record prunes that nap, and the next nap flush removes its Health write: the nap is written and
  removed again on the morning sync. Nothing is lost: the activity re-fetch starts at the last session
  night's end at the latest. Proved by sweeps through the app, a sync every 10 min to 07:00 with no
  record (and with the record delivered in progress from 23:00), then the morning's record: the
  reviewer's grid of 32 nights (doze 20/40/90 min, first fragment 5/15/19/25 min, awakening
  25/59/61/90/130 min, two dozes, records with an awake lead) for the 76l guarantee and Apple Health,
  and six nights for the hold. One that is the
  00:00–08:00 main sleep of a night no stored night covers is stored nowhere and counted
  (`mainOnlyBlocks=N`). The nap's segments are the block's own: one `.inBed` envelope, its sleep
  minutes as generic sleep, an awake gap of up to 5 min left a gap; no score. Every sync re-derives
  the nap from the minutes it fetched, and the activity re-fetch starts at the last night's end, so
  a nap after it is seen by every sync until the next night's record moves the watermark. A nap
  holding a block that a stored auto nap at its start already covers is left as stored (a
  re-derivation from fewer minutes never shrinks what Apple Health holds), and one whose start moved
  overlaps the stored nap and is not stored. Not recovered: a nap from before the last night's end.
  The diagnostics line gains `napsFromBlocks=N` and `mainOnlyBlocks=N` in its naps group, only when
  non-zero. 🔴 until §10 item 29 checks a real nap.
- **The awake time between fragments** (decision 74, #278): when the night is stored, each gap
  between two of its fragments is filled where the store holds the strap's own heart rate (its
  timeline, time it owns): those minutes are awake and in bed, merged into runs that bridge up to 5
  minutes without heart rate, each run one `.awake` and one `.inBed` segment
  (`HelioSleepSelection.awakeFilled`). Minutes without heart rate stay a gap, and nothing is filled
  before the first fragment or after the last. The fill comes from the stored rows, never a sync's
  fetched minutes, so every copy of the night carries the same fill; the sync's activity round,
  which stores the heart rate, runs before its sleep round, and a night whose gap heart rate is
  stored later gets the fill on its next re-delivery. Naps and the stitch never see the fill (it is
  added after both). The readers that judge sleep (temperature gate and verdict, overnight HRV) take
  the fragments' spans (`sleepSpans`), never a run.
- **The in-bed lead-in before the night** (decision 77, #328): the record's in-bed span starts at its
  own sleep start, about 5 minutes before the first stage, so time in bed read as almost no time
  before sleep. When the night is stored, after the stitch, the nap split and the awake fill, the app
  reaches back from the night's first in-bed start over the minutes where the store holds the strap's
  own rows showing the wearer lying in bed: a heart-rate sample in the minute (holes of 5 minutes or
  less bridged, as the fill does), fewer than 10 steps in the minute, and a heart rate no more than
  15 bpm above the night's sleeping level (the median heart rate of the first 60 min from the first
  sleep minute). It is at most 120 min long, and one under 5 min is not added. It never starts before
  the end of the latest sleep before it (a stored night or nap of either device, or one of the sync's
  own strap sleeps, a nap to be included) nor before the start of the strap's ownership (28). It is
  one `.awake` and one `.inBed` segment over the same span, before the first fragment: time in bed
  and awake time grow, asleep time doesn't, efficiency and the Sleep Score drop. **It is an estimate**,
  not the record's span. The constants are provisional and live in one place
  (`HelioInBedLeadIn`, ZeppKit); they are to be calibrated on a real store before they are trusted.
  - **Naps and nearness** (decision 77j, at the merge with #329): the lead-in stops at the end of every
    nap (stored, the sync's own session sleeps, and the sync's activity-block naps more than 60 min
    before the night's sleep), and a nap that runs into the night's in-bed start leaves it no room.
    Nearness is measured from the night's SLEEP, never its lead-in, on every path: the 60 min rule of
    the nap judgement, 76l's prune when the night is stored (its overlap test included) and `saveNap`'s
    overlap backstop. So a lead-in that ends at a nap's end never prunes it, and the nap or the night
    may be stored first, with one exception for a night already in Apple Health (next item). (A manual nap's add or edit, and the fences
    that keep a nap's Health delete off a stored night, still use the whole in-bed window, lead-in
    included: those are samples in Health.) Decision 80a (#331 item 7): the whole window stays the
    fence for deletes, but a strap nap whose moved re-detection only TOUCHES it (zero overlap: the
    lead-in starts where the nap ends) is rewritten, so the card's nap and Health agree; the clean of
    its old write still ends one second clear of the lead-in and the night's `inBed`. A nap that
    overlaps the lead-in by even one second is still not rewritten (its row is updated in place for
    the same start, or left as written for a moved start, and Health keeps the old write); one that
    overlaps the night's sleep is not stored at all (the backstop of 77j).
    A ring nap that touches a ring night is still not rewritten.
  - **A night stored before its nap** (decision 79e): a night stored BEFORE the sync that first sees a
    nap more than 60 min before its sleep onset was stored with a lead-in over that nap. The rule: while
    the night is NOT written to Apple Health, a re-delivery whose sleep window is the stored one's (within
    a second) and whose re-derived lead-in starts LATER than the stored one, or that has none, replaces
    the stored copy instead of the merge keeping the copy with more time in bed, whatever moved the
    lead-in start (a nap that now clamps it, 77c, or stored rows that changed since). The replacement is
    the re-delivered staging as it is, asleep minutes included, without the merge's completeness check;
    its sleep window is the same. So the lead-in then stops at the nap. Any other re-delivery (another
    sleep window, a lead-in starting as early or earlier) goes to the merge as before.
  - **Known limit, not fixed:** a night already WRITTEN to Apple Health keeps the lead-in it was written
    with (77f, forward-only; there is no rewrite path). The nap is stored (it is a real nap, §21.5),
    and the night's lead-in can lie over it by up to the clamp difference: 30 min for a nap ending 90
    min before onset, 59 min at 61 min, at most the 120 min cap. In Apple Health that is an `inBed`
    overlap and an `awake` sample over the nap's asleep one; asleep time is not counted twice. The card
    shows the night in bed from the lead-in start and the nap until its end. It converges only when the
    night comes back extended (58b). It is rare on the production fetch: a session nap comes with any
    later sync of the night (the sleep round re-fetches it), the activity fetch starts at or before the
    last session night's end, so a block nap comes in the same sync as the night, and a night reaches
    Apple Health only after the settle margin.
  - From the store, never a sync's fetched minutes, so every re-delivery derives the same lead-in
    (the 73f/73i/74b lesson), and the 50a hand-over and 50b backstop rebuild the night with the
    lead-in it was stored with.
  - Not sleep: `sleepSpans` (temperature gate and verdict, overnight HRV), the night score's heart
    rate and HRV, and the nap split's main sleeps (`storedNightWindows`) judge the night without it.
    The night key is unchanged (it is the day the night ends on), also for a lead-in across midnight.
  - Steps: the strap's step rows (`StoredStepSample`) carry no device column. They are the strap's by
    ownership (28): both step writers keep a row wholly inside time their device owns, and the lead-in
    never reads before the strap's ownership start.
  - Forward-only in Apple Health: a night already written is never rewritten for its lead-in. Written
    with the same lead-in, it passes as before; written without one (an earlier build, or before the
    heart rate was stored), the night goes on without a lead-in, exactly as before, so the card and
    Health agree; any other start-only difference is kept out (28f, 58b), store row included. A night
    not yet written is written once with it, and an extension (58b) takes it along.
  - Naps and the ring get none.
  - The lead-in can lie over minutes the strap marked as sleep in its activity minutes that the app
    did not keep (a standalone doze just before bed, decision 73c/73f); there it is labelled awake and
    in bed, never asleep.
  - Every reader that averages a night's vitals (the illness alert, Vitals Status, the Sleep card's
    overnight averages, Trends, the headache HRV and bedtime regularity) reads the night's sleep window,
    the in-bed window without the lead-in (decision 77h), so their baselines and alerts are as before.
    A night an earlier build wrote without a lead-in that later extends at the end (58b) takes its
    lead-in along in that one rewrite (77i); no start-only rewrite exists.
  - Only a STRAP night is read as having a lead-in (decision 79b): a stored row is the strap's when the
    strap owns its night under the ownership log (28a, the owner at its in-bed start; a lead-in never
    starts before the strap's ownership start). A ring night of the same shape reads whole, and with no
    switch on record (a ring-only install) every night does. No schema change.
  - A manually edited strap night (decision 79a): the edit rewrites the hypnogram but leaves the
    RECORDED in-bed columns frozen, lead-in included. Every reader of the recorded columns (the illness
    alert, Vitals Status, Trends' vitals averages, the nap judgement's main sleeps and `saveNap`'s
    overlap backstop) reads the recorded night without its recorded lead-in, decoded from the recording
    the edit never touches (`recordedHypnogramData`). The edited window is the person's own and is
    never trimmed: its readers (the Sleep card's overnight averages, the headache HRV and bedtime) read
    it as before.
  - Calories (decision 79c): Trends' active energy and exercise minutes leave out the night's whole
    in-bed window, lead-in included, as the dashboard, Goals, Wellness and the Health active-energy
    flushes do, so a day gives the same active kcal in Trends and on the dashboard. Trends' vitals
    averages keep the sleep window (77h).
- **Ownership**: a nap counts only when the strap owned all of it (no switch inside it).
- **Under 20 minutes**: not stored; a `helio-link` breadcrumb notes it (step 4).
- A stored strap nap within 60 min of a STRAP night stored later is removed by that night's store
  (decision 76l). One within 60 min of the RING's night (synced after the strap's nap, on a switch)
  is not: a ring night prunes by overlap only. Whether that ever happens on a real switch is open.

---

## Changelog

- 2026-09-30: first version (zepp-spec agent, #215 Phase 0). All claims 🟡/🔴.
- 2026-09-30: device-controls addendum (zepp-controls-spec agent, #215): §11 find device, §12
  alarms, §13 vibration and haptic alerts, §14 capability detection, §15 state safety; four
  endpoints added to §3.5; source aliases `GB-res/`, `GB#N`, `GB@sha`, `AMZ-S`, `AMZ-M`; capture
  items 13–21 in §10; worked examples E–H. Sections 1–10 are otherwise unchanged. All new
  claims are 🟡/🔴.
- 2026-09-30: first hardware run (§10.1, hw 0.132.27.2). The start reply's length unit is per
  type: records for activity, bytes for the other types seen (§6.2, §6.5). Both empty
  start-reply forms documented: length 0 is empty whatever the timestamp. Confirmed claims
  promoted to 🟢; `0x26`'s field layout demoted to 🔴 (zepp-fix agent, #215).
- 2026-09-30: device controls on the same strap (§10.1 items 13–21): find-device version 2,
  start/ack/stop and the 0.5 s buzz felt, alarm list and HEALTH alert args read and parsed, no
  config group `03`; the matching §11–§13 tags promoted to 🟢. Nothing was written (zepp-fix
  agent, #215).
- 2026-09-30: wording only (review-223 N3; helio-bg agent, #215 Phase 4): §5.5's intro keeps 🟢 for
  "`0x04` does not gate recording" and tags the sampling-rate meaning 🟡; §6.5's activity row says
  the CRC matches "like every type that has delivered data" (never observed for `0x02`, `0x12`,
  `0x3d`). No tag was promoted.
- 2026-10-01: parity addendum, part 1 (zepp-parity-spec agent, #233): §16, what the strap sends
  on its own, the subscriptions Gadgetbridge holds, idle links and iOS wake sources; endpoint
  `0x0019` added to §3.5; capture items 22–24 in §10. Existing sections are unchanged. All new
  claims are 🟡/🔴 except those already confirmed in §10.1.
- 2026-10-01: parity addendum, part 2 (zepp-parity-spec agent, #228 #229 #230): §17, config
  writes: message, version echo, ack, rejected writes, re-read, constraint validation, setting
  dependencies; worked examples I–K; capture item 25.
- 2026-10-01: parity addendum, part 3 (zepp-parity-spec agent, #227): §18, workout control:
  how Helio workouts are started (the phone-side commands are in no source we may read, so they
  stay unknown), sport type codes, the link during a workout and when it drops, phone GPS,
  per-workout alerts; worked example L; capture item 26. The workout record fetch types
  `0x05`/`0x06` stay out of scope (#226).
- 2026-10-01: parity addendum, part 4 (zepp-parity-spec agent, #229): §19, workout detection:
  the WORKOUT group args (`40` categories, `41` detection alert, `42` sensitivity), what
  Gadgetbridge exposes for the Helio, the missing on/off arg; worked example M; capture item 27.
- 2026-10-01: parity addendum, part 5 (zepp-parity-spec agent, #230): §20, strap alert events:
  no message is known for any strap-side alert; how to infer them from history instead; capture
  item 28.
- 2026-10-01: parity addendum, part 6 (zepp-parity-spec agent, #231): §21, naps: Amazfit's nap
  rule, what the references say (nothing), how a nap probably appears in `0x48`, re-fetching
  sessions, the phone-side nap rule; capture item 29.
- 2026-10-03: §21.6, what the app implements of §21.5 for strap naps (#231). No tag was promoted.
- 2026-10-18: §21.5 step 3 and §21.6: OpenCircuit joins the overnight sleeps of one night whatever the gap
  (decision 71, #278); the 60-min rule stays for every other sleep; the 71h known gap. No tag was
  promoted.
- 2026-10-18: §6.5, §21.3 and §21.6: one night on the owner's strap (fw 3.25.0.3) had no second
  `0x48` record for a sleep after a long awakening; that sleep was present only as kind-`0x78`
  activity minutes (🟡). OpenCircuit joins such minutes to a night that has a record (decision 73,
  #278); standalone ones are not stored.
- 2026-10-18: §21.6: the awake time between a night's fragments is awake and in bed where the strap's
  own heart rate is stored (decision 74, #278); unworn minutes stay a gap. No tag was promoted.
- 2026-10-26: §21.6: a strap nap that only touches its night's in-bed window is rewritten when it
  moves (decision 80a), and the 76l prune is idempotent and retried on a kept-out re-delivery
  (decision 80b; #331 items 7 and 10). No tag was promoted.
