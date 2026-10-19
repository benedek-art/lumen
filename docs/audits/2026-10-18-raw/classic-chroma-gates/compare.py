#!/usr/bin/env python3
import array,csv,hashlib,json,math,re,sys
from pathlib import Path
base=Path(sys.argv[1]).resolve()
def pixels(path):
 raw=path.read_bytes();values=array.array('f');values.frombytes(raw);return raw,values
def compare(a,b):
 ra,va=pixels(a);rb,vb=pixels(b);assert len(va)==len(vb)==64*64*4
 return {'byteExact':ra==rb,'floatArrayExact':va==vb,'maxFloatDifference':max(abs(x-y)for x,y in zip(va,vb)),
         'a_sha256':hashlib.sha256(ra).hexdigest(),'b_sha256':hashlib.sha256(rb).hexdigest()}
def rows(mode):return list(csv.DictReader((base/mode/'metrics.csv').open()))
original={r['setting']:r for r in rows('original')}
result={'native_byteorder':sys.byteorder,'crossBuild':[],'withinBuildDetail':[],'observedComputedGate':{}}
for mode in ['E','S']:
 for row in rows(mode):
  name=row['setting'];r={'mode':mode,'setting':name,**compare(base/'original'/(name+'.rawf32'),base/mode/(name+'.rawf32')),
       'originalMSE':float(original[name]['mse']),'mutantMSE':float(row['mse']),
       'originalAmplitudeRetention':float(original[name]['amplitudeRetention']),'mutantAmplitudeRetention':float(row['amplitudeRetention'])}
  result['crossBuild'].append(r)
 log=(base/mode/'execution.log').read_text()
 result['observedComputedGate'][mode]=[{'detail':float(d),'chroma':float(c),'min':float(lo),'max':float(hi),'nonzero':int(n),'count':int(count)}
  for d,c,lo,hi,n,count in re.findall(r'CHROMA-GATE-OBSERVATION detail=(\S+) chroma=(\S+) min=(\S+) max=(\S+) nonzero=(\d+) count=(\d+)',log)]
 assert len(result['observedComputedGate'][mode])==6
 assert all(v['min']==0 and v['max']==0 and v['nonzero']==0 and v['count']==4096 for v in result['observedComputedGate'][mode])
for mode in ['original','E','S']:
 for block in ['iso-default-chroma-only','maximum-chroma-only']:
  for detail in [50,100]:
   a=base/mode/(block+'-detail-0.rawf32');b=base/mode/(block+'-detail-'+str(detail)+'.rawf32')
   result['withinBuildDetail'].append({'mode':mode,'block':block,'detail':detail,**compare(a,b)})
# Causal controls, not quality bars. The E override is multiplied by protection0.
for row in result['crossBuild']:
 if row['setting']=='off' or(row['mode']=='E' and row['setting'].endswith('-detail-0')):
  assert row['byteExact'] and row['floatArrayExact'],row
 if row['mode']=='S' and row['setting'].endswith('-detail-0'):
  assert not row['byteExact'] and not row['floatArrayExact'] and row['maxFloatDifference']>0,row
(base/'comparisons.json').write_text(json.dumps(result,indent=2,sort_keys=True)+'\n')
print(json.dumps(result['withinBuildDetail'],indent=2));print('controls pass')
