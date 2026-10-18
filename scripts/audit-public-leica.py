# Inspect the SHA-pinned CC0 raw.pixls.us Leica1087 fixture only.
# Usage: python3 scripts/audit-public-leica.py /path/to/1087.DNG > independent-decode.json
# Dependencies used for recorded evidence: rawpy==0.27.1 numpy==2.5.4 tifffile.
# This checks nonempty content, not colorimetric correctness.
import sys, json, hashlib, time
from pathlib import Path
import numpy as np, rawpy, tifffile
p=Path(sys.argv[1])
assert hashlib.sha256(p.read_bytes()).hexdigest()=='3fb74d1fc402daaa48a9c3f1d6279d7e85fb58dfdaf816f036927d49ab228977'
def stats(a):
 a=np.asarray(a)
 return dict(shape=list(a.shape),dtype=str(a.dtype),min=float(a.min()),max=float(a.max()),mean=float(a.mean()),std=float(a.std()),nonzero=int(np.count_nonzero(a)),pixels=int(a.size),p01_p50_p99=np.percentile(a,[1,50,99]).tolist())
r={'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size,'rawpy':rawpy.__version__,'libraw':rawpy.libraw_version,'numpy':np.__version__}
with rawpy.imread(str(p)) as raw:
 r['sizes']=str(raw.sizes)
 for attr in ['num_colors','color_desc','black_level_per_channel','white_level','camera_white_level_per_channel','camera_whitebalance','daylight_whitebalance','raw_pattern','raw_type']:
  try: r[attr]=str(getattr(raw,attr))
  except Exception as e: r[attr]=repr(e)
 r['raw_visible']=stats(raw.raw_image_visible)
 for label,kwargs in [('linear_no_auto',dict(gamma=(1,1),no_auto_bright=True,output_bps=16,use_camera_wb=False,use_auto_wb=False,bright=1)),('default',{})]:
  try:
   start=time.perf_counter(); out=raw.postprocess(**kwargs)
   r[label]=stats(out);r[label]['seconds']=time.perf_counter()-start
  except Exception as e:r[label]={'error':repr(e)}
with tifffile.TiffFile(p) as tf:
 r['tiff_tags']={}
 def pagevisit(page,label):
  tags={}
  for tag in page.tags.values():
   if tag.name in ['Make','Model','ExposureTime','FNumber','ISOSpeedRatings','PhotometricInterpretation','BitsPerSample','SamplesPerPixel','BlackLevel','WhiteLevel','BaselineExposure','AsShotNeutral','ColorMatrix1','ColorMatrix2','CalibrationIlluminant1','CalibrationIlluminant2']:
    tags[tag.name]=str(tag.value)
  r['tiff_tags'][label]=tags
  for j,sub in enumerate(page.pages or []): pagevisit(sub,label+f'/sub{j}')
 for i,page in enumerate(tf.pages):pagevisit(page,f'ifd{i}')
 exif=tf.pages[0].tags['ExifTag'].value
 r['exposure_metadata']={k:str(exif[k]) for k in ['ExposureTime','ISOSpeedRatings','ShutterSpeedValue','ApertureValue','ExposureBiasValue','FocalLength'] if k in exif}
print(json.dumps(r,indent=2,sort_keys=True))

