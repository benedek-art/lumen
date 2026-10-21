# WS-14 needs from other lanes

Nothing blocking. Two comment-only follow-ups in functions WS-14 does not own:

1. **WS-18 (`DetailEngine.applySharpen`, DetailEngine.swift ~line 969).** The comment
   "Every neighbouring spatial stage already tracks the long edge (`pyramidLevels`,
   `bandCenter`, …)" names two functions WS-14 removed. Presence now tracks the long edge
   through `DetailEngine.textureBand` / `clarityBand` (`PresenceBand.sigmas(longEdge:)`),
   continuously. The sharpening code is unaffected; only the comment is stale.
2. **WS-07 (`RenderGraph.boxBlur` comment).** It lists "Clarity, Texture" among the guided
   filters in the render. Texture and Clarity no longer use a guided filter (they use
   `RenderGraph.presenceBlur`, a 9-tap discrete Gaussian plus `CIGaussianBlur`).

`SpatialOps.swift`'s comments around `frameScale` / `fineBandLevel` also mention
`pyramidLevels` / `bandCenter` as siblings; same stale reference, same owner as (1).

`Decomposition.coherence` (the working-radius structure tensor with the EV/px strength
gate) is kept because Dehaze and sharpening read `Decomposition.gradient` from the same
call and a test reads it; neither presence control reads it any more.
