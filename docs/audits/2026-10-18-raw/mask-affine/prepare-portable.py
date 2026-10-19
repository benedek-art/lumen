from pathlib import Path
import re
r=Path('/workspace/scratch/2982a056243e/lumen-mask-affine'); p=Path(__file__).parent
(p/'helper.swift').write_text((r/'Sources/LumenCore/Interaction/BrushStabilizer.swift').read_text()+'\nenum Num { static func saturate(_ v: Double) -> Double { min(max(v,0),1) } }\n')
entries=[]
for name in ['BrushStabilizerTests','BrushStabilizerSourceMetricTests']:
 s=(r/f'Tests/LumenCoreTests/{name}.swift').read_text().replace('@testable import LumenCore','')
 (p/f'{name}.swift').write_text(s)
 methods=re.findall(r'func (test\w+)\(',s)
 entries.append('testCase(['+','.join(f'("{m}", {name}.{m})' for m in methods)+'])')
(p/'main.swift').write_text('import XCTest\nXCTMain(['+','.join(entries)+'])\n')
(p/'mutant.swift').write_text((p/'helper.swift').read_text().replace('scaleX = sourceWidth / long','scaleX = 1').replace('scaleY = sourceHeight / long','scaleY = 1'))
