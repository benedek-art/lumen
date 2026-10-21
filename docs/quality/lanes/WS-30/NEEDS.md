# WS-30 needs (from WS-58 / WS-01)

## Camera-log input spaces for creative LUTs (blocks SPEC L7)

Most LUTs photographers buy are written for a camera log: input S-Log3/S-Gamut3.Cine,
ARRI LogC3/AWG, Canon Log 3, output Rec.709 display. Lumen has two taps, both of which map a
space onto itself (`.display` sRGB → sRGB after the transform, `.log` LumenLog → LumenLog
before it). Such a LUT at the log tap is followed by Lumen's display transform a second
time; at the display tap it reads display code as camera log. Measured on the A7 IV frame
with a generated LumenLog→709 cube: mean ΔE2000 28.1 (log tap) and 30.5 (display tap)
against what the LUT means (`evidence/lut-log2709-both-taps-wrong.png`).

What is needed: a third tap value, e.g. `"sceneToDisplay"` with an `input` encoding
(`lumenLog`, `slog3`, `logc3`, `clog3`), which REPLACES S14 the way a Film Lab stock does
and outputs display-referred sRGB/Rec.709. `LUTReference.Tap` is an enum, so an older build
decoding an unknown case throws and drops the whole look: this needs a `pipelineVersion`
stamp raised only by recipes that use it (the `healSpotsPipelineVersion` pattern), which is
WS-58's (`Recipe.swift`, decoding, version table), and a new stage position, which is WS-01's
(`RR.render`, `RG.build`). WS-30 will write the stage body and its GPU twin once those exist.
