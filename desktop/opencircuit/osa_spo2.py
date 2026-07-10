"""OSA SpO2 pipeline (#91) — decode 0x48 PPG -> per-window ratio-of-ratios -> SpO2 series.
Builds on osa_ppg.py (proven 0x48 frame format). Adds:
  - per-session (cursor) filtering  [osa4 re-dumps night-2's backlog; must isolate]
  - robust outlier rejection (saturated/misaligned samples hit 24-bit garbage)
  - windowed AC/DC extraction -> R = (AC_red/DC_red)/(AC_ir/DC_ir)
  - SpO2 = a - b*R  (a,b calibrated vs 3-night ground truth)
  - sample-rate anchored to pulse rate (autocorrelation of the green/HR channel)
"""
import re, statistics, math
from collections import defaultdict

# ---- night -> (decoded log, session-cursor to KEEP) -------------------------
NIGHTS = {
    'osa2': ('captures/osa2_decoded.txt', 0x0c425adc),   # 07/08
    'osa3': ('captures/osa3_decoded.txt', 0x0c43adeb),   # 07/09
    'osa4': ('captures/osa4_decoded.txt', 0x0c44f92a),   # 07/10  (NOT 0x0c43adeb re-dump)
}
# app "comprehensive assessment" ground truth per night
GT = {  # AHI, ODI, spo2_avg, spo2_min, sec_below_90
    'osa2': (4.3, 4.2, 96, 85, 204),
    'osa3': (2.2, 3.8, 96, 87, 110),
    'osa4': (3.7, 4.8, 95, 87, 230),
}

def decode_night(name):
    """Return frames deduped by counter, chronological (counter descends over time).
    Counter steps by 20 per frame (=20 samples/ch); ~1900 frames/night are BLE
    retransmit duplicates -> keep first occurrence of each counter."""
    path, keep_cursor = NIGHTS[name]
    seen={}
    for line in open(path):
        m=re.search(r'0x0804 48 ([0-9a-f ]+)', line)
        if not m: continue
        b=[int(x,16) for x in m.group(1).split()]
        if len(b)<196: continue
        cur=(b[5]<<24)|(b[6]<<16)|(b[7]<<8)|b[8]
        if cur!=keep_cursor: continue
        ctr=(b[1]<<24)|(b[2]<<16)|(b[3]<<8)|b[4]
        if ctr in seen: continue
        ch=[[],[],[]]
        for blk in (14,105):
            for s in range(30):
                i=blk+s*3
                ch[s%3].append((b[i]<<16)|(b[i+1]<<8)|b[i+2])
        seen[ctr]=ch
    return [(c, seen[c]) for c in sorted(seen, reverse=True)]  # chronological

def channels(frames):
    """Flatten frames -> 3 continuous channel arrays (chronological)."""
    ch=[[],[],[]]
    for _,fch in frames:
        for c in range(3):
            ch[c].extend(fch[c])
    return ch

if __name__=='__main__':
    for name in NIGHTS:
        fr=decode_night(name)
        ch=channels(fr)
        print(f"{name}: {len(fr)} frames, {len(ch[0])} samples/ch")
        for c in range(3):
            xs=ch[c]
            med=statistics.median(xs)
            lo=sum(1 for x in xs if x<med*0.5)
            hi=sum(1 for x in xs if x>med*1.5)
            print(f"   ch{c}: median={med:.0f}  <0.5x:{lo} ({100*lo/len(xs):.1f}%)  >1.5x:{hi} ({100*hi/len(xs):.1f}%)")
