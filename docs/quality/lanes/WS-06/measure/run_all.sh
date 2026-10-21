#!/usr/bin/env bash
# WS-06 Contrast & Pivot: run every measurable SPEC line and print one row per line.
#
#   bash docs/quality/lanes/WS-06/measure/run_all.sh [BIN] [CORPUS] [WORK]
#
#   BIN     release lumen-render (default: $(swift build -c release --show-bin-path)/lumen-render)
#           Build it first:  swift build -c release --product lumen-render
#           The engine probe links against the LumenCore objects next to BIN, so BIN and
#           those objects must come from the same build (they do after the command above).
#   CORPUS  corpus directory with lfi/ and synthetic/ (default: <repo>/corpus)
#   WORK    scratch directory for renders (default: /tmp/ws06-measure). Renders are
#           cached per BIN mtime, so a rebuilt binary re-renders everything.
#
# Output: `Sxx  KEY  measured  rule  baseline  PASS|FAIL|OPEN|INFO`. Exit status 1 if any
# lane line FAILs. OPEN lines are requirements this lane cannot meet inside its own
# functions (see SPEC S22 and NEEDS.md); they are printed, never counted as PASS.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../../../.." && pwd)"
export PATH=/opt/swift/usr/bin:$PATH
BIN="${1:-$(cd "$REPO" && swift build -c release --show-bin-path)/lumen-render}"
CORPUS="${2:-$REPO/corpus}"
WORK="${3:-/tmp/ws06-measure}"
BUILD="$(cd "$(dirname "$BIN")" && pwd)"
mkdir -p "$WORK"
RAW="$WORK/raw.txt"; : > "$RAW"

