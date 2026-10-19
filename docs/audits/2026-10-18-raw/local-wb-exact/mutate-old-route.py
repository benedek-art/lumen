#!/usr/bin/env python3
"""Install the ENTIRE exact original RenderGraph for a causal baseline.
Caller MUST back up the candidate file and restore it on exit. Does not run tests.
The new tests intentionally use only APIs already present in this original source.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source-root',type=Path,required=True)
a=p.parse_args()
relative='Sources/LumenPipeline/RenderGraph.swift'
source=subprocess.run(['git','-C',str(a.source_root),'show','0e9e4a483e37e3fd5be04daec159a0ccdba72609:'+relative],
                      check=True,stdout=subprocess.PIPE).stdout
(a.source_root/relative).write_bytes(source)
print('Installed entire 0e9e4a4 RenderGraph.swift SHA256='+hashlib.sha256(source).hexdigest())
print('Candidate source restoration remains required.')
