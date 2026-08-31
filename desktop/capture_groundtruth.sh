#!/usr/bin/env bash
# One-command ground-truth capture session.
#
#   ./desktop/capture_groundtruth.sh
#
# Starts mitmproxy with the auto-saving hypnogram addon and prints the exact phone
# settings for THIS machine's current IP. Every night you open in the RingConn app
# lands in desktop/captures/ by itself — you never touch the mitmweb UI.
#
# Ctrl-C when done; it prints a summary of what was captured (and a diagnosis if
# nothing was).
#
# Full plan: docs/RUNBOOK_GROUNDTRUTH_TONIGHT.md

set -euo pipefail

PORT="${OC_PROXY_PORT:-8080}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDON="$REPO/desktop/mitm_sleep_capture.py"
OUT="$REPO/desktop/captures"
export OC_CAPTURE_DIR="$OUT"
export OC_TZ="${OC_TZ:-America/New_York}"

command -v mitmdump >/dev/null || { echo "mitmdump not found — brew install mitmproxy"; exit 1; }
mkdir -p "$OUT"

IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
[ -n "$IP" ] || { echo "Could not determine this Mac's Wi-Fi IP. Are you on Wi-Fi?"; exit 1; }

cat <<EOF

╔══════════════════════════════════════════════════════════════════════╗
║  RingConn hypnogram capture — ground truth for sleep staging         ║
╚══════════════════════════════════════════════════════════════════════╝

ON THE PHONE — Settings → Wi-Fi → (your network) → ⚙ → Proxy → Manual
        Hostname : $IP
        Port     : $PORT

CERT (first time only) — phone browser → http://mitm.it → download Android cert
        → Settings → Security → Encryption & credentials
        → Install a certificate → CA certificate

TEST FIRST: load any https:// site on the phone. If nothing scrolls by below,
the proxy is not wired up — fix that before opening RingConn.

⚠️  DO NOT SYNC THE RING IN THE RINGCONN APP.
    Reading history is free. Syncing drains the ring and moves its single
    resume pointer, which is how we have shredded our own nights before.

THEN: open RingConn → tap into Sleep detail for each night. One tap per night.
      Each hypnogram saves itself and prints a ✅ line here.

PRIORITY NIGHTS (we already hold your raw ring bytes for these 14):
   2026-06-26  06-27  06-28  06-29  06-30      07-03  07-04
   2026-08-04  08-05  08-09  08-12  08-13      08-15  08-19 ← most valuable

Saving to: $OUT
Timezone  : $OC_TZ    (override with OC_TZ=...)

Press Ctrl-C when you have tapped through every night you can see.
──────────────────────────────────────────────────────────────────────

EOF

# NOTE: do NOT add -q. It sets the log level to `error`, which suppresses the addon's own
# `✅ SAVED` lines (they are emitted at warning level) — you would sit watching a silent
# terminal while nights captured invisibly. `warn` hides the per-flow noise and keeps them.
exec mitmdump -s "$ADDON" --listen-port "$PORT" --set termlog_verbosity=warn
