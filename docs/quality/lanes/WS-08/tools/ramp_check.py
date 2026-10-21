#!/usr/bin/env python3
"""WS-08 ramp check: render corpus/synthetic/grey_ramp.lfi at native 2800 px through
lumen-render for a set of Zones recipes and report, per recipe, the pipeline transfer
slope relative to the default render (rows 0-199 averaged; 0.1 EV box smooth).
Usage: ramp_check.py [outdir]   (env BIN = lumen-render path, LUMEN = repo root)"""
import os, sys, subprocess, numpy as np
from PIL import Image
LUMEN=os.environ.get('LUMEN','/home/user/lumen')
BIN=os.environ.get('BIN',LUMEN+'/.build/x86_64-unknown-linux-gnu/release/lumen-render')
OUT=sys.argv[1] if len(sys.argv)>1 else '/tmp/claude-0/spec/ramp'
os.makedirs(OUT,exist_ok=True)
RECIPES={
 'default':[],
 'dark+3':['develop.zones.dark.ev=3'],
 'dark+1.25':['develop.zones.dark.ev=1.25'],
 'mid-3':['develop.zones.mid.ev=-3'],
 'mid+3':['develop.zones.mid.ev=3'],
 'light-3':['develop.zones.light.ev=-3'],
 'shadow+3':['develop.zones.shadow.ev=3'],
 'bright-3':['develop.zones.bright.ev=-3'],
 'dark+3,mid-3':['develop.zones.dark.ev=3','develop.zones.mid.ev=-3'],
 'shadow+3,mid-3,light+3':['develop.zones.shadow.ev=3','develop.zones.mid.ev=-3','develop.zones.light.ev=3'],
}
ev=-10+(np.arange(2800)+0.5)/200
k=np.ones(20)/20
def render(name,sets):
    p=f'{OUT}/{name.replace(",","_")}.png'
    a=[BIN,'render','--input',LUMEN+'/corpus/synthetic/grey_ramp.lfi','--long-edge','2800','--out',p]
    for s in sets: a+=['--set',s]
    subprocess.run(a,check=True,capture_output=True)
    g=np.asarray(Image.open(p).convert('RGB')).astype(float)[0:200].mean(axis=0).mean(axis=1)
    return np.convolve(g,k,'same')
base=render('default',[])
m=(ev>-9.8)&(ev<3.8)
d0=np.gradient(base,ev)
print(f"{'recipe':26s} {'minRatio':>8s} {'@EV':>6s} {'negSpanEV':>9s} {'flatEV':>7s} {'maxKink':>8s}")
for name,sets in RECIPES.items():
    c=base if name=='default' else render(name,sets)
    d=np.gradient(c,ev)
    vis=m&(c>5)&(c<250)&(d0>2)
    r=d[vis]/d0[vis]
    neg=(d[m]<-0.5).sum()/200
    flat=(m&(d>=-0.5)&(d<1.0)&(c>3)&(c<252)).sum()/200
    # slope kink: max change of slope ratio between samples 0.1 EV apart
    rr=np.where(vis,d/np.maximum(d0,1e-9),np.nan); kink=np.nanmax(np.abs(rr[20:]-rr[:-20]))
    print(f"{name:26s} {r.min():8.2f} {ev[vis][r.argmin()]:+6.2f} {neg:9.2f} {flat:7.2f} {kink:8.2f}")
