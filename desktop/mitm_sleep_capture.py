"""mitmproxy addon — auto-save RingConn's computed hypnogram (sleep ground truth).

Run via `desktop/capture_groundtruth.sh` (which wires up ports and paths for you), or:

    mitmdump -s desktop/mitm_sleep_capture.py --listen-port 8080

WHAT IT DOES
Every response that flows through is scanned for a `sleepPhases` array (searched
RECURSIVELY — the envelope keys vary between app versions, so we do not depend on the
path or the response shape). When one is found the addon:

  1. derives the night's WAKE date from the latest phase end, in the ring's local
     timezone (`OC_TZ`, default America/New_York), because that is our night key
     (`SleepNightKey`, build 39+ — startOfDay of the recorded in-bed END);
  2. writes it to `desktop/captures/groundtruth_sleep_<YYYYMMDD>.json`;
  3. prints a loud line so you can watch nights land without opening the mitmweb UI.

It also keeps a running census of every RingConn host/path seen. That census is the
DIAGNOSTIC: if you tap through nights and see hosts but never a hypnogram, the app is
talking but not serving what we want; if you see NO ringconn traffic at all, TLS
interception is being refused (Android 7+ user-CA limit and/or pinning) — stop and say so
rather than burning the evening.

Captures land in `desktop/captures/`, which is gitignored — it holds real health data.
Commit decoded FINDINGS only, never a raw capture.
"""

from __future__ import annotations

import json
import os
import pathlib
import datetime as dt
import logging

from mitmproxy import http

OUT_DIR = pathlib.Path(
    os.environ.get("OC_CAPTURE_DIR", pathlib.Path(__file__).parent / "captures")
)


def _resolve_tz():
    """Timezone for the night key, WITHOUT hard-depending on `zoneinfo`.

    ⚠️ mitmproxy's Homebrew binary bundles its own stripped Python that has **no
    `zoneinfo` module** (verified on mitmproxy 12.2.3, 2026-08-24) — importing it at module
    scope makes the addon fail to load and the proxy then runs happily while capturing
    nothing. So: prefer an explicit fixed offset, then zoneinfo if it happens to exist,
    and otherwise fall back to the machine's own local time.

    The fallback is the normal case and it is correct: the laptop running the capture is
    in the same timezone as the ring that recorded the night.
    """
    offset = os.environ.get("OC_TZ_OFFSET_HOURS")
    if offset:
        return dt.timezone(dt.timedelta(hours=float(offset)))
    name = os.environ.get("OC_TZ")
    if name:
        try:
            from zoneinfo import ZoneInfo

            return ZoneInfo(name)
        except Exception:
            logging.warning(
                f"[groundtruth] no zoneinfo available — using this machine's local time "
                f"instead of {name}. Set OC_TZ_OFFSET_HOURS to force an offset."
            )
    return None  # None => datetime.fromtimestamp uses system local time


TZ = _resolve_tz()

# A phase timestamp may arrive in seconds or milliseconds; anything past this is ms.
_MS_CUTOFF = 10_000_000_000


class SleepGroundTruth:
    def __init__(self) -> None:
        self.saved: dict[str, str] = {}          # night -> url it came from
        self.hosts: dict[str, int] = {}          # host -> response count
        self.ringconn_paths: set[str] = set()
        OUT_DIR.mkdir(parents=True, exist_ok=True)

    # ---- helpers -------------------------------------------------------------

    @staticmethod
    def _find_phases(node):
        """Depth-first search for the first non-empty `sleepPhases` list."""
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "sleepPhases" and isinstance(value, list) and value:
                    return value
                found = SleepGroundTruth._find_phases(value)
                if found is not None:
                    return found
        elif isinstance(node, list):
            for item in node:
                found = SleepGroundTruth._find_phases(item)
                if found is not None:
                    return found
        return None

    @staticmethod
    def _epoch_seconds(value) -> float | None:
        try:
            number = float(value)
        except (TypeError, ValueError):
            return None
        if number <= 0:
            return None
        return number / 1000.0 if number > _MS_CUTOFF else number

    def _night_key(self, phases: list) -> str | None:
        """Wake date = local calendar day of the LATEST phase end."""
        ends = [
            self._epoch_seconds(p.get("end"))
            for p in phases
            if isinstance(p, dict)
        ]
        ends = [e for e in ends if e is not None]
        if not ends:
            return None
        return dt.datetime.fromtimestamp(max(ends), TZ).strftime("%Y%m%d")

    # ---- mitmproxy hook ------------------------------------------------------

    def response(self, flow: http.HTTPFlow) -> None:
        host = flow.request.pretty_host
        self.hosts[host] = self.hosts.get(host, 0) + 1
        if "ringconn" in host:
            self.ringconn_paths.add(flow.request.path.split("?")[0])

        try:
            body = flow.response.text or ""
        except Exception:
            return
        if "sleepPhases" not in body:
            return

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            logging.warning(f"[groundtruth] {host} mentions sleepPhases but is not JSON — skipped")
            return

        phases = self._find_phases(payload)
        if not phases:
            return

        night = self._night_key(phases)
        if night is None:
            logging.warning("[groundtruth] found sleepPhases with no usable end timestamps — skipped")
            return

        path = OUT_DIR / f"groundtruth_sleep_{night}.json"
        # A night re-fetched with MORE phases wins; never shrink a capture we already hold.
        if path.exists():
            try:
                existing = self._find_phases(json.loads(path.read_text())) or []
            except Exception:
                existing = []
            if len(existing) >= len(phases):
                logging.info(f"[groundtruth] {night} already captured ({len(existing)} phases) — kept")
                return

        path.write_text(json.dumps(payload, indent=2))
        self.saved[night] = flow.request.pretty_url

        stages: dict[str, int] = {}
        for phase in phases:
            if isinstance(phase, dict):
                label = str(phase.get("sleepType", "?"))
                stages[label] = stages.get(label, 0) + 1
        summary = " ".join(f"{k.replace('SLEEP_','')}={v}" for k, v in sorted(stages.items()))

        logging.warning(
            f"[groundtruth] ✅ SAVED {night}  ({len(phases)} phases: {summary})  "
            f"→ {path.name}   [{len(self.saved)} night(s) so far]"
        )

    def done(self) -> None:
        print("\n" + "=" * 72)
        if self.saved:
            print(f"CAPTURED {len(self.saved)} NIGHT(S) → {OUT_DIR}")
            for night in sorted(self.saved):
                print(f"  ✅ groundtruth_sleep_{night}.json")
        else:
            print("NO HYPNOGRAMS CAPTURED.")
            if not self.hosts:
                print("  No traffic at all — the phone is not routing through this proxy.")
                print("  Re-check the Wi-Fi proxy host/port on the phone.")
            elif not any("ringconn" in h for h in self.hosts):
                print("  Traffic seen, but NONE from ringconn. Either the app was never")
                print("  opened, or it refuses the mitm CA (Android 7+ user-CA limit /")
                print("  certificate pinning). This is the 'stop and report' case.")
            else:
                print("  RingConn traffic WAS intercepted but carried no sleepPhases.")
                print("  Paths seen (share these — they tell us where the data moved to):")
                for p in sorted(self.ringconn_paths):
                    print(f"    {p}")
        if self.hosts:
            top = sorted(self.hosts.items(), key=lambda kv: -kv[1])[:8]
            print("\n  hosts seen: " + ", ".join(f"{h}({n})" for h, n in top))
        print("=" * 72 + "\n")


addons = [SleepGroundTruth()]
