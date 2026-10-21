import numpy as np,sys,struct
for f in sys.argv[1:]:
  b=open(f,'rb').read(); w,h,c=struct.unpack('<III',b[4:16])
  a=np.frombuffer(b,dtype='<f4',offset=16).reshape(h,w,3)
  y=0.2627*a[...,0]+0.6780*a[...,1]+0.0593*a[...,2]
  ev=np.log2(np.maximum(y,1e-6)/0.18)
  p=np.percentile(ev,[1,5,25,50,75,95,99,99.9])
  fr=[(ev>x).mean()*100 for x in (0,1,1.5,2)]
  print(f.split('/')[-1][:22], ' '.join(f'{v:+.1f}' for v in p), ' >0,1,1.5,2EV%:',' '.join(f'{v:.1f}' for v in fr))
