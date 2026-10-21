# Mean dE2000 of zone EV -1/+1 (min of the two) per frame, per candidate default-pivot set.
# Run from a scratch dir: python3 pivot_authority.py
import json,subprocess,sys
BIN='/home/user/lumen/.build/x86_64-unknown-linux-gnu/release/lumen-render'
frames=['6929_sony-ilce-7m4','6933_sony-ilce-7m4','2545_panasonic-dmc-gx85','1569_panasonic-dmc-gx80','4694_canon-eos-r5','983_canon-eos-5d-mark-iv','1840_nikon-d850','4213_nikon-z-7-2']
sets={'A_now':[-4,-2,0,2,4],'B_aud':[-3.1,-1.7,0,1.5,3.0],'C_even':[-3,-1.5,0,1.5,3],'D':[-4,-2,0,1,2],'G':[-3,-1.5,0,1.25,2.25]}
zones=['dark','shadow','mid','light','bright']
out={}
for sn,evs in sets.items():
  piv=[(e+9)/14 for e in evs]
  sets_args=[]
  for i,p in enumerate(piv): sets_args+=['--set',f'develop.zones.pivots.{i}={p:.6f}']
  for z in zones:
    row=[]
    for f in frames:
      m=f'{sn}_{z}_{f}.json'
      subprocess.run([BIN,'sweep','--input',f'/home/user/lumen/corpus/lfi/{f}.lfi','--key',f'develop.zones.{z}.ev','--values','-1,0,1','--long-edge','384','--out','/dev/null' if False else f'{sn}_{z}_{f}.png','--metrics',m]+sets_args,capture_output=True)
      d=json.load(open(m))
      de=[t['deltaE2000VsReference']['mean'] for t in d['tiles'] if not t['isReference']]
      row.append(round(min(de),2))
    out[(sn,z)]=row
    print(sn,z,row,flush=True)
