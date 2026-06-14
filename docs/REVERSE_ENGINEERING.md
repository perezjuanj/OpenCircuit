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
   python -m openringconn decode-log captures/btsnoop_hci.log --addr <ring-mac>
   ```
   This prints, per ATT operation: timestamp, direction, handle, and hex payload —
   filtered to the ring. Cross-reference timestamps with the action you performed.

You can also open the same file in **Wireshark** (`btatt` filter) for a GUI view.

### iOS capture
iOS has no on-device HCI log. Options: a macOS + iPhone **PacketLogger** capture
(Additional Tools for Xcode), or an external sniffer (below).

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
python -m openringconn scan            # enumerate services/characteristics/handles
python -m openringconn listen          # subscribe to notify char, log everything live
python -m openringconn replay --hex "950095" --handle 0x0802   # send a command
```

Loop: copy a write you saw the app make → `replay` it → watch `listen` for the
response → record in `PROTOCOL.md`.

## Decoding tips

- **Find the framing before the fields.** Capture several frames of the same type
  and diff them — fixed bytes are header/command-id, varying tail is often a CRC.
- **Checksums:** `openringconn guess-checksum` brute-forces common CRC-8/16/32
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

## Safety

`captures/` is gitignored — these logs contain your real health data and device
identifiers. Don't commit or share raw captures; only commit decoded *findings*.
