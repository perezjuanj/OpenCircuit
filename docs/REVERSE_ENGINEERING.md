# Reverse-engineering workflow

The goal: turn captured RingConn-app ↔ ring traffic into entries in
[`PROTOCOL.md`](PROTOCOL.md). Two complementary tracks — **passive capture** of the
real app, and **active probing** with the workbench.

## Track A — Passive capture (do this first)

The official app already speaks the protocol. Record it and read along.

### Android HCI snoop log (recommended, no extra hardware)
1. On an Android phone with the RingConn app paired:
   Settings → Developer options → **Enable Bluetooth HCI snoop log**.
2. Toggle Bluetooth off/on so logging starts cleanly.
3. In the RingConn app, perform **one isolated action** and note the wall-clock
   time: e.g. open app (handshake), take a manual HR reading, take an SpO2 reading,
   trigger a sleep sync. Do them one at a time, separated by ~30 s of idle.
4. Pull the log:
   ```
   adb bugreport bugreport.zip      # contains btsnoop_hci.log, or:
   adb pull /data/misc/bluetooth/logs/btsnoop_hci.log
   ```
5. Drop it in `desktop/captures/` and run:
   ```
   python -m opencircuit decode-log captures/btsnoop_hci.log --addr <ring-mac>
   ```
   This prints, per ATT operation: timestamp, direction, handle, and hex payload —
   filtered to the ring. Cross-reference timestamps with the action you performed.

You can also open the same file in **Wireshark** (`btatt` filter) for a GUI view.

### iOS capture
iOS has no on-device HCI log. Options: a macOS + iPhone **PacketLogger** capture
(Additional Tools for Xcode), or an external sniffer (below).

### In-app frame capture (iOS, no Mac/sniffer needed)
For a tester who only runs the iOS app (e.g. a new ring generation that connects but
whose overnight sleep/HRV/RR won't decode — the Gen 2 `0x4c` layout is firmware-pinned),
a **Debug build** exposes **Device Info ▸ Diagnostics (debug)**:
1. Toggle **Capture history frames** on.
2. Wear the ring overnight, then open the app / sync in the morning. Captured frames are
   persisted per-ring, so a **background** overnight drain is kept too.
3. Tap **Share capture** → send us the `.txt`. It carries the ring's firmware/generation
   plus every raw `0x47`/`0x4c`/`0x50`/`0x82`/`0x10` frame (hex) for offline decoding.

The section is compiled out of Release builds (`#if DEBUG`) and is OFF by default. The file
includes overnight HR/HRV/SpO₂ bytes — treat it as personal data.

### External sniffer (most reliable, needs hardware)
A **Nordic nRF52840 dongle + nRF Sniffer for BLE** plugin for Wireshark captures
the live link regardless of phone OS. Best for catching the connection handshake
and encrypted-vs-plaintext determination.

## Track B — Active probing (workbench)

> ⚠️ **The Mac can only handshake, not pull data** (🟢 live test, PROTOCOL.md §0).
> The ring gates `0x02`/`0x07`/`0x95` data commands behind an LE **bond**. An unbonded
> CoreBluetooth/bleak central gets `0x01`→`0x81` replies but the ring silently drops
> every data command, and bleak can't pair on macOS (`pair()` → NotImplementedError).
> So `scan`/`enumerate`/`listen` work for the handshake, but `replay` of a sync/fetch
> sees nothing. **For any real data, capture the bonded phone (Track A).**

Once you can see the app's traffic, reproduce it yourself:

```
python -m opencircuit scan            # enumerate services/characteristics/handles
python -m opencircuit listen          # subscribe to notify char, log everything live
python -m opencircuit replay --hex "950095" --handle 0x0802   # send a command
```

Loop: copy a write you saw the app make → `replay` it → watch `listen` for the
response → record in `PROTOCOL.md`.

## Decoding tips

- **Find the framing before the fields.** Capture several frames of the same type
  and diff them — fixed bytes are header/command-id, varying tail is often a CRC.
- **Checksums:** `opencircuit guess-checksum` brute-forces common CRC-8/16/32
  params (incl. openwhoop's Whoop poly `0x4C11DB7`) against a frame.
- **Timestamps:** history records usually carry an epoch or minutes-since-midnight.
  Capture at a known time and look for a 4-byte field near `now`.
- **Is it encrypted?** If notification payloads for the *same* action differ wildly
  every session and have no stable header, suspect link-layer or app-layer
  encryption — check the sniffer for an LL `ENC_REQ`/pairing, and look for a key
  exchange in the first packets. RingConn's "encrypted" marketing is about
  app↔cloud; the BLE link may still be plaintext. Confirm, don't assume.
- **One variable at a time.** Take two HR readings 10 bpm apart and diff the
  payloads to locate the HR byte.

## Track C — App-logic RE (Flutter / Dart AOT) — how the auth was cracked

When the protocol isn't decodable from the wire alone (e.g. a keyed auth), reverse the official
app's logic. The RingConn app is **Flutter**, so its logic lives in `lib/arm64-v8a/libapp.so`
(Dart AOT snapshot) — **not** Java; jadx/apktool are useless. This is how the per-connection auth
(`SM3([mac[3]^mac[4]^mac[5], challenge])[-3:]`, PROTOCOL §5.8 / issue #54) was recovered:

1. **Pull the APK splits:** `adb shell pm path com.gdjztech.ringconn` → `adb pull` the base +
   `split_config.arm64_v8a.apk` (the Dart code is in the **arm64 split**), or grab an XAPK/bundle.
2. **Decompile the Dart AOT with blutter** (`github.com/worawit/blutter`; needs `brew install cmake
   ninja capstone pkg-config` + a JDK). It auto-detects the Dart version, builds the matching VM,
   and emits `asm/*.dart` (annotated ARM64), `pp.txt` (object pool), `objs.txt`, a Frida script.
   ⚠️ **blutter can't parse a too-new Dart** — it SIGSEGV/SIGBUS'd on the current app's Dart 3.10.7.
   **Workaround that worked:** RE an **older app version** (v3.2.1 = Dart 3.5.4) from APKMirror/
   APKPure — wire protocols/algorithms are stable across app versions. Check first:
   `strings libflutter.so | grep 'stable'`.
3. **blutter sometimes omits a layer** (it dropped the BLE opcode-dispatch here). Fall back to
   **capstone**: disassemble `libapp.so`, find the opcode-dispatch `cmp #0x81` cluster + the handler
   it calls, read the arithmetic. (The Dart class names like `BleAuthRspMixin` survive as strings.)
4. **VERIFY — never guess** (no-fabrication rule): reproduce the algorithm against ground-truth
   (challenge,response) pairs harvested from btsnoop + a known-answer test for any standard primitive
   (e.g. `SM3("abc")`). Don't claim a crack until **every** captured pair matches. Cheap pre-checks
   first: `desktop/find_table.py` (lookup-table by spacing), `crack_f.py` (keyless/keyed hash/CRC
   brute), `scan_smp.py` (SMP/bonding — confirm there's **no cloud key**, just a local ECDH LTK).
5. **iOS gotcha:** CoreBluetooth hides the BLE MAC — read it from the DIS **System ID** char `0x2a23`.

## Safety

`captures/` is gitignored — these logs contain your real health data and device
identifiers. Don't commit or share raw captures; only commit decoded *findings*.
