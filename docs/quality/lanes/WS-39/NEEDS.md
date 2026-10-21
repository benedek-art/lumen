# WS-39 needs from other lanes

## WS-38 (film stocks)

1. **cine250D halation default is too strong.** Kodak Vision3 250D carries a rem-jet
   anti-halation backing in camera, so it should have among the least halation of the
   roster. It currently has Portra's strength `RGB(0.050, 0.015, 0.000)` with default
   Amount 30 on a smaller (24.9 mm) gate, which makes its default halo the second
   strongest and the widest of the six (`measure.py` M10). Proposed:
   `halationDefault: 10` (keep the strengths) so it lands at or under Ektar.
2. **No CineStill 800T-type stock.** CineStill is Vision3 500T with the rem-jet removed:
   the extreme red bloom around lights is its signature. With WS-39's model, Portra at
   Amount 100, Size 2, Redness 80 approximates it; a dedicated stock would make it one
   click. Proposed literals: `halationStrength RGB(0.12, 0.03, 0.0)`,
   `halationDefault 70`, `halationRedness 70`, tungsten-balanced curve. A per-stock
   default halo Size (not a recipe key today) would let it default to ~1.6.

Both are stock literals in `FilmStock` definitions (FilmLab.swift 228-400), owned by WS-38.
WS-39 changed none of them.
