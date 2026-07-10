"""OSA SpO2 metrics (#91) — calibrated series -> avg / min / time<90% / ODI.
Validates the full pipeline against the app's 3-night comprehensive-assessment report.

Chain (all local, no cloud):
  0x48 frames -> dedupe by counter -> 3 PPG channels (IR=ch0, Red=ch1, Green=ch2)
  -> per-window FD ratio-of-ratios R -> SpO2 = A - B*R  (calibrated on 3 nights)
  -> smoothed SpO2 series (~15s/step) -> metrics.
AHI (apnea events) is NOT computed here — it needs the airflow/effort model the app
runs server-side; SpO2/ODI is the locally-derivable tier.
"""
import sys, statistics
sys.path.insert(0,'opencircuit')
from osa_spo2 import decode_night, channels, GT
from osa_spo2_fd import spo2_series

A, B = 104.91, 15.18        # SpO2 = A - B*R  (fit on osa2/3/4 avg+min anchors)
HZ = 4.15                   # samples/s/channel (pulse-anchored: ~48bpm; osa4 dur 7.05h=GT)
STEP = 64                   # FD window hop (samples) -> STEP/HZ s per point

def median_filter(x,k):
    n=len(x); out=[]
    for i in range(n):
        a=max(0,i-k//2); b=min(n,i+k//2+1)
        out.append(statistics.median(x[a:b]))
    return out

def spo2_from_night(name):
    ch=channels(decode_night(name))
    s=spo2_series(ch,0,1)                       # IR=ch0, Red=ch1
    sp=[min(100.0, A - B*R) for R,_ in s]       # clamp <=100
    return median_filter(sp,3)                  # ~45s median smoothing

def count_odi(sp, drop=3.0, base_win=20, refractory=4):
    """Oxygen Desaturation Index events. Baseline = rolling median (~base_win pts).
    Event = dip >= `drop` % below baseline reaching a nadir, then recovery; refractory
    enforced between events (points)."""
    n=len(sp); base=median_filter(sp,base_win)
    events=0; i=0
    while i<n:
        if sp[i] <= base[i]-drop:
            j=i
            while j<n and sp[j] <= base[i]-1.0: j+=1   # extend until near-recovery
            events+=1
            i=j+refractory
        else:
            i+=1
    return events

def metrics(name):
    sp=spo2_from_night(name)
    dur_h=len(decode_night(name))*20/HZ/3600     # unique frames*20 samples /Hz
    avg=statistics.fmean(sp)
    mn=min(sp)
    sec_lo=sum(1 for v in sp if v<90)*(STEP/HZ)
    for drop in (3.0,4.0):
        odi=count_odi(sp,drop)/dur_h
        yield drop, avg, mn, sec_lo, odi, dur_h

if __name__=='__main__':
    print(f"SpO2 = {A} - {B}*R   Hz={HZ}\n")
    hdr=f"{'night':6} {'dur':>5} | {'avg':>10} {'min':>10} {'t<90%':>12} {'ODI@3':>7} {'ODI@4':>7}"
    print(hdr); print('-'*len(hdr))
    for name in ['osa2','osa3','osa4']:
        rows=list(metrics(name))
        drop3=rows[0]; drop4=rows[1]
        _,avg,mn,sec,odi3,dur=drop3
        odi4=drop4[4]
        g=GT[name]  # AHI,ODI,avg,min,sec<90
        def mm(v):
            m=int(v)//60; s=int(v)%60; return f"{m}m{s:02d}s"
        print(f"{name:6} {dur:4.1f}h | {avg:4.1f}(GT{g[2]})  {mn:4.1f}(GT{g[3]})  "
              f"{mm(sec):>5}(GT{mm(g[4])})  {odi3:4.1f}  {odi4:4.1f}   (GT ODI {g[1]})")
