#!/usr/bin/env python3
from pathlib import Path
import argparse,hashlib,json,subprocess,os,time
parser=argparse.ArgumentParser(description="Build fresh Core without overwriting archived evidence")
parser.add_argument('--output-dir', required=True, type=Path)
parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[4])
args=parser.parse_args();root=args.source_root.resolve();base=root.parent;out=args.output_dir.resolve()
if out.exists():parser.error('--output-dir must not exist')
out.mkdir(parents=True);build=out/'build-core'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def manifest():return {str(p.relative_to(root/'Sources/LumenCore')):sha(p)for p in sorted((root/'Sources/LumenCore').rglob('*.swift'))}
pre=manifest();command=[str(base/'swift/usr/bin/swift'),'build','-c','release','--scratch-path',str(build),'--jobs','2','--target','LumenCore','-Xcc','-I'+str(base/'swift-deps/usr/include')];env=os.environ.copy();env['LD_LIBRARY_PATH']=str(base/'swift-deps/usr/lib/x86_64-linux-gnu');env['LIBRARY_PATH']=env['LD_LIBRARY_PATH'];record={'source_root':str(root),'build_root':str(build),'source_head':subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip(),'source_status':subprocess.check_output(['git','-C',str(root),'status','--short'],text=True),'prebuild_core_sha256':pre,'command':command};start=time.monotonic()
with (out/'build.log').open('w')as log:p=subprocess.run(command,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT)
record['build_exit']=p.returncode;record['build_seconds']=time.monotonic()-start;record['postbuild_core_sha256']=manifest();assert pre==record['postbuild_core_sha256'];(out/'build-provenance.json').write_text(json.dumps(record,indent=2,sort_keys=True)+'\n');print(p.returncode,record['build_seconds']);raise SystemExit(p.returncode)
