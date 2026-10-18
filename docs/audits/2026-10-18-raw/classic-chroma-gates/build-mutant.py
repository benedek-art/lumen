#!/usr/bin/env python3
import hashlib,json,os,subprocess,sys,time
from pathlib import Path
mode=sys.argv[1]
assert mode in ['E','S']
base=Path('/workspace/scratch/2982a056243e')
checkout=base/('lumen-edge-gate-mutant' if mode=='E' else 'lumen-smooth-gate-mutant')
build=base/('build-chroma-edge-mutant' if mode=='E' else 'build-chroma-smooth-mutant')
out=base/'classic-chroma-gate-evidence'/mode
reference=base/'lumen-chroma-gates'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def manifest(r):return {str(p.relative_to(r/'Sources/LumenCore')):sha(p) for p in sorted((r/'Sources/LumenCore').rglob('*.swift'))}
def git(*a):return subprocess.check_output(['git','-C',str(checkout),*a],text=True).strip()
pre=manifest(checkout);original=manifest(reference);changed=[p for p in sorted(set(pre)|set(original)) if pre.get(p)!=original.get(p)]
assert changed==['Image/DenoiseEngine.swift'],changed
command=[str(base/'swift/usr/bin/swift'),'build','-c','release','--scratch-path',str(build),'--jobs','2','--target','LumenCore','-Xcc','-I'+str(base/'swift-deps/usr/include')]
env=os.environ.copy();env['LD_LIBRARY_PATH']=str(base/'swift-deps/usr/lib/x86_64-linux-gnu');env['LIBRARY_PATH']=str(base/'swift-deps/usr/lib/x86_64-linux-gnu')
record={'mode':mode,'source_head':git('rev-parse','HEAD'),'source_status':git('status','--short'),'source_diff':git('diff','--','Sources/LumenCore/Image/DenoiseEngine.swift'),'prebuild_core_sha256':pre,'reference_core_sha256':original,'different_core_files':changed,'build_command':command,'swift_version':subprocess.check_output([str(base/'swift/usr/bin/swift'),'--version'],env=env,text=True),'scope':'isolated single gate diagnostic mutation plus disclosed scalar observation logging; never production integration'}
start=time.monotonic()
with (out/'build.log').open('w') as log:p=subprocess.run(command,cwd=checkout,env=env,stdout=log,stderr=subprocess.STDOUT)
record['build_exit']=p.returncode;record['build_seconds']=time.monotonic()-start;record['postbuild_core_sha256']=manifest(checkout)
assert record['postbuild_core_sha256']==pre,'source changed during build'
if not p.returncode:
 release=build/'x86_64-unknown-linux-gnu/release';record['module_sha256']=sha(release/'Modules/LumenCore.swiftmodule');record['object_sha256']={p.name:sha(p) for p in sorted((release/'LumenCore.build').glob('*.swift.o'))}
(out/'build-provenance.json').write_text(json.dumps(record,indent=2,sort_keys=True)+'\n');print(mode,p.returncode,record['build_seconds'])
raise SystemExit(p.returncode)
