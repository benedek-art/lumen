# grid.py out.png im x y w h ctrl1 ctrl2 ...   rows: none | R_ctrl | |R-N|*8
import sys,numpy as np
from PIL import Image, ImageDraw
out,im=sys.argv[1],sys.argv[2]; x,y,w,h=map(int,sys.argv[3:7]); ctrls=sys.argv[7:]
d='r/rad'
N=Image.open(f'{d}/{im}_none.png').convert('RGB').crop((x,y,x+w,y+h))
rows=[]
for c in ctrls:
    R=Image.open(f'{d}/{im}_R_{c}.png').convert('RGB').crop((x,y,x+w,y+h))
    D=Image.fromarray(np.clip(np.abs(np.asarray(R).astype(int)-np.asarray(N).astype(int))*8,0,255).astype(np.uint8))
    rows.append((c,[N,R,D]))
S=Image.new('RGB',(3*w+8,len(rows)*(h+16)),(30,30,30)); dr=ImageDraw.Draw(S)
for i,(c,ts) in enumerate(rows):
    for j,t in enumerate(ts): S.paste(t,(j*(w+4),i*(h+16)+14))
    dr.text((2,i*(h+16)),f'{im} R_{c}: none | radial | |diff|x8',fill=(255,255,0))
S.save(out,optimize=True); print(out,S.size)