# 1. engine probe, linked against the release LumenCore objects
swiftc -O -I "$BUILD/Modules" \
    -Xcc -fmodule-map-file="$REPO/Sources/CSQLite3/module.modulemap" -I "$REPO/Sources/CSQLite3" \
    "$HERE/probe.swift" "$BUILD"/LumenCore.build/*.o -lsqlite3 -o "$WORK/probe" 2> "$WORK/probe.build.log" \
    || { cat "$WORK/probe.build.log"; exit 2; }
"$WORK/probe" >> "$RAW"
# 2. rendered measurements
python3 -I "$HERE/measure.py" "$BIN" "$CORPUS" "$WORK" all >> "$RAW"
# 3. panel literals
python3 -I "$HERE/ui_check.py" "$REPO" >> "$RAW"

python3 -I - "$RAW" <<'EOF'
import sys
vals, notes = {}, {}
for line in open(sys.argv[1]):
    k, v, *rest = line.split(" ", 2)
    vals[k] = float(v); notes[k] = rest[0].strip() if rest else ""
# spec id, key, rule, baseline (measured on the audit build, recorded in SPEC.md), kind
RULES = [
 ("S1",  "S1_identity_mismatches",            "== 0",          "0",      "lane"),
 ("S2",  "P5_identity_png_mismatches",        "== 0",          "0",      "lane"),
 ("S3",  "S2_min_derivative",                 ">= 0.40",       "0.400",  "lane"),
 ("S3",  "S2_min_derivative_positive_c",      ">= 0.50",       "0.4105", "lane"),
 ("S3",  "S2_full_scale_inversions",          "== 0",          "0",      "lane"),
 ("S4",  "S3_fixed_point_error",              "<= 1e-12",      "0",      "lane"),
 ("S5",  "S4_slope_plus100",                  "in 1.60 2.00",  "1.600",  "lane"),
 ("S5",  "S4_slope_minus100",                 "in 0.40 0.50",  "0.400",  "lane"),
 ("S5",  "S4_slope_nonincreasing_steps",      "== 0",          "0",      "lane"),
 ("S5",  "S4_slope_plus50",                   "info",          "1.300",  "info"),
 ("S5",  "S4_slope_minus50",                  "info",          "0.700",  "info"),
 ("S5",  "S4_log2_asymmetry_100",             "info",          "-0.644", "info"),
 ("S6",  "S4_limiter_touches_contrast",       "<= 1e-9",       "0",      "lane"),
 ("S7",  "S5_shift_minus6EV_c100",            "abs<= 0.55",    "-1.354", "lane"),
 ("S7",  "S5_shift_minus7EV_c100",            "abs<= 0.30",    "-0.792", "lane"),
 ("S8",  "R3_top_span_ratio_c+100",           ">= 0.55",       "0.419",  "lane"),
 ("S8",  "R3_top_span_ratio_c+50",            ">= 0.75",       "0.686",  "lane"),
 ("S8",  "S5_log_span_2to4_c100",             "info",          "1.363",  "info"),
 ("S9",  "P1_code0_pct_c+100_1346",           "<= 7.0",        "8.968",  "lane"),
 ("S9",  "P1_code0_pct_c+100_4694",           "<= 3.6",        "4.379",  "lane"),
 ("S9",  "P1_code0_pct_c+100_2348",           "<= 2.0",        "3.144",  "lane"),
 ("S10", "P2_code255_pct_983_exp+1.5_c+100",  "<= 0.45",       "0.439",  "lane"),
 ("S11", "R2_grey_clipped_or_reversed_columns","== 0",         "0",      "lane"),
 ("S11", "R1_pivot_code_drift",               "<= 1.0",        "0.5",    "lane"),
 ("S12", "R4_mid_slope_c+100",                ">= 80",         "85",     "lane"),
 ("S12", "R4_mid_slope_c-100",                "<= 26",         "21",     "lane"),
 ("S13", "S8_authority_tone.contrast",        ">= 57",         "68.382", "lane"),
 ("S13", "S8_frontLoading_tone.contrast",     "in 0.42 0.58",  "0.635",  "lane"),
 ("S13", "S8_deadSteps_tone.contrast",        "== 0",          "0",      "lane"),
 ("S13", "S8_step_peak_ratio",                "info",          "2.304",  "info"),
 ("S14", "S6_hl-100_at_c+100",                ">= 0.845",      "0.8460", "lane"),
 ("S14", "S6_sh+100_at_c-100",                ">= 0.619",      "0.6192", "lane"),
 ("S14", "S6_worst_paired_scale",             ">= 0.619",      "0.6192", "lane"),
 ("S14", "S6_four_way_corner_scale",          ">= 0.620",      "0.6468", "lane"),
 ("S14", "S6_moderate_band_scale",            ">= 0.990",      "0.9939", "lane"),
 ("S14", "S6_composed_min_derivative",        ">= -0.001",     "-0.00084","lane"),
 ("S15", "S7_lut_vs_stops_max_err_EV",        "<= 1e-9",       "0",      "lane"),
 ("S15", "S7_cube32_interp_err_EV",           "<= 0.105",      "0.1013", "lane"),
 ("S15", "S7_cube65_interp_err_EV",           "<= 0.035",      "0.0249", "lane"),
 ("S15", "S7_golden_c60_cube32_interp_err_EV","<= 0.036",      "0.0341", "lane"),
 ("S15", "S7_golden_c60_cube65_interp_err_EV","<= 0.0090",     "0.0084", "lane"),
 ("S16", "P3_step_ratio_6929",                "<= 1.6",        "2.279",  "lane"),
 ("S16", "P3_step_ratio_2545",                "<= 1.6",        "2.153",  "lane"),
 ("S16", "P3_adjacent_step_ratio_6929",       "<= 1.15",       "1.050",  "lane"),
 ("S16", "P3_adjacent_step_ratio_2545",       "<= 1.15",       "1.044",  "lane"),
 ("S16", "P3_rms_nonincreasing_6929",         "== 0",          "0",      "lane"),
 ("S16", "P3_rms_nonincreasing_2545",         "== 0",          "0",      "lane"),
 ("S17", "P4_sym_100_6929",                   "in 0.75 1.33",  "0.558",  "lane"),
 ("S17", "P4_sym_100_2545",                   "in 0.75 1.33",  "0.653",  "lane"),
 ("S17", "P4_sym_50_6929",                    "in 0.80 1.25",  "0.750",  "lane"),
 ("S17", "P4_sym_50_2545",                    "in 0.80 1.25",  "0.806",  "lane"),
 ("S18", "C1_hue_mean_abs_deg",               "<= 0.75",       "0.492",  "lane"),
 ("S18", "C1_hue_max_abs_deg",                "<= 2.5",        "1.984",  "lane"),
 ("S19", "C2_sat_CL_pct_c+100",               "abs<= 3",       "-1.562", "lane"),
 ("S19", "C2_sat_CL_pct_c-100",               "abs<= 3",       "0.250",  "lane"),
 ("S19", "C2_photo_CL_change_pct_6929",       "<= 1",          "0.159",  "lane"),
 ("S19", "C2_photo_CL_change_pct_2545",       "<= 1",          "0.341",  "lane"),
 ("S20", "C2_sat_CL_pct_c+100",               "in 6 15",       "-1.562", "open"),
 ("S20", "C2_sat_CL_pct_c+50",                "in 3 8",        "-0.614", "open"),
 ("S20", "C2_sat_CL_pct_c-100",               "in -20 -8",     "0.250",  "open"),
 ("S21", "S8_authority_pivot_-3_3",           ">= 20",         "84.094", "lane"),
 ("S21", "S9_min_move_per_quarter_EV_pivot_in_pm3", ">= 0.05", "0.075",  "lane"),
 ("S21", "S8_authority_pivot_-4_4",           "info",          "100.288","info"),
 ("S21", "S9_info_pivot3.5_vs_4_at_whites100","info",          "0",      "info"),
 ("S21", "R5_info_pivot_codes",               "info",          "",       "info"),
 ("S22", "U1_pivot_range_ok",                 "== 1",          "0",      "lane"),
 ("S22", "U1_contrast_range_ok",              "== 1",          "1",      "lane"),
 ("S23", "T1_contrast_tooltip_truthful",      "== 1",          "0",      "lane"),
 ("S23", "T2_pivot_tooltip_truthful",         "== 1",          "0",      "lane"),
]
def ok(v, rule):
    op, *a = rule.split(); a = [float(x) for x in a]
    return {"==": lambda: v == a[0], ">=": lambda: v >= a[0], "<=": lambda: v <= a[0],
            "abs<=": lambda: abs(v) <= a[0], "in": lambda: a[0] <= v <= a[1],
            "info": lambda: True}[op]()
fails = 0
print(f"{'id':4} {'key':42} {'measured':>12}  {'rule':14} {'baseline':>9}  verdict")
for sid, key, rule, base, kind in RULES:
    if key not in vals:
        print(f"{sid:4} {key:42} {'MISSING':>12}  {rule:14} {base:>9}  FAIL"); fails += 1; continue
    v = vals[key]; good = ok(v, rule)
    verdict = "INFO" if kind == "info" else ("PASS" if good else ("OPEN" if kind == "open" else "FAIL"))
    if kind == "open" and good: verdict = "PASS(open)"
    fails += verdict == "FAIL"
    extra = f"  {notes[key]}" if kind == "info" or verdict == "FAIL" else ""
    print(f"{sid:4} {key:42} {v:12.6g}  {rule:14} {base:>9}  {verdict}{extra}")
print(f"\n{fails} lane line(s) FAIL")
sys.exit(1 if fails else 0)
EOF
