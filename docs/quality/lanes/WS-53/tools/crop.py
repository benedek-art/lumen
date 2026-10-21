# crop.py out.png x y w h scale img1 img2 [img3...]  (-- adds amplified |diff| of first two, x8)
import sys, numpy as np
from PIL import Image, ImageDraw
out=sys.argv[1]; x,y,w,h,sc=map(int,sys.argv[2:7]); files=sys.argv[7:]
amp = '--diff' in files
files=[f for f in files if f!='--diff']
tiles=[]
for f in files:
    im=Image.open(f).convert('RGB')
    if x<0:  # auto: locate max diff later
        pass
    tiles.append(im.crop((x,y,x+w,y+h)))
if amp:
    a=np.asarray(tiles[0]).astype(int); b=np.asarray(tiles[1]).astype(int)
    d=np.clip(np.abs(a-b)*8,0,255).astype(np.uint8); tiles.append(Image.fromarray(d))
tiles=[t.resize((w*sc,h*sc),Image.NEAREST) for t in tiles]
W=sum(t.width for t in tiles)+4*(len(tiles)-1)
sheet=Image.new('RGB',(W,h*sc),(255,0,255))
xx=0
for t in tiles: sheet.paste(t,(xx,0)); xx+=t.width+4
sheet.save(out, optimize=True)
print(out, sheet.size)
