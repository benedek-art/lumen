import sys, numpy as np
from PIL import Image
a=np.asarray(Image.open(sys.argv[1]).convert('RGB')).astype(int); b=np.asarray(Image.open(sys.argv[2]).convert('RGB')).astype(int)
d=np.abs(a-b).max(axis=2); 
k=int(sys.argv[3]) if len(sys.argv)>3 else 64
# box-sum to find region with largest diff energy
from numpy.lib.stride_tricks import sliding_window_view as sw
y,x=np.unravel_index(np.argmax(d),d.shape); print('maxpix',x,y,d.max())
c=np.cumsum(np.cumsum(np.pad(d,((1,0),(1,0))),0),1)
s=c[k:,k:]-c[:-k,k:]-c[k:,:-k]+c[:-k,:-k]
yy,xx=np.unravel_index(np.argmax(s),s.shape); print('maxbox',xx,yy,s.max()/(k*k), a.shape)
