"""#61 clean A/B — map every descriptor byte to the maintainer's labeled phases.

Ground truth (06-19, wall-clock == btsnoop UTC base, calibrated from prior pull):
  10:56-10:58  FINGER   (warm baseline)
  10:58-11:04  CHARGER  (battery should rise, ring cools)
  11:04-11:06  TABLE    (off-wrist, NOT charging)
  11:06+       FINGER2  (re-warm)

Prints: per-frame full bytes with phase label, per-phase byte distributions
(to find the byte that flips CHARGER vs the rest), and ALL non-descriptor
notifications in the charger window (case-battery / #89 hunt).
"""
from __future__ import annotations
import sys
from datetime import datetime, timezone
from collections import Counter, defaultdict
from opencircuit.sniff import _iter_att

PHASES = [  # (label, start "HH:MM:SS", end)
    ("FINGER ", "10:56:00", "10:58:00"),
    ("CHARGER", "10:58:00", "11:04:00"),
    ("TABLE  ", "11:04:00", "11:06:00"),
    ("FINGER2", "11:06:00", "11:20:00"),
]

def hms(ts): return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%H:%M:%S")
def temp_mean(f):
    a=(f[6]<<8)|f[7]; b=(f[8]<<8)|f[9]
    return (a+b)/20.0 if (150<=a<=500 and 150<=b<=500) else None
def phase_of(ts):
    t=hms(ts)
    for lab,s,e in PHASES:
        if s<=t<e: return lab
    return None

def main(path):
    blob=open(path,"rb").read()
    evs=list(_iter_att(blob)); evs.sort(key=lambda e:e.ts_unix)
    # window = 10:55..11:20
    win=[e for e in evs if "10:55:00"<=hms(e.ts_unix)<="11:20:00"]

    # --- descriptor frames, labeled ---
    desc=[e for e in win if e.opcode in (0x1B,0x1D) and e.value and e.value[0] in (0x10,0x87) and len(e.value)>=19]
    print(f"=== {len(desc)} descriptor frames in 10:55-11:20 ===")
    print(f"{'time':<10}{'ph':<8}{'resp':<5}{'batt':<6}{'temp':<7}{'[2]':<5}{'[14]':<6}{'[15]':<6}{'[16]':<6}{'[17]':<6}")
    by=defaultdict(lambda: defaultdict(Counter))  # phase -> byteidx -> Counter
    for e in desc:
        f=e.value; ph=phase_of(e.ts_unix) or "???    "
        tm=temp_mean(f); tms=f"{tm:.1f}" if tm else "--"
        print(f"{hms(e.ts_unix):<10}{ph:<8}{f[0]:02x}   {f[1]:<6}{tms:<7}{f[2]:02x}   {f[14]:02x}    {f[15]:02x}    {f[16]:02x}    {f[17]:02x}")
        for j in range(1,18):
            by[ph][j][f[j]]+=1

    # --- per-phase byte distribution, find CHARGER-distinct bytes ---
    print("\n=== per-phase byte distribution (looking for a CHARGER-distinct byte) ===")
    phases=[p[0] for p in PHASES if by.get(p[0])]
    for j in range(1,18):
        cells=[]
        for ph in phases:
            c=by[ph][j]
            top=" ".join(f"{v:02x}×{n}" for v,n in c.most_common(3))
            cells.append(f"{ph}:{top}")
        # flag if charger's dominant value never appears in other phases
        if by.get("CHARGER") and by["CHARGER"][j]:
            cmode=by["CHARGER"][j].most_common(1)[0][0]
            others=set()
            for ph in phases:
                if ph!="CHARGER": others|=set(by[ph][j].keys())
            flag="   <== CHARGER-DISTINCT" if cmode not in others else ""
        else:
            flag=""
        print(f"  [{j:>2}] " + " | ".join(cells) + flag)

    # --- non-descriptor notifications in charger window (#89 case battery hunt) ---
    print("\n=== non-descriptor RX notifications 10:57-11:05 (case-battery / #89 hunt) ===")
    for e in win:
        if not (e.opcode in (0x1B,0x1D) and e.value): continue
        if e.value[0] in (0x10,0x87): continue
        if "10:57:00"<=hms(e.ts_unix)<="11:05:30":
            print(f"  {hms(e.ts_unix)} h=0x{(e.att_handle or 0):04x} {e.value.hex(' ')}")

if __name__=="__main__":
    main(sys.argv[1])
