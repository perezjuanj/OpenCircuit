"""calibration_session.py — Guided BP calibration capture for the Healthops BP pipeline.

Starts the ring PPG capture, then walks you through simultaneous Apple Watch ECG +
cuff BP readings with exact timing cues.  Saves a calibration JSON that links the
PPG CSV, per-reading wall-clock timestamps, and your BP numbers so Stage 3 can
align all three signals.

Usage:
    .venv/bin/python calibration_session.py <ring-uuid> rest
    .venv/bin/python calibration_session.py <ring-uuid> exercise   # right after 2-min walk
    .venv/bin/python calibration_session.py <ring-uuid> morning    # within 10 min of waking

Get your ring UUID:
    .venv/bin/python -m opencircuit scan

Run all 3 states across 2 days for initial baseline (~9 calibration points).
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import subprocess
import sys
import threading
import time

# ── Per-state timings ────────────────────────────────────────────────────────
SETTLE_S = {"rest": 120, "exercise": 25, "morning": 60}
MEASURE_S = 70       # long enough for AW ECG (30s) + BP machine (45-60s)
REST_BETWEEN_S = 90  # rest between readings
NUM_READINGS = 3


# ── Terminal helpers ─────────────────────────────────────────────────────────

def beep(n: int = 1) -> None:
    for _ in range(n):
        os.system("afplay /System/Library/Sounds/Glass.aiff 2>/dev/null")
        time.sleep(0.35)


def countdown(label: str, total: int) -> None:
    for remaining in range(total, 0, -1):
        filled = int(24 * (total - remaining) / total)
        bar = "█" * filled + "░" * (24 - filled)
        m, s = divmod(remaining, 60)
        print(f"\r  {label}: [{bar}] {m:02d}:{s:02d} ", end="", flush=True)
        time.sleep(1)
    print(f"\r  {label}: [{'█' * 24}] 00:00 ✓            ")


def banner(title: str, lines: list[str]) -> None:
    width = max(len(title), max(len(l) for l in lines)) + 4
    print()
    print(f"  ┌{'─' * width}┐")
    print(f"  │  {title.center(width - 2)}  │")
    print(f"  ├{'─' * width}┤")
    for line in lines:
        print(f"  │  {line:<{width - 2}}  │")
    print(f"  └{'─' * width}┘")
    print()


# ── Main session ─────────────────────────────────────────────────────────────

def run(ring_uuid: str, state: str) -> None:
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    ppg_csv = f"ppg_calibration_{state}_{ts}.csv"
    cal_json = f"calibration_{state}_{ts}.json"
    ppg_log  = f"ppg_calibration_{state}_{ts}.log"

    settle_s = SETTLE_S[state]
    # Total PPG capture duration: settle + readings + rests + 2-min buffer
    total_s = settle_s + NUM_READINGS * (MEASURE_S + REST_BETWEEN_S) + 120

    script_dir = os.path.dirname(os.path.abspath(__file__))
    capture_py = os.path.join(script_dir, "capture_ppg.py")

    banner(
        f"BP Calibration — {state.upper()}",
        [
            f"PPG file : {ppg_csv}",
            f"Cal file : {cal_json}",
            f"Duration : ~{total_s // 60} min",
            f"Readings : {NUM_READINGS} (each: ECG 30s + BP machine simultaneously)",
        ],
    )

    # ── Start PPG capture subprocess ─────────────────────────────────────────
    # Use subprocess.PIPE (not a file) so we read output as a live stream.
    # File-redirect buffering is 8 KB, meaning prints don't appear until the
    # buffer fills — which causes the "waiting forever" hang.  PIPE + -u gives
    # us each line as soon as capture_ppg.py flushes it.
    proc = subprocess.Popen(
        [sys.executable, "-u", capture_py,
         ring_uuid, "--duration", str(total_s), "--output", ppg_csv],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        cwd=script_dir,
        text=True,
        bufsize=1,   # line-buffered on our end
    )

    # Read subprocess output line-by-line in a background thread.
    # Writes everything to the log file, prints key status lines to the terminal.
    agc_ready = threading.Event()

    def pipe_reader() -> None:
        try:
            with open(ppg_log, "w") as log_f:
                for line in proc.stdout:          # blocks per line, no busy-spin
                    log_f.write(line)
                    log_f.flush()
                    kws = ["Connecting", "Connected.", "Auth OK", "PPG mode",
                           "AGC settled", "AGC not settled", "Re-entering PPG",
                           "OPTICAL", "IR DEAD", "BLE error", "GAP"]
                    if any(kw in line for kw in kws):
                        print(f"\n  [ring] {line.rstrip()}", flush=True)
                    if "AGC settled" in line or "AGC not settled" in line:
                        agc_ready.set()
        except Exception:
            agc_ready.set()   # unblock main thread if reader crashes

    watcher = threading.Thread(target=pipe_reader, daemon=True)
    watcher.start()

    print("  Waiting for ring to connect (keep ring close to Mac)...\n")
    agc_ready.wait(timeout=90)

    if not agc_ready.is_set():
        print("\n  WARNING: Ring didn't confirm AGC in 90s — continuing anyway.")
    else:
        print()

    # ── Settle period ─────────────────────────────────────────────────────────
    settle_msgs = {
        "rest":     ["Sit still. Breathe normally. No talking or moving.",
                     "Arms resting on the table. Both hands relaxed."],
        "exercise": ["Sit down now.", f"First reading in {settle_s}s while BP is still elevated."],
        "morning":  ["Sit comfortably. Don't drink coffee yet.",
                     "Breathe normally."],
    }
    banner(f"Settling {settle_s}s — do not move", settle_msgs[state])
    countdown("Settling", settle_s)

    # ── Readings ──────────────────────────────────────────────────────────────
    readings: list[dict] = []

    for i in range(NUM_READINGS):
        rnum = i + 1
        banner(
            f"READING {rnum} of {NUM_READINGS}",
            [
                ">>> APPLE WATCH: Tap the ECG app. Place right finger on Crown.",
                ">>> BP MACHINE:  Press START at the same time.",
                "",
                "Keep BOTH arms flat on the table. Stay completely still.",
            ],
        )
        beep(3)

        start_wall = time.time()
        countdown(f"Reading {rnum}", MEASURE_S)
        end_wall = time.time()

        beep(1)
        print("\n  ECG recording done. Read the BP numbers from your machine.\n")

        try:
            sbp_s = input("  SBP — top number   (e.g. 118): ").strip()
            dbp_s = input("  DBP — bottom number (e.g. 75):  ").strip()
            sbp = int(sbp_s) if sbp_s.isdigit() else None
            dbp = int(dbp_s) if dbp_s.isdigit() else None
        except (EOFError, KeyboardInterrupt):
            sbp, dbp = None, None

        readings.append({
            "reading_num": rnum,
            "start_wall_s": start_wall,
            "end_wall_s": end_wall,
            "sbp_mmhg": sbp,
            "dbp_mmhg": dbp,
        })

        if sbp and dbp:
            print(f"\n  ✓ Saved: {sbp} / {dbp} mmHg")

        if i < NUM_READINGS - 1:
            print(f"\n  Rest {REST_BETWEEN_S}s before next reading. Stay seated, relax.\n")
            countdown("Next reading in", REST_BETWEEN_S)

    # ── Wrap up ───────────────────────────────────────────────────────────────
    print(f"\n\n  All {NUM_READINGS} readings done — stopping PPG capture...")
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()

    notes = ""
    try:
        notes = input("\n  Optional notes (ring position, room temp, etc.) — Enter to skip: ").strip()
    except (EOFError, KeyboardInterrupt):
        pass

    # Average BP
    valid_sbp = [r["sbp_mmhg"] for r in readings if r["sbp_mmhg"]]
    valid_dbp = [r["dbp_mmhg"] for r in readings if r["dbp_mmhg"]]
    avg_sbp = sum(valid_sbp) / len(valid_sbp) if valid_sbp else None
    avg_dbp = sum(valid_dbp) / len(valid_dbp) if valid_dbp else None

    cal = {
        "state": state,
        "timestamp": ts,
        "ppg_csv": ppg_csv,
        "ppg_log": ppg_log,
        "ring_uuid": ring_uuid,
        "avg_sbp_mmhg": round(avg_sbp, 1) if avg_sbp else None,
        "avg_dbp_mmhg": round(avg_dbp, 1) if avg_dbp else None,
        "readings": readings,
        "notes": notes or None,
        "ecg_export": (
            "iPhone Health app → profile icon → Export All Health Data → "
            "AirDrop zip to Mac → "
            "apple_health_export/electrocardiograms/*.csv"
        ),
    }

    with open(cal_json, "w") as fh:
        json.dump(cal, fh, indent=2)

    banner(
        "Session Complete",
        [
            f"State       : {state}",
            f"Average BP  : {avg_sbp:.0f} / {avg_dbp:.0f} mmHg" if avg_sbp else "Average BP  : (no readings)",
            f"PPG file    : {ppg_csv}",
            f"Cal file    : {cal_json}",
            "",
            "NEXT: Export ECG from iPhone Health app",
            "  Health → profile icon → Export All Health Data",
            "  AirDrop zip to Mac",
            "  Inside: apple_health_export/electrocardiograms/*.csv",
        ],
    )
    beep(2)


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("uuid",
                   help="Ring CBPeripheral UUID from 'python -m opencircuit scan'")
    p.add_argument("state",
                   choices=["rest", "exercise", "morning"],
                   help="Physiological state for this session")
    args = p.parse_args()
    run(args.uuid, args.state)


if __name__ == "__main__":
    main()
