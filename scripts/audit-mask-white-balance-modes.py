#!/usr/bin/env python3
"""Independent numerical witness for Lumen's relative/absolute mask WB modes.

Diagnostic only: this is not a production mode fix, conversion implementation,
calibration, aesthetic test or UI integration test. It imports no Lumen code and
neither reads nor changes photographs, recipes, tolerances or golden records.

Source provenance: benedek-art/lumen commit
4d7dcbd4542fa4bc34d6a6b8819ba048a1bf7486:
  Sources/LumenCore/Color/ColorSpaces.swift: CAT16 constants; Rec.2020
    chromaticities/D65; Kim Planckian fit; CIE daylight fit; XYZ(Y=1).
  Sources/LumenCore/Engine/ReferenceRenderer.swift: LocalWhiteBalance's
    5500 K relative anchor and 0.5 mired/Temp-unit mapping.
  Sources/LumenCore/Engine/WhiteBalanceEngine.swift: adaptation direction.
  Sources/LumenApp/MaskPanel.swift: entering Kelvin seeds the balanced neutral.

These equations are derived independently with NumPy linear algebra rather than
calling the Swift renderer or copying a UI mutation into a passing unit test.
The two selected whites are outside the 3500..4500 K locus blend, have tint=0,
and require no physical-tint guard. No claim about other parameter combinations
or camera files follows from this witness.

Representability proof: let A be the relative anchor's CAT16 cone white, R its
relative target and B the global balanced white. Relative gains are A/R.
An equivalent absolute target X must satisfy B/X=A/R componentwise, hence
X=B*R/A. Every Kelvin/tint target has XYZ Y=1. If inverseCAT16(X).Y !=1,
no Kelvin/tint pair can produce exactly this same full matrix at this balance.
This does not rule out approximate conversions or models with an extra gain.
"""

import json
import platform

import numpy as np

SOURCE_COMMIT = "4d7dcbd4542fa4bc34d6a6b8819ba048a1bf7486"
CAT16 = np.array([
    [0.401288, 0.650173, -0.051461],
    [-0.250268, 1.204414, 0.045854],
    [-0.002079, 0.048952, 0.953127],
], dtype=np.float64)
REC2020_XY = ((0.708, 0.292), (0.170, 0.797), (0.131, 0.046))
D65_XY = (0.3127, 0.3290)


def unit_y_xyz(x, y):
    return np.array([x / y, 1.0, (1.0 - x - y) / y], dtype=np.float64)


def witness_white_xyz(kelvin):
    """Only the Planckian/daylight branches exercised by this chosen witness."""
    if 2222 < kelvin <= 3500:
        x = (-0.2661239e9 / kelvin**3 - 0.2343589e6 / kelvin**2
             + 0.8776956e3 / kelvin + 0.179910)
        y = -0.9549476 * x**3 - 1.37418593 * x**2 + 2.09137015 * x - 0.16748867
    elif 4500 <= kelvin <= 7000:
        x = (0.244063 + 0.09911e3 / kelvin + 2.9678e6 / kelvin**2
             - 4.6070e9 / kelvin**3)
        y = -3.0 * x**2 + 2.870 * x - 0.275
    else:
        raise ValueError("Witness deliberately excludes other locus branches")
    return unit_y_xyz(x, y)


def main():
    primary_matrix = np.column_stack([unit_y_xyz(x, y) for x, y in REC2020_XY])
    rgb_to_xyz = primary_matrix @ np.diag(
        np.linalg.solve(primary_matrix, unit_y_xyz(*D65_XY)))
    xyz_to_rgb = np.linalg.inv(rgb_to_xyz)
    inverse_cat16 = np.linalg.inv(CAT16)

    relative_temp = 40.0
    balanced_kelvin = 3200.0
    anchor_kelvin = 5500.0
    relative_kelvin = 1e6 / (1e6 / anchor_kelvin - 0.5 * relative_temp)
    anchor = CAT16 @ witness_white_xyz(anchor_kelvin)
    relative_target = CAT16 @ witness_white_xyz(relative_kelvin)
    balanced = CAT16 @ witness_white_xyz(balanced_kelvin)

    relative_matrix = (xyz_to_rgb @ inverse_cat16 @ np.diag(anchor / relative_target)
                       @ CAT16 @ rgb_to_xyz)
    probe = np.array([0.4, 0.4, 0.4])
    before = relative_matrix @ probe
    # Kelvin seeded to the current balance is mathematically identity, independently
    # of implementation shortcuts: B/B gives three gains of exactly one.
    kelvin_seeded_identity = probe.copy()
    required_target_xyz = inverse_cat16 @ (balanced * relative_target / anchor)
    pixel_separation = float(np.max(np.abs(before - kelvin_seeded_identity)))
    required_y_separation = abs(float(required_target_xyz[1]) - 1.0)

    # Witness separations only, not accuracy gates for production rendering.
    assert pixel_separation > 0.01, pixel_separation
    assert required_y_separation > 1e-5, required_y_separation
    print(json.dumps({
        "diagnostic_only": True,
        "source_commit": SOURCE_COMMIT,
        "python": platform.python_version(),
        "numpy": np.__version__,
        "inputs": {"balanced_kelvin": balanced_kelvin, "relative_temp": relative_temp,
                   "tint": 0, "scene_linear_probe": probe.tolist()},
        "relative_before": before.tolist(),
        "kelvin_seeded_identity": kelvin_seeded_identity.tolist(),
        "max_scene_linear_separation": pixel_separation,
        "required_target_xyz": required_target_xyz.tolist(),
        "required_y_separation_from_one": required_y_separation,
        "interpretation": "Mode jump exists; exact Kelvin/tint-only conversion is unavailable for this witness",
    }, indent=2))


if __name__ == "__main__":
    main()
