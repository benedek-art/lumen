#!/usr/bin/env python3
"""Install ENTIRE exact222 RenderGraph to qualify the CIColorMatrix regression.
Caller MUST back up candidate RenderGraph.swift and restore it on exit.
Keeps new kernel/availability definitions and identical strict tests; runs no tests.
This differs from historical0e fused-LUT causal evidence.
"""
import argparse, hashlib, subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source-root',type=Path,required=True)
a=p.parse_args()
relative='Sources/LumenPipeline/RenderGraph.swift'
revision='222cf96276d9e9c3a027c2f0ed18404a73401014'
source=subprocess.run(['git','-C',str(a.source_root),'show',revision+':'+relative],
                      check=True,stdout=subprocess.PIPE).stdout
(a.source_root/relative).write_bytes(source)
print('Installed entire222 CIColorMatrix route SHA256='+hashlib.sha256(source).hexdigest())
print('Candidate source restoration remains required; no tests executed.')
