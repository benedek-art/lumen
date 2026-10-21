# Lane M6 measurement tools

`maskh` rasterizes Mask JSON through `MaskRaster.combine` on a corpus `.lfi` and writes
float32 alphas (`<w:u32><h:u32><f32…>`). It depends on the repository root by relative
path; SwiftPM names that dependency after the root directory, so the product reference
in `Package.swift` says `package: "lumen"`; change it if your clone has another name.

```
swift build -c release --package-path maskh
python3 cases.py OUT refine     # writes OUT/ref*.json job files (CORPUS_LFI overrides corpus/lfi)
python3 cases.py OUT algebra    # writes OUT/alg*.json
for f in OUT/*.json; do maskh/.build/release/maskh $f; done
python3 refcheck.py OUT         # coverage, speckle, stair, per-pixel wrong-way, per control value
python3 algcheck.py OUT         # fold semantics against closed forms, references, inverts
python3 leak.py OUT_BEFORE OUT_AFTER   # Follow's off-hue leak (R7)
python3 compare.py BEFORE AFTER ref8559_C edge -50,0,50 y0,y1,x0,x1 sheet.png
```

Needs numpy, scipy, Pillow. `gfproto.py` is the numpy prototype of the colour guided
filter and the OKLab conversion `leak.py` uses; `mtool.py` holds the metrics.
