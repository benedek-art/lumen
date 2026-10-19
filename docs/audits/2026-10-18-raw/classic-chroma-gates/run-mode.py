#!/usr/bin/env python3
import hashlib,json,os,subprocess,sys,time
from pathlib import Path
mode=sys.argv[1];assert mode in ['original','E','S']
base=Path('/workspace/scratch/2982a056243e');source_dir=Path(__file__).resolve().parent;reference=source_dir.parents[3]
root=base/({'original':'lumen-chroma-gates','E':'lumen-edge-gate-mutant','S':'lumen-smooth-gate-mutant'}[mode])
build=base/({'original':'build-final-core','E':'build-chroma-edge-mutant','S':'build-chroma-smooth-mutant'}[mode])/'x86_64-unknown-linux-gnu/release'
out=base/'classic-chroma-gate-evidence'/mode;out.mkdir(exist_ok=True)
assert not (out/'metrics.csv').exists(),'refusing to overwrite accepted measurements'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def manifest(r):return {str(p.relative_to(r/'Sources/LumenCore')):sha(p) for p in sorted((r/'Sources/LumenCore').rglob('*.swift'))}
source_manifest=manifest(root);ref_manifest=manifest(base/'lumen-chroma-gates');differences=[p for p in sorted(set(source_manifest)|set(ref_manifest)) if source_manifest.get(p)!=ref_manifest.get(p)]
assert differences==([] if mode=='original' else ['Image/DenoiseEngine.swift']),differences
if mode!='original':
 bp=json.loads((out/'build-provenance.json').read_text());assert bp['build_exit']==0 and bp['postbuild_core_sha256']==source_manifest
objects=sorted((build/'LumenCore.build').glob('*.swift.o'));assert objects
command=[str(base/'swift/usr/bin/swiftc'),'-O','-I',str(build/'Modules'),'-I',str(root/'Sources/CSQLite3'),'-Xcc','-I'+str(base/'swift-deps/usr/include'),'-L',str(base/'swift-deps/usr/lib/x86_64-linux-gnu'),'-lsqlite3',str(source_dir/'executed-harness.swift'),*map(str,objects),'-o',str(out/'harness')]
record={'mode':mode,'core_sha256':source_manifest,'reference_core_sha256':ref_manifest,'different_core_files':differences,'harness_sha256':sha(source_dir/'executed-harness.swift'),'compile_command':command,'module_sha256':sha(build/'Modules/LumenCore.swiftmodule'),'object_sha256':{p.name:sha(p) for p in objects},'scope':'actual CPU Classic seven calls on fixed synthetic hash; original/mutants separated, no production integration'}
env=os.environ.copy();env['LD_LIBRARY_PATH']=str(base/'swift-deps/usr/lib/x86_64-linux-gnu');env['SWIFT_BACKTRACE']='enable=no'
p=subprocess.run(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);(out/'compile.log').write_text(p.stdout);record['compile_exit']=p.returncode
if not p.returncode:
 prior=source_dir.parent/'classic-chroma-isolation/metrics.csv';execution=[str(out/'harness'),str(out),mode,str(prior)];record['execution_command']=execution;record['prior_csv_sha256']=sha(prior);record['binary_sha256']=sha(out/'harness');start=time.monotonic();p=subprocess.run(execution,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True);record['execution_exit']=p.returncode;record['execution_seconds']=time.monotonic()-start;(out/'execution.log').write_text(p.stdout)
(out/'provenance.json').write_text(json.dumps(record,indent=2,sort_keys=True)+'\n');print(p.stdout);print(mode,record.get('compile_exit'),record.get('execution_exit'))
raise SystemExit(record.get('execution_exit',p.returncode))
