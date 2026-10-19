#!/usr/bin/env python3
"""Compile/run the portable diagnostic once, after full Core source hash matching.
Requires a NEW output directory. Does not modify production source or run native tests.
"""
import argparse, hashlib, json, os, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source-root',type=Path,required=True)
p.add_argument('--build-release',type=Path,required=True)
p.add_argument('--build-manifest',type=Path,required=True)
p.add_argument('--swiftc',type=Path,required=True)
p.add_argument('--dependency-root',type=Path,required=True)
p.add_argument('--output-dir',type=Path,required=True)
a=p.parse_args()
out=a.output_dir.resolve()
if out.exists():p.error('output directory already exists')
root=a.source_root.resolve(); expected=json.loads(a.build_manifest.read_text())
actual={str(q.relative_to(root/'Sources/LumenCore')):hashlib.sha256(q.read_bytes()).hexdigest()
        for q in sorted((root/'Sources/LumenCore').rglob('*.swift'))}
out.mkdir(parents=True,exist_ok=False)
comparison={'buildManifest':str(a.build_manifest.resolve()),'matches':expected==actual,
            'sources':actual,'sourceCount':len(actual)}
(out/'source-comparison.json').write_text(json.dumps(comparison,indent=2)+'\n')
if expected!=actual:p.error('actual Core source does not match build manifest; no compilation/execution')
objects=sorted((a.build_release/'LumenCore.build').glob('*.o'))
assert objects
source=Path(__file__).resolve().with_name('main.swift')
command=[str(a.swiftc),'-O','-I',str(a.build_release/'Modules'),'-I',str(root/'Sources/CSQLite3'),
         '-Xcc','-I'+str(a.dependency_root/'usr/include'),'-L',str(a.dependency_root/'usr/lib/x86_64-linux-gnu'),
         '-lsqlite3',str(source),*[str(q) for q in objects],'-o',str(out/'probe')]
env=os.environ.copy();lib=str(a.dependency_root/'usr/lib/x86_64-linux-gnu')
env.update(LD_LIBRARY_PATH=lib,LIBRARY_PATH=lib,SWIFT_BACKTRACE='enable=no')
provenance={'command':command,'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),
            'environment':{k:env[k] for k in ('LD_LIBRARY_PATH','LIBRARY_PATH','SWIFT_BACKTRACE')}}
(out/'command.json').write_text(json.dumps(provenance,indent=2)+'\n')
version=subprocess.run([str(a.swiftc),'--version'],env=env,capture_output=True,text=True)
(out/'compiler-version.log').write_text(version.stdout+version.stderr)
with(out/'compile.log').open('w') as f:c=subprocess.run(command,env=env,stdout=f,stderr=subprocess.STDOUT)
status={'compileExit':c.returncode}
if c.returncode==0:
 with(out/'execution.log').open('w')as f:r=subprocess.run([str(out/'probe')],env=env,stdout=f,stderr=subprocess.STDOUT)
 status['executionExit']=r.returncode
(out/'status.json').write_text(json.dumps(status,indent=2)+'\n')
print(json.dumps(status))
raise SystemExit(status.get('executionExit',c.returncode))
