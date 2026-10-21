#!/usr/bin/env python3
"""Writes the Lightroom develop presets for the Lumen reference export (see CHECKLIST.md).

Every preset states the WHOLE baseline explicitly, so applying any preset to any photo
leaves exactly one control away from neutral. Baseline: Adobe Color, all Basic/Presence
sliders 0, sharpening/NR/lens corrections/vignette/grain off, as-shot white balance.
"""
import uuid, zipfile, os

BASE = {
    "WhiteBalance": "As Shot",
    "Exposure2012": "0.00", "Contrast2012": "0", "Highlights2012": "0", "Shadows2012": "0",
    "Whites2012": "0", "Blacks2012": "0", "Texture": "0", "Clarity2012": "0", "Dehaze": "0",
    "Vibrance": "0", "Saturation": "0",
    "Sharpness": "0", "LuminanceSmoothing": "0", "ColorNoiseReduction": "0",
    "LensProfileEnable": "0", "AutoLateralCA": "0", "EnableLensCorrections": "False",
    "PostCropVignetteAmount": "0", "GrainAmount": "0",
    "ColorGradeShadowLum": "0", "ColorGradeMidtoneLum": "0", "ColorGradeHighlightLum": "0",
    "SplitToningShadowSaturation": "0", "SplitToningHighlightSaturation": "0",
    "ColorGradeMidtoneSat": "0", "ColorGradeGlobalSat": "0",
}

def v(n):
    return f"+{n}" if isinstance(n, (int, float)) and n > 0 else str(n)

PRESETS = [("00 Baseline", {})]
for ev in (-2, -1, 1, 2):
    PRESETS.append((f"Exposure {ev:+d}", {"Exposure2012": f"{ev:+.2f}"}))
for key, name in [("Contrast2012", "Contrast"), ("Highlights2012", "Highlights"),
                  ("Shadows2012", "Shadows"), ("Whites2012", "Whites"), ("Blacks2012", "Blacks"),
                  ("Texture", "Texture"), ("Clarity2012", "Clarity"), ("Dehaze", "Dehaze"),
                  ("Vibrance", "Vibrance"), ("Saturation", "Saturation")]:
    for a in (-100, -50, 50, 100):
        PRESETS.append((f"{name} {a:+d}", {key: v(a)}))
PRESETS += [
    ("Temp 3200K", {"WhiteBalance": "Custom", "Temperature": "3200", "Tint": "0"}),
    ("Temp 7500K", {"WhiteBalance": "Custom", "Temperature": "7500", "Tint": "0"}),
    ("Tint -50", {"WhiteBalance": "Custom", "Temperature": "5500", "Tint": "-50"}),
    ("Tint +50", {"WhiteBalance": "Custom", "Temperature": "5500", "Tint": "+50"}),
    ("Temp 5500K Tint 0", {"WhiteBalance": "Custom", "Temperature": "5500", "Tint": "0"}),
    ("Vignette -50", {"PostCropVignetteAmount": "-50", "PostCropVignetteMidpoint": "50",
                      "PostCropVignetteRoundness": "0", "PostCropVignetteFeather": "50",
                      "PostCropVignetteHighlightContrast": "0", "PostCropVignetteStyle": "1"}),
    ("Vignette -100", {"PostCropVignetteAmount": "-100", "PostCropVignetteMidpoint": "50",
                       "PostCropVignetteRoundness": "0", "PostCropVignetteFeather": "50",
                       "PostCropVignetteHighlightContrast": "0", "PostCropVignetteStyle": "1"}),
    ("Grain 50 s25 r50", {"GrainAmount": "50", "GrainSize": "25", "GrainFrequency": "50"}),
    ("Grain 100 s50 r80", {"GrainAmount": "100", "GrainSize": "50", "GrainFrequency": "80"}),
    ("Grade Shadows teal", {"SplitToningShadowHue": "200", "SplitToningShadowSaturation": "40"}),
    ("Grade Highlights orange", {"SplitToningHighlightHue": "40", "SplitToningHighlightSaturation": "40"}),
    ("Grade Midtones magenta", {"ColorGradeMidtoneHue": "320", "ColorGradeMidtoneSat": "40"}),
    ("Curve S strong", {"ToneCurvePV2012": [(0, 0), (64, 40), (128, 128), (192, 215), (255, 255)]}),
]

def xmp(name, overrides):
    s = dict(BASE); s.update(overrides)
    curve = s.pop("ToneCurvePV2012", None)
    attrs = "\n   ".join(f'crs:{k}="{val}"' for k, val in s.items())
    curve_xml = ""
    if curve:
        lis = "".join(f"<rdf:li>{x}, {y}</rdf:li>" for x, y in curve)
        curve_xml = f"<crs:ToneCurvePV2012><rdf:Seq>{lis}</rdf:Seq></crs:ToneCurvePV2012>"
    return f'''<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
   crs:PresetType="Normal" crs:Cluster="" crs:UUID="{uuid.uuid4().hex.upper()}"
   crs:SupportsAmount="False" crs:SupportsColor="True" crs:SupportsMonochrome="True"
   crs:SupportsHighDynamicRange="True" crs:SupportsNormalDynamicRange="True"
   crs:SupportsSceneReferred="True" crs:SupportsOutputReferred="True"
   crs:CameraModelRestriction="" crs:Copyright="" crs:ContactInfo=""
   crs:Version="16.0" crs:ProcessVersion="11.0" crs:HasSettings="True"
   crs:CameraProfile="Adobe Color"
   {attrs}>
   <crs:Name><rdf:Alt><rdf:li xml:lang="x-default">{name}</rdf:li></rdf:Alt></crs:Name>
   <crs:Group><rdf:Alt><rdf:li xml:lang="x-default">Lumen Reference</rdf:li></rdf:Alt></crs:Group>
   {curve_xml}
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
'''

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Lumen-Reference-Presets.zip")
with zipfile.ZipFile(out, "w") as z:
    for name, o in PRESETS:
        z.writestr(f"Lumen Reference/{name}.xmp", xmp(name, o))
print(len(PRESETS), "presets ->", out)
