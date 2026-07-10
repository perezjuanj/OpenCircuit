"""OSA full-night per-epoch SpO2/HR from the 0x4c BulkSleep stream (#91).

The 0x48 dense PPG gives the high-rate waveform; 0x4c gives the ring's OWN per-epoch
(2.5-min) SpO2/HR for the whole night, store-and-forwarded. This pulls that series
straight from the existing OSA captures — no new capture, no DSP.

Record layout = PROTOCOL.md §5.3 (23 B): [0:4] BE counter (+150 s/epoch), [4] HR,
[5] HRV, [7] RR*8, [8] SpO2, [10:20] acti_counts.

CRITICAL (#39): classify sleep-vitals STRUCTURALLY, not by a 0x57..0x63 SpO2 band —
a real desaturation nadir (<87 %) would be dropped by the band gate, losing exactly
the OSA events we want. sleep-vitals = NOT idle AND [8] not in {0x12,0x13}.
"""
import sys, statistics
sys.path.insert(0, '.')
from decode_bulk import notif_payloads, reassemble_4c, is_idle, ts

NIGHTS = {'osa2':'captures/osa2_decoded.txt',
          'osa3':'captures/osa3_decoded.txt',
          'osa4':'captures/osa4_decoded.txt'}
GT = {'osa2':(96,85),'osa3':(96,87),'osa4':(95,87)}   # SpO2 avg, min

AWAKE = {0x12, 0x13}

def sessions(recs, gap=600):
    out=[]; seg=[]; prev=None
    for r in recs:
        c=int.from_bytes(r[0:4],'big')
        if prev is not None and c-prev>gap:
            out.append(seg); seg=[]
        seg.append(r); prev=c
    if seg: out.append(seg)
    return out

def night_spo2(recs):
    """Return per-epoch (counter, HR, SpO2) for structural sleep-vitals epochs."""
    out=[]
    for r in recs:
        if is_idle(r): continue
        if r[8] in AWAKE: continue          # awake / no-SpO2 sentinel
        if not (30<=r[8]<=100): continue    # guard against garbage bytes
        out.append((int.from_bytes(r[0:4],'big'), r[4], r[8]))
    return out

if __name__=='__main__':
    print(f"{'night':6} {'session (UTC)':>28} | epochs | {'SpO2 avg':>8} {'min':>4} | GT(avg/min)")
    print('-'*84)
    for name,path in NIGHTS.items():
        recs=reassemble_4c(notif_payloads(open(path).read().splitlines(), 0x4c))
        best=None
        for s in sessions(recs):
            sp=night_spo2(s)
            if len(sp)<10: continue
            spo2=[v[2] for v in sp]
            # pick the session with the most sleep-vitals epochs = the OSA night
            if best is None or len(sp)>best[0]:
                best=(len(sp), s[0], s[-1], statistics.fmean(spo2), min(spo2), sp)
        if not best:
            print(f"{name:6}  (no sleep-vitals session)"); continue
        n,r0,r1,avg,mn,sp=best
        c0=int.from_bytes(r0[0:4],'big'); c1=int.from_bytes(r1[0:4],'big')
        g=GT[name]
        print(f"{name:6} {ts(c0):%m-%d %H:%M}->{ts(c1):%H:%M} | {n:6d} | "
              f"{avg:8.1f} {mn:4d} | {g[0]}/{g[1]}")
