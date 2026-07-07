"""Known RingConn Gen 2 BLE constants.

Everything here is OBSERVED. Items tagged 🟢 are reproduced from a real btsnoop
capture (FW FR02.018, see docs/PROTOCOL.md); 🟡/🔴 still need confirming. Update
this file and docs/PROTOCOL.md together.

Sources: capture FR02.018 (2026-06-13); Gadgetbridge issue #4506.
"""

# Primary data service + characteristics (🟢 confirmed by scan on FR02.018).
# Value handle = characteristic declaration handle + 1.
DATA_SERVICE = "8327ad99-2d87-4a22-a8ce-6dd7971c0437"      # handle 0x0800
NOTIFY_CHAR = "8327ad97-2d87-4a22-a8ce-6dd7971c0437"       # value handle 0x0804
WRITE_CHAR = "8327ad98-2d87-4a22-a8ce-6dd7971c0437"        # value handle 0x0802

# Secondary service (🔴 role unknown — likely OTA/bulk). NOTE: GB #4506 mislabeled
# these two as services; scan shows they are *characteristics* inside this service.
SECONDARY_SERVICE = "1d14d6ee-fd63-4fa1-bfa4-8f47b42119f0"  # handle 0x0900
SECONDARY_CHAR_A = "f7bf3564-fb6d-4e53-88a4-5e37e0326063"   # 0x0901 write
SECONDARY_CHAR_B = "984227f3-34fc-4045-a5d0-2c581f81a153"   # 0x0903 write[-no-resp]

# ATT handles (🟢 confirmed from capture). The app drives the ring almost entirely
# through this notify/command pair, NOT discrete per-metric characteristics.
HANDLE_NOTIFY = 0x0804         # all responses + live + bulk data arrive here
HANDLE_WRITE = 0x0802          # all commands are written here
HANDLE_NOTIFY_CCCD = 0x0805    # enable notifications with `01 00`

# Back-compat aliases for the earlier (mis-scoped) GB #4506 names.
HANDLE_LIVE_HR_NOTIFY = HANDLE_NOTIFY
HANDLE_KEEPALIVE_WRITE = HANDLE_WRITE

# Frame opcodes (🟢). Response id = command id XOR RESP_FLAG.
RESP_FLAG = 0x80
CMD_POLL = 0x95          # live-sample poll/keepalive  -> 0x15
CMD_FETCH_RECORD = 0x07  # next history record header  -> 0x87
CMD_PAGE_47 = 0xC7       # page ACK / continue bulk    -> 0x47
CMD_PAGE_4C = 0xCC       # page ACK / continue bulk    -> 0x4C

# The live poll the official app writes between samples (🟢, from capture).
# NOTE: commands are NOT XOR-checksummed (unlike responses) — the real bytes are
# `95 00 00`, not the GB #4506-guessed `95 00 95`. Each poll yields one 0x15 frame.
KEEPALIVE_PAYLOAD = bytes.fromhex("950000")

# Exact command sequence the app sends to start the live-HR stream (🟢, capture
# idx 224-229): set live-HR mode, then begin streaming. Poll with KEEPALIVE_PAYLOAD
# afterwards. Sent verbatim — do not append a checksum.
LIVE_HR_START_SEQ = [bytes.fromhex("060100"), bytes.fromhex("070000")]

# Sync-cursor epoch: seconds since 2019-12-31 12:00:00 UTC (🟢 confirmed, PROTOCOL
# §5.6). The 0x02 open-session command carries a 4-byte BE cursor in this space.
SYNC_EPOCH = 1577793600
SYNC_ALL = bytes.fromhex("0200ffffffff000100")  # "everything pending"


def sync_cursor_cmd(unix_seconds: float, channel: int = 0x00) -> bytes:
    """Build `02 00 <cursor BE4> <channel> 01 00` to sync `channel` since unix_seconds.

    `channel` is the byte[6] history-channel selector (🟢 §5.6.1): 0x00 = sleep,
    0x03 = all-day are the only two the official app ever sends. `probe-channels`
    sweeps the rest to hunt the still-uncaptured activity/step/stress/temp streams
    (#9/#93/#94). Default 0x00 keeps every existing caller byte-identical.
    """
    import struct
    cursor = max(0, int(unix_seconds) - SYNC_EPOCH)
    return bytes([0x02, 0x00]) + struct.pack(">I", cursor) + bytes([channel, 0x01, 0x00])

# Name prefixes to match while scanning (🟢 — observed "RingConn Gen2-<MAC suffix>").
NAME_PREFIXES = ("RingConn", "Ring")
