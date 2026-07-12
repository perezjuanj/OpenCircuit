#!/usr/bin/env bash
# Monitor OpenCircuit ring logs from a connected iPhone.
#
# MODES:
#   monitor.sh [--save]              Live terminal stream via --console (shows [OC] lines)
#   monitor.sh --record [--time N]   xctrace full OS-log capture to .trace (default 8h)
#   monitor.sh --show <file.trace>   Filter a captured .trace in the terminal
#   monitor.sh --show-last           Filter the most recent .trace in build/logs/
#
# The live "--console" mode shows the [OC] print() lines added at key sync events:
#   [OC] sync START ch=sleep|all-day     → drain opened on that channel
#   [OC] sync DRAIN ch=X added=N        → N>0 means new epochs; 0 means ring was empty
#   [OC] sync FINALIZE records=N ...    → complete; check sleepSegs and sleepOutcome
#   [OC] sleep COMMITTED coarse=N staged=N  → night saved to archive ✓
#   [OC] healthKit WROTE samples=N ...  → data written to Apple Health ✓
#   [OC] healthKit flush: nothing new … → either already written or not yet authorized
#
# Full unified-log detail (ringLog.notice lines) is only visible in:
#   • Xcode's console pane while the app is run from Xcode
#   • --record mode → open .trace in Instruments.app → select "os log" table
#   • `log stream --predicate '...'` on macOS 14/15 (removed in macOS 26)

set -euo pipefail

BUNDLE_ID="com.standardsoftwaresolutions.opencircuit"
SAVE=false
RECORD=false
RECORD_DURATION="8h"
SHOW_FILE=""
SHOW_LAST=false
DEVICE_ID=""

usage() {
    echo "Usage:"
    echo "  $0 [--save] [--device <id>]              Live stream ([OC] print lines)"
    echo "  $0 --record [--time <dur>] [--device <id>]  xctrace capture to .trace (default 8h)"
    echo "  $0 --show <file.trace>                    Show a captured .trace"
    echo "  $0 --show-last                            Show the most recent .trace"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --save)      SAVE=true; shift ;;
        --record)    RECORD=true; shift ;;
        --time)      RECORD_DURATION="$2"; shift 2 ;;
        --device)    DEVICE_ID="$2"; shift 2 ;;
        --show)      SHOW_FILE="$2"; shift 2 ;;
        --show-last) SHOW_LAST=true; shift ;;
        -h|--help)   usage ;;
        *)           echo "Unknown option: $1"; usage ;;
    esac
done

LOG_DIR="$(cd "$(dirname "$0")/.." && pwd)/build/logs"
mkdir -p "$LOG_DIR"

# ── device detection ──────────────────────────────────────────────────────────
if [[ -z "$DEVICE_ID" ]] && [[ "$SHOW_LAST" == false ]] && [[ -z "$SHOW_FILE" ]]; then
    DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
        | awk '/connected.*physical/ {print $NF; exit}')
    if [[ -z "$DEVICE_ID" ]]; then
        echo "ERROR: no connected physical device found. Plug in the iPhone."
        exit 1
    fi
    echo "Device: $DEVICE_ID"
fi

# ── --show / --show-last: filter a .trace file ────────────────────────────────
if $SHOW_LAST; then
    SHOW_FILE=$(ls -t "$LOG_DIR"/*.trace 2>/dev/null | head -1)
    if [[ -z "$SHOW_FILE" ]]; then
        echo "No .trace files in $LOG_DIR. Run: $0 --record first."
        exit 1
    fi
fi

if [[ -n "$SHOW_FILE" ]]; then
    echo "Reading: $SHOW_FILE"
    echo "(Open in Instruments.app for the full interactive view)"
    echo "------------------------------------------------------------"
    # Try to export the os-log table from the trace
    xcrun xctrace export \
        --input "$SHOW_FILE" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-log"]' \
        --output - 2>/dev/null \
        | grep -o '"[^"]*com\.standardsoftwaresolutions\.opencircuit[^"]*"' \
        | sed 's/^"//; s/"$//' \
        || {
            echo ""
            echo "No filterable os-log data found in the schema above."
            echo "Open the .trace in Instruments.app (File → Open) and select the Console pane."
        }
    exit 0
fi

# ── --record: overnight xctrace capture ──────────────────────────────────────
if $RECORD; then
    TRACE_FILE="$LOG_DIR/ring-$(date +%Y%m%d-%H%M%S).trace"
    echo "Recording OS log from device to: $TRACE_FILE"
    echo "Duration cap: $RECORD_DURATION  (Ctrl-C to stop early)"
    echo ""
    echo "When done, view with:"
    echo "  $0 --show-last"
    echo "  open \"$TRACE_FILE\"   (Instruments.app)"
    echo "------------------------------------------------------------"

    xcrun xctrace record \
        --template "Logging" \
        --device "$DEVICE_ID" \
        --all-processes \
        --time-limit "$RECORD_DURATION" \
        --output "$TRACE_FILE"

    echo ""
    echo "Saved: $TRACE_FILE"
    echo "Run:   $0 --show-last"
    exit 0
fi

# ── live stream mode (default) ────────────────────────────────────────────────
# Launches the app with --console so its stdout (print statements) streams here.
# Unified-log (ringLog.notice) output does NOT appear here — use --record for that.
echo "Launching OpenCircuit with console bridging…"
echo "Showing [OC] print lines (key sync events). Press Ctrl-C to stop."
echo "------------------------------------------------------------"

LAUNCH_ARGS=(
    --device "$DEVICE_ID"
    --console
    --terminate-existing
    "$BUNDLE_ID"
)

if $SAVE; then
    LOGFILE="$LOG_DIR/ring-stdout-$(date +%Y%m%d-%H%M%S).log"
    echo "Saving to: $LOGFILE"
    xcrun devicectl device process launch "${LAUNCH_ARGS[@]}" 2>&1 \
        | grep --line-buffered "\[OC\]" \
        | tee "$LOGFILE"
else
    xcrun devicectl device process launch "${LAUNCH_ARGS[@]}" 2>&1 \
        | grep --line-buffered "\[OC\]"
fi
