"""Decode the RingConn OSA dense-PPG stream (opcode 0x48) — #91.
NOT compressed: each 196-byte frame after 0x48 is
  [flag c1][4B counter][4B session cursor][2B][2B offset]  (13B header)
  [1B marker][30 samples][1B marker][30 samples]           (182B payload)
samples = 3-byte BIG-ENDIAN, 3 LED channels interleaved (idx%3), ~18-bit, ~10.35 Hz/ch.
"""
import re
def decode_channels(decoded_log_path):
    ch=[[],[],[]]
    for line in open(decoded_log_path):
        m=re.search(r'0x0804 48 ([0-9a-f ]+)', line)
        if not m: continue
        b=[int(x,16) for x in m.group(1).split()]
        if len(b)<196: continue
        for blk in (14,105):                 # skip 1B marker before each 30-sample block
            for s in range(30):
                i=blk+s*3
                ch[s%3].append((b[i]<<16)|(b[i+1]<<8)|b[i+2])
    return ch                                 # 3 channels, big-endian 18-bit PPG
