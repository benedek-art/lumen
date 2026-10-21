import json,subprocess,sys,numpy as np
d=json.load(open(sys.argv[1])); solver=sys.argv[2]
KS=('5','15','17','19','25')
lines=[];keys=[]
for i,r in enumerate(d):
    K,T=r['asShot']
    for k in KS:
        for m in r[k]['means'][:120]:
            lines.append('%g %g %g %g %g'%(m[0],m[1],m[2],K,T)); keys.append((i,k))
out=subprocess.run([solver],input='\n'.join(lines)+'\n',capture_output=True,text=True).stdout.split('\n')
res={}
for (i,k),o in zip(keys,out):
    if not o: continue
    kk,t=map(float,o.split()); res.setdefault((i,k),[]).append((kk,t))
agg={}
for i,r in enumerate(d):
    row=[]
    for k in KS:
        a=np.array(res[(i,k)]); mired=1e6/a[:,0]
        row.append('k%s: sdK %4.0f (p5-p95 %4.0f) sdMired %4.1f sdTint %4.1f'%(k,a[:,0].std(),np.percentile(a[:,0],95)-np.percentile(a[:,0],5),mired.std(),a[:,1].std()))
        agg.setdefault((r['file'],k),[]).append((a[:,0].std(),mired.std(),a[:,1].std(),a[:,0].mean()))
    print(r['file'],'iso',int(r['iso']),'lvl %.2f'%r['level']); print('   '+'\n   '.join(row))
print('--- per-frame median over 3 patches: sdK / sdMired / sdTint (meanK)')
for f in dict.fromkeys(r['file'] for r in d):
    print(f, ' | '.join('%s:%.0fK/%.1fmired/%.1ftint'%(k,*np.median(np.array(agg[(f,k)])[:,:3],axis=0)) for k in KS), 'meanK %.0f'%np.median(np.array(agg[(f,'25')])[:,3]))
