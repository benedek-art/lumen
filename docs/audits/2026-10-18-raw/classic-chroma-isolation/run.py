#!/usr/bin/env python3
"""Reproduce nine-call diagnostic. Paths below identify the executed cloud build."""
from pathlib import Path
import hashlib,json,os,subprocess,time,sys
root=Path(__file__).resolve().parents[4]
source_dir=Path(__file__).resolve().parent
if len(sys.argv)!=2: raise SystemExit('usage: python run.py NEW_OUTPUT_DIRECTORY')
out=Path(sys.argv[1]).resolve()
out.mkdir(parents=True,exist_ok=False)
build=Path('/workspace/scratch/2982a056243e/build-final-core/x86_64-unknown-linux-gnu/release')
built_source=Path('/workspace/scratch/2982a056243e/lumen-pick-index-next')
swiftc=Path('/workspace/scratch/2982a056243e/swift/usr/bin/swiftc')
deps=Path('/workspace/scratch/2982a056243e/swift-deps/usr')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def manifest(p): return {str(f.relative_to(p/'Sources/LumenCore')):sha(f) for f in sorted((p/'Sources/LumenCore').rglob('*.swift'))}
def git(p,*args): return subprocess.check_output(['git','-C',str(p),*args],text=True).strip()
current,built=manifest(root),manifest(built_source)
assert current==built,'full Core source mismatch'
objects=sorted((build/'LumenCore.build').glob('*.swift.o'))
assert objects
command=[str(swiftc),'-O','-I',str(build/'Modules'),'-I',str(root/'Sources/CSQLite3'),'-Xcc','-I'+str(deps/'include'),'-L',str(deps/'lib/x86_64-linux-gnu'),'-lsqlite3',str(source_dir/'executed-harness.swift'),*map(str,objects),'-o',str(out/'harness')]
record={'source_head':git(root,'rev-parse','HEAD'),'source_status':git(root,'status','--short'),'built_checkout_head':git(built_source,'rev-parse','HEAD'),'built_checkout_status':git(built_source,'status','--short'),'current_core_sha256':current,'built_checkout_core_sha256':built,'differing_core_files':[],'compile_command':command,'harness_sha256':sha(source_dir/'executed-harness.swift'),'module_sha256':sha(build/'Modules/LumenCore.swiftmodule'),'object_sha256':{p.name:sha(p) for p in objects},'scope':'fresh release actualClassic CPU; current fullCore snapshot equal declared builtcheckout; object provenance from fresh-core build recorded separately; no whole-app/native/GPU/camera claim'}
env=os.environ.copy();env['LD_LIBRARY_PATH']=str(deps/'lib/x86_64-linux-gnu');env['SWIFT_BACKTRACE']='enable=no'
p=subprocess.run(command,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(out/'compile.log').write_text(p.stdout);record['compile_exit']=p.returncode
if not p.returncode:
 execution=[str(out/'harness'),str(out)];record['execution_command']=execution;record['binary_sha256']=sha(out/'harness');start=time.monotonic();p=subprocess.run(execution,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);record['execution_seconds']=time.monotonic()-start;record['execution_exit']=p.returncode;(out/'execution.log').write_text(p.stdout)
(out/'provenance.json').write_text(json.dumps(record,indent=2,sort_keys=True)+'\n');print(p.stdout);print(record.get('compile_exit'),record.get('execution_exit'))
raise SystemExit(record.get('execution_exit',p.returncode))
