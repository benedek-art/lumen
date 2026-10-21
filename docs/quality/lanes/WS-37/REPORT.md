# WS-37 Printer lights: report (lane K4)

## For the owner

1. Printer lights already behaved like a lab's. This lane measured and pinned it: 12 points is exactly one stop, equal R/G/B trims are the master, and a trim tints every tone toward one hue.
2. The only change is the help text, which now states the sign: plus makes the picture redder, Resolve's convention. A lab timer adding red light makes the print cyan.
3. Try by hand: with Printer Lights expanded, type a "." or "," into the "Name this look" field. The steppers bind those keys without a modifier, and SwiftUI may steal them from the text field (can't be checked on Linux).

Best evidence: `evidence/printer-red-trim-gx85.png`.

## Verdict per spec line

Final verifier: VERDICT_PLACEHOLDER

| # | Verdict | Measured |
|---|---|---|
| P1 12 pt = 1 stop, equal log steps | PASS | bit-exact; step error < 1e-12 |
| P2 R=G=B=k is master k | PASS | S6 matrix bit-identical k = −24…24; 0-code difference on the grey ramp |
| P3 master +12 = Exposure +1 EV | PASS | bit-identical; −30 = −2.5 EV too |
| P4 one hue per trim across a neutral ramp, print-like roll-off | PASS | hue spread ≤ 0.45° (bound 5°); chroma peaks at OKLab L 0.71–0.90 |
| P5 limits ±48 / ±24 | PASS | exact |
| V1 red trim −12…+12 even and symmetric | PASS | |
| V2 grey ramp holds one hue per row | PASS | |

## Notes

- The gains are applied after white balance in linear Rec.2020, which is a lab's log-exposure offset. `PrinterLightsLabTests` holds the measurements.
- At +R in mid-tones, G and B also move by a couple of codes (the display transform's hue preservation). The hue of the shift still holds within 0.45°.
