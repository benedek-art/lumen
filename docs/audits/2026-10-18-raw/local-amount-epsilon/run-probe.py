#!/usr/bin/env python3
from pathlib import Path
import argparse,subprocess,hashlib,os,json,time
fixtures=Path(__file__).resolve().parent
parser=argparse.ArgumentParser(description="Run probe only in a fresh build output directory")
parser.add_argument('--output-dir', required=True, type=Path)
args=parser.parse_args();out=args.output_dir.resolve()
if out==fixtures or not (out/'build-provenance.json').is_file():parser.error('use output of build-core.py, never archived fixture directory')
allowed={'build-core','build.log','build-provenance.json'}
if any(p.name not in allowed for p in out.iterdir()):parser.error('output directory already contains probe artifacts; refusing overwrite')
bp=json.loads((out/'build-provenance.json').read_text())
if 'source_root' not in bp or 'build_root' not in bp:parser.error('new build-core.py provenance required')
root=Path(bp['source_root']);base=root.parent;build=Path(bp['build_root'])/'x86_64-unknown-linux-gnu/release'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
manifest={str(p.relative_to(root/'Sources/LumenCore')):sha(p)for p in sorted((root/'Sources/LumenCore').rglob('*.swift'))};assert bp['build_exit']==0 and manifest==bp['postbuild_core_sha256']
graph=(root/'Sources/LumenPipeline/RenderGraph.swift').read_text();a=graph.index('struct LocalPlan {');b=graph.index('/// Uploaded cube bytes',a);assert (fixtures/'LocalPlan-verbatim.swift').read_text()==graph[a:b]
objects=sorted((build/'LumenCore.build').glob('*.swift.o'));command=[str(base/'swift/usr/bin/swiftc'),'-O','-I',str(build/'Modules'),'-I',str(root/'Sources/CSQLite3'),'-Xcc','-I'+str(base/'swift-deps/usr/include'),'-L',str(base/'swift-deps/usr/lib/x86_64-linux-gnu'),'-lsqlite3',str(fixtures/'executed-probe.swift'),*map(str,objects),'-o',str(out/'probe')]
record={'source_head':bp['source_head'],'core_sha256':manifest,'compile_command':command,'probe_sha256':sha(fixtures/'executed-probe.swift'),'LocalPlan_sha256':sha(fixtures/'LocalPlan-verbatim.swift'),'zero_bypass_disabled_sha256':sha(fixtures/'LocalPlan-zero-bypass-disabled.swift'),'graph_sha256':sha(root/'Sources/LumenPipeline/RenderGraph.swift'),'module_sha256':sha(build/'Modules/LumenCore.swiftmodule'),'object_sha256':{p.name:sha(p)for p in objects},'scope':'intended CPU execution of verbatim GPU LocalPlan helper and actual Core LUT/Grade/RenderPlan; consult exit status, no GPU/CoreImage/maskcomposite execution'}
env=os.environ.copy();env['LD_LIBRARY_PATH']=str(base/'swift-deps/usr/lib/x86_64-linux-gnu');env['SWIFT_BACKTRACE']='enable=no';p=subprocess.run(command,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);(out/'compile.log').write_text(p.stdout);record['compile_exit']=p.returncode
if not p.returncode:
 cmd=[str(out/'probe'),str(out)];record['execution_command']=cmd;record['binary_sha256']=sha(out/'probe');start=time.monotonic();p=subprocess.run(cmd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT);record['execution_seconds']=time.monotonic()-start;record['execution_exit']=p.returncode;(out/'execution.log').write_text(p.stdout)
(out/'provenance.json').write_text(json.dumps(record,indent=2,sort_keys=True)+'\n');print(p.stdout);print(record.get('compile_exit'),record.get('execution_exit'));raise SystemExit(record.get('execution_exit',p.returncode))
