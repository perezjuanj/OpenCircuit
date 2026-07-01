"""PPG CSV watcher — auto-imports new capture_ppg.py CSVs into health-local-core.

Watches a directory for new ppg_capture_*.csv files, submits each to the
health-local-core API (/ppg/import), then writes an Obsidian session note.

Usage:
    python ppg_watch.py [--watch-dir DIR] [--api-url URL] [--vault-dir DIR]

Defaults:
    --watch-dir  /Users/pravinsail/OpenCircuit-master/desktop
    --api-url    http://localhost:8765
    --vault-dir  ~/Documents/Obsidian/Health/PPG   (skipped if not set)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx


API_URL_DEFAULT = "http://localhost:8765"
WATCH_DIR_DEFAULT = Path(__file__).parent
POLL_INTERVAL_S = 5.0
STABLE_SECS = 30.0  # file must be unmodified this long before import (ensures capture is finished)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def import_csv(path: Path, api_url: str) -> dict | None:
    with open(path, "rb") as f:
        try:
            r = httpx.post(
                f"{api_url}/ppg/import",
                files={"file": (path.name, f, "text/csv")},
                timeout=60.0,
            )
            r.raise_for_status()
            return r.json()
        except httpx.HTTPStatusError as e:
            print(f"  [ERROR] HTTP {e.response.status_code}: {e.response.text[:200]}")
            return None
        except Exception as e:
            print(f"  [ERROR] {e}")
            return None


def fetch_summary(session_id: str, api_url: str) -> dict | None:
    try:
        r = httpx.get(f"{api_url}/ppg/sessions/{session_id}/summary", timeout=30.0)
        r.raise_for_status()
        return r.json()
    except Exception as e:
        print(f"  [WARN] Could not fetch summary: {e}")
        return None


def write_obsidian_note(summary: dict, vault_dir: Path) -> Path:
    """Write a dated Obsidian markdown note for a PPG session."""
    vault_dir.mkdir(parents=True, exist_ok=True)

    captured_at = summary.get("captured_at", "")
    try:
        ts = datetime.fromisoformat(captured_at.replace("Z", "+00:00"))
    except Exception:
        ts = datetime.now(timezone.utc)

    date_str = ts.strftime("%Y-%m-%d")
    time_str = ts.strftime("%H:%M")
    filename = f"PPG-{ts.strftime('%Y%m%d-%H%M%S')}.md"
    note_path = vault_dir / filename

    duration_s = summary.get("duration_s", 0)
    duration_min = duration_s / 60
    mean_hr = summary.get("mean_hr_bpm")
    mean_spo2 = summary.get("mean_spo2_pct")
    total_frames = summary.get("total_frames", 0)
    agc_frames = summary.get("agc_frames", 0)
    contact_ratio = summary.get("contact_ratio")
    csv_filename = summary.get("csv_filename", "")

    hr_trend = summary.get("hr_trend", [])
    hr_trend_lines = "\n".join(
        f"  - seq {row['seq']}: {row['hr_fft_bpm']:.1f} bpm"
        for row in hr_trend[:20]
        if row.get("hr_fft_bpm")
    )

    contact_pct = f"{contact_ratio * 100:.1f}%" if contact_ratio is not None else "n/a"
    hr_str = f"{mean_hr:.1f} bpm" if mean_hr else "n/a"
    spo2_str = f"{mean_spo2:.1f}%" if mean_spo2 else "n/a"

    note = f"""---
date: {date_str}
time: {time_str}
tags: [health, ppg, ringconn]
session_id: {summary.get('session_id', '')}
source: {csv_filename}
---

# PPG Session — {date_str} {time_str}

| Metric | Value |
|--------|-------|
| Duration | {duration_min:.1f} min |
| Mean HR (FFT) | {hr_str} |
| Mean SpO₂ | {spo2_str} |
| Contact ratio | {contact_pct} |
| Total frames | {total_frames} |
| AGC events | {agc_frames} |

## HR Trend (first 20 frames with estimate)

{hr_trend_lines or "  (no HR estimates yet — need 10s of contact data)"}

## Notes

- chA = GREEN, chB = RED 660 nm, chC = IR 940 nm (confirmed 2026-06-26)
- SpO₂ formula: `110.0 - 19.05 × R` calibrated Apple Watch 98% reference
- Stage 2 import: `{csv_filename}` → health-local-core DuckDB
"""

    note_path.write_text(note, encoding="utf-8")
    return note_path


def watch(watch_dir: Path, api_url: str, vault_dir: Path | None) -> None:
    seen: dict[str, str] = {}  # filename → sha256

    print(f"Watching {watch_dir} for new ppg_capture_*.csv files")
    print(f"API:     {api_url}")
    if vault_dir:
        print(f"Obsidian: {vault_dir}")
    print("Press Ctrl-C to stop.\n")

    # Seed seen set with stable existing files — don't re-import on startup.
    # Files modified recently are left out of seen so they get picked up when stable.
    now = time.time()
    for p in sorted(watch_dir.glob("ppg_capture_*.csv")):
        if now - p.stat().st_mtime >= STABLE_SECS:
            seen[p.name] = sha256(p)
    print(f"  {len(seen)} existing files indexed (will not re-import).")

    while True:
        time.sleep(POLL_INTERVAL_S)
        for p in sorted(watch_dir.glob("ppg_capture_*.csv")):
            h = sha256(p)
            if p.name in seen and seen[p.name] == h:
                continue  # already processed this exact file version

            # File is new or has grown since last check.
            # Only import once write is complete (mtime stable for STABLE_SECS).
            age_s = time.time() - p.stat().st_mtime
            if age_s < STABLE_SECS:
                # Still being written by capture_ppg.py — skip, check next poll.
                continue

            # File is stable and complete — mark seen BEFORE import to prevent duplicates.
            seen[p.name] = h
            print(f"\n[{datetime.now().strftime('%H:%M:%S')}] New capture: {p.name}")

            result = import_csv(p, api_url)
            if result is None:
                print("  Import failed — will retry next cycle.")
                del seen[p.name]  # allow retry
                continue

            session_id = result.get("session_id")
            print(f"  Imported: session_id={session_id} "
                  f"rows={result.get('records_inserted')} "
                  f"dedup={result.get('records_deduplicated')}")

            if vault_dir and session_id:
                summary = fetch_summary(session_id, api_url)
                if summary:
                    note_path = write_obsidian_note(summary, vault_dir)
                    print(f"  Obsidian note: {note_path}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--watch-dir", type=Path, default=WATCH_DIR_DEFAULT,
                   help="directory to watch for ppg_capture_*.csv files")
    p.add_argument("--api-url", default=API_URL_DEFAULT,
                   help="health-local-core API base URL")
    p.add_argument("--vault-dir", type=Path, default=None,
                   help="Obsidian vault directory for PPG session notes (optional)")
    args = p.parse_args()

    try:
        watch(args.watch_dir, args.api_url, args.vault_dir)
    except KeyboardInterrupt:
        print("\nWatcher stopped.")


if __name__ == "__main__":
    main()
