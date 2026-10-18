from pathlib import Path
import subprocess,os,json,hashlib
r=Path('/workspace/scratch/2982a056243e/lumen-inflight-keyword-review');out=r/'docs/audits/2026-10-18-raw/inflight-keyword-scan';build=Path('/workspace/scratch/2982a056243e/build-final-core');target=build/'x86_64-unknown-linux-gnu/release';swiftc='/workspace/scratch/2982a056243e/swift/usr/bin/swiftc'
env=dict(os.environ,LD_LIBRARY_PATH='/workspace/scratch/2982a056243e/swift-deps/usr/lib/x86_64-linux-gnu',LIBRARY_PATH='/workspace/scratch/2982a056243e/swift-deps/usr/lib/x86_64-linux-gnu',SWIFT_BACKTRACE='enable=no')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
manifest=json.loads((r/'docs/audits/2026-10-18-raw/classic-independent-projection/fresh-core-build-manifest.json').read_text())
assert all(sha(r/k)==v for k,v in manifest['core_sources'].items())
objects=sorted((target/'LumenCore.build').glob('*.o'));assert objects
records=[]
for mode in ['none','no-fallback','no-filter']:
 source=out/(mode+'-executed.swift');binary=Path('/workspace/scratch/2982a056243e')/('inflight-keyword-'+mode+'-release')
 cmd=['python3',str(out/'extract-witness.py'),'--source-root',str(r),'--output',str(source),'--mutant',mode]
 extracted=subprocess.run(cmd,text=True,capture_output=True);assert extracted.returncode==0,extracted.stderr
 compile=[swiftc,'-O','-I',str(target/'Modules'),'-Xcc','-fmodule-map-file='+str(r/'Sources/CSQLite3/module.modulemap'),str(source),*map(str,objects),'-o',str(binary)]
 compiled=subprocess.run(compile,env=env,capture_output=True,text=True)
 (out/(mode+'-compile.log')).write_text(compiled.stdout+compiled.stderr);assert compiled.returncode==0,compiled.stderr
 for legacy in [False,True]:
  args=[str(binary)]+(['--legacy'] if legacy else[]);run=subprocess.run(args,env=env,capture_output=True,text=True)
  name=mode+('-legacy' if legacy else '-removal');(out/(name+'.log')).write_text(run.stdout+run.stderr)
  expected=1 if (mode=='no-fallback' and not legacy)or(mode=='no-filter' and legacy) else 0
  assert run.returncode==expected,(name,run.returncode,run.stdout,run.stderr)
  records.append({'case':name,'expected_exit':expected,'actual_exit':run.returncode,'command':args,'source_sha256':sha(source),'binary_sha256':sha(binary),'extraction_command':cmd,'extraction_stdout':extracted.stdout,'compile_command':compile})
j={'qualification':'Portable actual optimized Core/extracted App method bodies, not compiled native CatalogService or asynchronous runtime. Legacy queued empty delta modeled per production recovery; native fixture executes it.','source_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=r,text=True).strip(),'core_source_comparison':{'matched':len(manifest['core_sources']),'mismatches':[],'built_manifest':'../classic-independent-projection/fresh-core-build-manifest.json','manifest_sha256':sha(r/'docs/audits/2026-10-18-raw/classic-independent-projection/fresh-core-build-manifest.json')},'module_sha256':sha(target/'Modules/LumenCore.swiftmodule'),'objects':{str(p.relative_to(build)):sha(p) for p in objects},'cases':records,'artifacts':{p.name:sha(p) for p in out.iterdir() if p.is_file()},'environment':{k:env[k] for k in ['LD_LIBRARY_PATH','LIBRARY_PATH','SWIFT_BACKTRACE']}}
(out/'provenance.json').write_text(json.dumps(j,indent=2)+'\n')
for v in records:print(v['case'],v['actual_exit'])
