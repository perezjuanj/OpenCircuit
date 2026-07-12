"""OSA SpO2 — frequency-domain ratio-of-ratios (#91).
Per ~30s window: find the cardiac frequency (peak of IR power in the pulse band),
evaluate AC magnitude of Red & IR at THAT frequency (Goertzel), DC = window mean.
  R = (AC_red/DC_red)/(AC_ir/DC_ir);  SpO2 = a - b*R.
FD extraction rejects the large respiratory/baseline wander + broadband noise that
wrecked time-domain peak-to-peak AC.
"""
import math, statistics, sys
sys.path.insert(0,'opencircuit')
from osa_spo2 import decode_night, channels, GT

# normalized cardiac band (cycles/sample). At Hz~4.17: 40-90 bpm -> 0.16-0.36.
FMIN, FMAX, NF = 0.10, 0.40, 60
FREQS = [FMIN + (FMAX-FMIN)*i/(NF-1) for i in range(NF)]

def goertzel_mag(x, f):
    """|DFT| at normalized freq f (cycles/sample), mean-removed."""
    n=len(x); m=statistics.fmean(x)
    w=2*math.pi*f; cr=math.cos(w); ci=math.sin(w)
    s0=s1=s2=0.0
    for v in x:
        s0=(v-m)+2*cr*s1-s2; s2=s1; s1=s0
    re=s1-s2*cr; im=s2*ci
    return math.hypot(re,im)*2/n     # amplitude

def _band_amps(w):
    return [goertzel_mag(w,f) for f in FREQS]

def window_R(ir, red, grn):
    """One window -> (R, min-channel-SNR) or None.
    Lock pulse freq on green; require a CLEAN pulse (amplitude at fstar >> band-median
    amplitude) in ALL three channels — a weak IR pulse is the dominant artifact that
    inflates R into fake desaturations."""
    dci=statistics.fmean(ir); dcr=statistics.fmean(red)
    if dci<=0 or dcr<=0: return None
    ampg=_band_amps(grn); fi=max(range(len(FREQS)), key=lambda k:ampg[k]); fstar=FREQS[fi]
    def snr(w,amps=None):
        a=amps or _band_amps(w); at=a[fi]; med=statistics.median(a)
        return at/(med+1e-9)
    si=snr(ir); sr=snr(red); sg=ampg[fi]/(statistics.median(ampg)+1e-9)
    aci=goertzel_mag(ir,fstar); acr=goertzel_mag(red,fstar)
    pii=aci/dci; pir=acr/dcr
    if pii<=0: return None
    return (pir/pii, min(si,sr,sg), pii)

def spo2_series(ch, ir_idx, red_idx, grn_idx=2, win=128, step=64,
                snr_ir=5.0, snr_all=4.0, pi_ir_min=0.15):
    """Gated ratio-of-ratios series. snr_ir: IR pulse SNR floor (kills the fake-low
    artifact); snr_all: floor for red & green too; pi_ir_min: IR perfusion-index floor
    (%) — below it AC_ir is tiny and R (=PI_red/PI_ir) is unreliable, so SpO2 is
    dropped, exactly as clinical oximeters flag low-perfusion readings."""
    ir=ch[ir_idx]; red=ch[red_idx]; grn=ch[grn_idx]; n=len(ir)
    out=[]  # (R, minSNR)
    for a in range(0, n-win, step):
        wi,wr,wg=ir[a:a+win],red[a:a+win],grn[a:a+win]
        dci=statistics.fmean(wi); dcr=statistics.fmean(wr)
        if dci<=0 or dcr<=0: continue
        ampg=_band_amps(wg); fi=max(range(len(FREQS)),key=lambda k:ampg[k]); fstar=FREQS[fi]
        medg=statistics.median(ampg)
        si=goertzel_mag(wi,fstar)/(statistics.median(_band_amps(wi))+1e-9)
        sr=goertzel_mag(wr,fstar)/(statistics.median(_band_amps(wr))+1e-9)
        sg=ampg[fi]/(medg+1e-9)
        if si<snr_ir or sr<snr_all or sg<snr_all: continue   # need clean pulse everywhere
        aci=goertzel_mag(wi,fstar); acr=goertzel_mag(wr,fstar)
        pii=aci/dci
        if pii*100 < pi_ir_min: continue                     # low-perfusion -> unreliable
        R=(acr/dcr)/pii
        if not (0.1<R<2.5): continue
        out.append((R,min(si,sr,sg)))
    return out

if __name__=='__main__':
    for name in ['osa2','osa3','osa4']:
        ch=channels(decode_night(name))
        print(f"=== {name}  GT avg={GT[name][2]} min={GT[name][3]} ===")
        for iri,redi,lbl in [(0,1,'IR=ch0,Red=ch1'),(1,0,'IR=ch1,Red=ch0')]:
            s=spo2_series(ch,iri,redi)
            Rs=[r for r,_ in s]
            if not Rs: print(f"   {lbl}: none"); continue
            q=statistics.quantiles(Rs,n=100)
            print(f"   {lbl}: n={len(Rs)}/{len(ch[0])//64} R p2={q[1]:.3f} p10={q[9]:.3f} p50={statistics.median(Rs):.3f} p90={q[89]:.3f} p98={q[97]:.3f}")
