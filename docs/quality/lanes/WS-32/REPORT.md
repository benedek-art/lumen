# Lane K3 report: Point Colour (WS-32) and Primaries (WS-33)

Branch `quality/k3-point-colour`, from `claude/inspiring-dirac-ulgpch` @ 9068ded.
Specs: `SPEC.md` here and `../WS-33/SPEC.md`. Measurements:
`tools/measure.py` (base and new builds side by side). Cross-lane asks: `NEEDS.md`.

## For the owner

1. Primaries Saturation used to be dead for half its travel (Red + did nothing at all, the
   old PROOF-03). It now runs the whole −100…+100 on every primary, and greys stay exact.
2. Point Colour now follows soft edges (defocused petals, satin sheen) instead of cutting
   them, Variance evens skin without flattening pores, and Lightroom's Hue/Sat/Lum range
   refinements exist, with a live strip under Range showing what is selected.
3. Not fixed: speckle on high-ISO frames with NR off. That needs a smoothed reference
   image fed to the point pass (WS-34, see NEEDS.md). With the default NR it is mild.
4. Try by hand: drag Range and the three refinements and watch the strip; pick a red on a
   portrait and push Variance to −100; Blue Saturation is the weakest primary (±10–15%).
5. Evidence: `evidence/ws32-2062-petal-edges.png`, `evidence/ws32-skin-variance.png`,
   `../WS-33/evidence/ws33-chart-red-saturation.png`.

## Verdict per spec line

PROOF_TABLE_PLACEHOLDER
