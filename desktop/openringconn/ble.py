"""Known RingConn Gen 2 BLE constants.

Everything here is OBSERVED, not vendor-documented, and may be wrong. Confidence
notes mirror docs/PROTOCOL.md. Update both together when you learn more.

Sources: Gadgetbridge issue #4506.
"""

# Characteristics (🟡 probable)
NOTIFY_CHAR = "8327ad97-2d87-4a22-a8ce-6dd7971c0437"
WRITE_CHAR = "8327ad98-2d87-4a22-a8ce-6dd7971c0437"

# Services seen in scans (🔴 unverified roles)
SERVICE_A = "f7bf3564-fb6d-4e53-88a4-5e37e0326063"
SERVICE_B = "984227f3-34fc-4045-a5d0-2c581f81a153"

# Raw ATT handles seen in captures (🟡). Handle-based access may be needed because
# the device is reported as not fully GATT-compatible.
HANDLE_LIVE_HR_NOTIFY = 0x0804
HANDLE_KEEPALIVE_WRITE = 0x0802

# The live-HR keepalive the official app writes between measurements (🟡).
KEEPALIVE_PAYLOAD = bytes.fromhex("950095")

# Name prefixes to match while scanning (🔴 — confirm and tighten).
NAME_PREFIXES = ("RingConn", "Ring")
