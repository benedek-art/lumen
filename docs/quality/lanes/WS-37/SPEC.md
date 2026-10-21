# WS-37 Printer lights: acceptance spec

Owned: `GradeEngine.pointsPerStop/masterPointLimit/trimPointLimit/printerLightGains`,
`LookPanel.printerLightsSection/printerRow`, `PrinterLightRow`, `PrinterLights`.
Lab convention: 1 point = 1/12 stop of printing exposure on one channel (Kodak/Resolve,
0.025 log E). Sign is image-referred like Resolve: +R makes the picture redder (a lab
printer's +red light makes the print cyan; the row's help names both directions).

| # | Claim | Threshold | Measured by |
|---|---|---|---|
| P1 | 12 points = 2.0× exactly (master and trims); every step is 1/12 stop in log | bit-exact; step error < 1e-12 | `PrinterLightsLabTests.testP1…` |
| P2 | R = G = B = k is the master at k | S6 matrix bit-identical, k = −24…24 | `testP2…`; render: 0 code difference on `grey_ramp` |
| P3 | Master +12 = Exposure +1 EV; −30 = −2.5 EV | S6 matrix bit-identical | `testP3…`; render: 0 code difference |
| P4 | A trim on a neutral ramp moves every tone (OKLab L 0.15–0.95) toward one hue; shift peaks in mid-tones and rolls off toward white like a print | hue spread ±5° of the mean | `testP4…` (R+6, B−6, G+4) |
| P5 | Limits ±48 master, ±24 trims; past them renders as the limit | exact | `testP5…` |

Visual claims:
- V1 `evidence/printer-red-trim-gx85.png`: −12…+12 red steps look equal in size and symmetric (cyan ↔ red), no hue drift in the sky or grass beyond the trim's own.
- V2 `evidence/printer-blue-trim-grey-ramp.png`: the ramp stays one hue per row from shadow to highlight.
