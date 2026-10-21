# WS-13 Display transform: report

**STATUS: PAUSED, UNVERIFIED.** The programme was paused mid round 3. No independent verifier has run. The tip commit holds round-3 work in progress (bleach onset moved to +1.5 EV) that has NOT been through the Linux suite or ControlProofTests. Last fully tested state: `5a1b43d` (round 2). There, the Linux suite (Swift 6.1.2) passes 3055/3055, and ControlProofTests fails one floor: `primaries.gPurity` 39.7 < 44. Do not merge until a verifier passes.

## For the owner
- Purple blues are fixed in the maths: the outset undoes the inset rotation, and highlights bleach to white at constant hue. Blue probes and the hue ring hold within about 1e-12° on the exact transform, against +49° (sRGB blue) and +7° (sky) before.
- Lumen still renders about 0.9 EV darker than Adobe's default curve, and real RAWs never reach code 255. The fix is display mid-grey 0.25 (already built, one constant) together with WS-05 moving the white anchor from +5 to about +3 EV. Lifting mid-grey alone broke other lanes' highlight proofs.
- Saturation lift, the dead skew range and the black-target range mismatch are addressed but unverified.
- Remaining work: finish round 3 (gPurity floor), then run the verifier and produce evidence images.

## Round history
- Audit: real RAWs render about 0.86 EV darker than the ACR3 curve. Sensor white lands at code 221. Blues drift +6…+9° (rotation) and up to +49° (max-channel shoulder blend). ColorChecker chroma is 0.92× truth.
- Round 1 (`44ab5e1`): mid 0.25, rotation undone, constant-hue path to white. It broke four highlight-authority proof floors and two reversal ceilings in other lanes.
- Round 2 (`5a1b43d`): mid back to 0.18 (scene/display split kept). Both ceilings were root-caused and fixed in DisplayTransform. One floor is left: gPurity.
- Round 3 (tip, WIP): bleach onset +1.5 EV to restore gPurity; spec line 3.8 amended in `1d4d9b5`.

Per-line numbers as of round 2 are in `BUILD-NOTES.md`. The spec is `SPEC.md`. No evidence images have been produced yet.
