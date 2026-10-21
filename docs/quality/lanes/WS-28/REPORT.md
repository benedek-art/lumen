# WS-28 Lens corrections: report

Lane C3, branch `quality/c3-lens` from `claude/inspiring-dirac-ulgpch`.

## For the owner

- Your A7 IV and GX85 RAWs get distortion fixed by Apple, nothing else. Lumen now adds Remove CA (on by default, as in Lightroom), the A7 IV's own vignetting record (+0.46 EV in the outer ring on the FE 50 F2.5) and Lightroom-style Defringe.
- GX85 vignetting is still uncorrected: the RW2 carries no vignetting data, so fixing it needs a lens-profile database this build doesn't have.
- Remove CA cuts corner colour misregistration by 66–94% on the corpus frames that have it (VERIFY_CA_SUMMARY), and leaves CA-free frames bit-identical.
- Try by hand: the Lens section (Crop column) on a GX85 and an A7 IV file; Defringe Purple 5 on a backlit branch; check that toggling Remove CA on a JPEG behaves.
- Evidence: `evidence/4213-treeline-ca.png`, `evidence/6929-vignette.png`, `evidence/1840-corner-ca.png`.

VERDICT_PLACEHOLDER
