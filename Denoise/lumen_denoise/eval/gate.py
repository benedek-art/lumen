"""Release gate: runs every available eval module and prints one PASS/FAIL release table.

python -m lumen_denoise.eval.gate --model net:runs/A/best.pt --baseline net:runs/prev/best.pt
python -m lumen_denoise.eval.gate --model wiener --baseline identity --synthetic --quick   # CPU smoke run
Specs: noisy|identity|wiener|blur:<s>|bm3d|net:<path.pt> (common.get_method). Thresholds live in each module
(UPPERCASE constants) and are explained in docs/RELEASE_GATE.md. Writes <out>/<model>_vs_<baseline>.{json,md}.
Exit code: 0 = RELEASE PASS (or synthetic smoke PASS with --synthetic), 1 = any FAIL row, 2 = not enough data
(also: unreadable --calib, method that cannot load/run). --quick is never a release.
"""
import argparse, json, re, sys, time
from dataclasses import asdict
from pathlib import Path
import numpy as np
from . import common
from .common import Check

# section keys (--only) -> module; each returns list[Check]
SECTIONS = ("synthetic", "detail", "real-noise", "low-iso", "stars", "a/b")
ALIASES = {"bench": "synthetic", "synth_bench": "synthetic", "noref": "real-noise", "real": "real-noise",
           "lowiso": "low-iso", "ab": "a/b", "abtest": "a/b", "star": "stars"}
# a real release needs evidence from each of these (>= 1 PASS/FAIL row, not all SKIP): synthetic PSNR, texture,
# real high-ISO noise, clean-shot regression and stars are the five ways a denoiser can hurt the user's photos
MANDATORY = ("synthetic", "detail", "real-noise", "low-iso", "stars")
# a/b rows are human judgements of a rendered "ours" (maybe an older model): they decide the LIGHTROOM CLAIM only,
# never the release (not yet proven better than Lightroom must not block a model that passes every safety check)
CLAIM_ONLY = ("a/b",)
AB_MIN_PHOTOS = 8   # Lightroom claim: decisive ours-vs-LR judgements must come from >= 8 different photos (one scene can't carry it)
DEFAULT_LISTS = dict(real="data/lists/local_real_noisy.txt", lowiso="data/lists/local_clean_val.txt",
                     astro="data/lists/local_astro.txt")


def _crash(sec, e):
    return [Check(sec, "module crashed", None, "-", "FAIL", f"{type(e).__name__}: {e}"[:300])]


def _synthetic(m, b, ctx):
    from . import synth_bench
    return synth_bench.gate_checks(m, b, ctx)


def _detail(m, b, ctx):
    from . import detail
    return detail.gate_checks(m, b, ctx)


def _noref(m, b, ctx):
    from . import noref
    return noref.gate_checks(m, b, ctx) + noref.noref_selftest_checks(m, ctx, b)


def _lowiso(m, b, ctx):
    from . import lowiso
    return lowiso.gate_checks(m, b, ctx)


def _stars(m, b, ctx):
    from . import stars
    return stars.gate_checks(m, b, ctx)


def _ab(m, b, ctx):
    from . import abtest
    return abtest.gate_checks(m, b, ctx) + ab_photo_checks(ctx)


RUNNERS = {"synthetic": _synthetic, "detail": _detail, "real-noise": _noref, "low-iso": _lowiso,
           "stars": _stars, "a/b": _ab}


def ab_photo_checks(ctx):
    """Distinct photos behind the ours-vs-lightroom judgements (crop ids are <stem>_<kind>, see crops.py --ab)."""
    from . import abtest
    files = abtest.find_results(ctx)
    if not files:
        return []
    try:
        rec = abtest.load_results(files)
    except Exception as e:
        return [Check("a/b", "ab_photos", None, f">= {AB_MIN_PHOTOS}", "SKIP", f"unreadable results: {e}")]
    pair = {abtest.OURS, abtest.LR}
    ph = {str(r.get("crop_id", "")).rsplit("_", 1)[0] for r in rec
          if {r["left"], r["right"]} == pair and r["choice"] != "tie"}
    if not ph:
        return []
    return [Check("a/b", "ab_photos", len(ph), f">= {AB_MIN_PHOTOS} photos", common.status(len(ph) >= AB_MIN_PHOTOS),
                  "distinct photos with decisive ours-vs-lightroom judgements")]


def normalize_only(only):
    if not only:
        return list(SECTIONS)
    out = []
    for s in only.split(","):
        s = ALIASES.get(s.strip().lower(), s.strip().lower())
        if s not in RUNNERS:
            raise SystemExit(f"--only: unknown section {s!r} (choose from {', '.join(SECTIONS)})")
        out.append(s)
    return out


def run_gate(model, baseline, ctx, sections=SECTIONS, log=print):
    """model/baseline: method fns. Every module runs in try/except: a crash is one FAIL row, never kills the run.
    Returns (checks, seconds per section)."""
    checks, secs = [], {}
    for s in sections:
        t = time.time()
        try:
            rows = list(RUNNERS[s](model, baseline, ctx))
            if not rows:
                rows = [Check(s, "no checks", None, "-", "SKIP", "module returned no rows")]
        except Exception as e:  # noqa: BLE001 - any module failure must show up as a FAIL, not abort the gate
            rows = _crash(s, e)
        secs[s] = time.time() - t
        checks += rows
        if log:
            n = {k: sum(c.status == k for c in rows) for k in ("PASS", "FAIL", "SKIP", "INFO")}
            log(f"  {s:12s} {secs[s]:6.1f}s  " + " ".join(f"{k} {v}" for k, v in n.items()), flush=True)
    return checks, secs


def _ran(checks, sec):
    """A section counts as run when at least one gating row (PASS/FAIL) came from real or synthetic data
    (the synthetic proxy of real-noise does not stand in for real photos)."""
    return any(c.section == sec and c.status in ("PASS", "FAIL") for c in checks)


def verdict(checks, synthetic, sections=SECTIONS, quick=False, cams_missing=()):
    """-> dict(release, exit, fails, missing, lightroom, lightroom_missing, smoke).
    quick: 2-frame run, never a release. cams_missing: calibrated bodies with no held-out frame."""
    fails = [c for c in checks if c.status == "FAIL" and c.section not in CLAIM_ONLY]
    missing = []
    if synthetic:
        missing.append("held-out clean frames (data/gt_val + data/gt_meta.json): ran on procedural scenes")
    elif cams_missing:
        missing.append(f"held-out frames from every camera: none from {', '.join(cams_missing)} (use --n 0 / add frames)")
    if quick:
        missing.append("--quick run (2 frames, fewer crops): rerun without --quick for a release")
    for s in MANDATORY:
        if s not in sections:
            missing.append(f"section '{s}' not run (--only)")
        elif not _ran(checks, s):
            why = next((c.note for c in checks if c.section == s and c.note), "all SKIP")
            missing.append(f"section '{s}' produced no PASS/FAIL rows ({why[:120]})")
    if "low-iso" in sections and not any(c.section == "low-iso" and c.name.endswith("_real")
                                         and c.status in ("PASS", "FAIL") for c in checks):
        missing.append("real base-ISO RAWs (--lowiso-list): low-iso ran on synthetic frames only")
    if fails:
        rel, code = "FAIL", 1
    elif missing:
        rel, code = "NOT ENOUGH DATA", 2
    else:
        rel, code = "PASS", 0
    ab = [c for c in checks if c.section == "a/b" and c.name in ("ab_ours_vs_lightroom", "ab_photos")]
    lr_missing = []
    if "a/b" not in sections:
        lr_missing.append("a/b section not run")
    elif not any(c.name == "ab_ours_vs_lightroom" and c.status in ("PASS", "FAIL") for c in ab):
        lr_missing.append("no blind A/B results with ours vs lightroom in reports/ab_results*.json")
    elif not any(c.name == "ab_photos" and c.status == "PASS" for c in ab) and not any(
            c.name == "ab_photos" and c.status == "FAIL" for c in ab):
        lr_missing.append(f"ab_photos: could not count distinct photos (need >= {AB_MIN_PHOTOS})")
    lr_missing += [f"{c.name} {c.status} ({c.value} vs {c.threshold})" for c in ab if c.status == "FAIL"]
    if rel != "PASS":
        lr_missing.append(f"release gate is {rel}" + (" (synthetic smoke run)" if synthetic else ""))
    return dict(release=rel, exit=code, smoke=synthetic, fails=[f"{c.section}/{c.name}" for c in fails],
                missing=missing, lightroom="PROVEN" if not lr_missing else "NOT PROVEN", lightroom_missing=lr_missing)


def _v(x):
    if x is None:
        return "-"
    if isinstance(x, (int, np.integer)):
        return str(int(x))
    try:
        x = float(x)
    except (TypeError, ValueError):
        return str(x)
    return "nan" if not np.isfinite(x) else (f"{x:.4g}" if abs(x) < 1e4 else f"{x:.3e}")


COLS = (("section", 28), ("check", 34), ("value", 9), ("threshold", 40), ("status", 6), ("note", 0))


def format_table(checks, width_note=90):
    L = ["  ".join(f"{h:{w}s}" if w else h for h, w in COLS), "  ".join("-" * (w or 4) for _, w in COLS)]
    for c in checks:
        note = c.note if width_note is None or len(c.note) <= width_note else c.note[:width_note - 3] + "..."
        L.append("  ".join([f"{c.section[:28]:28s}", f"{c.name[:34]:34s}", f"{_v(c.value):>9s}",
                            f"{str(c.threshold)[:40]:40s}", f"{c.status:6s}", note]))
    return "\n".join(L)


def verdict_lines(v, model_name, baseline_name):
    n = len(v["fails"])
    if v["smoke"]:
        L = [f"RELEASE: NOT A RELEASE - synthetic smoke run ({model_name} vs {baseline_name}): "
             f"SMOKE {'PASS' if not n else 'FAIL'}, {n} FAIL row(s)"]
    else:
        L = [f"RELEASE: {v['release']} ({model_name} vs {baseline_name}), {n} FAIL row(s)"]
    if v["fails"]:
        L.append("  failed: " + ", ".join(v["fails"][:12]) + (" ..." if n > 12 else ""))
    L += [f"  missing: {m}" for m in v["missing"]]
    L.append(f"LIGHTROOM CLAIM: {v['lightroom']}")
    L += [f"  missing: {m}" for m in v["lightroom_missing"]]
    return L


def to_markdown(checks, v, meta):
    L = [f"# Release gate: {meta['model']} vs {meta['baseline']}", "",
         f"{meta['when']} - frames: {meta['frames']} ({'synthetic' if v['smoke'] else 'real held-out'}), "
         f"ISOs {meta['isos']}, quick={meta['quick']}", "", "```", *verdict_lines(v, meta["model"], meta["baseline"]), "```", "",
         "| section | check | value | threshold | status | note |", "|---|---|---|---|---|---|"]
    for c in checks:
        L.append("| " + " | ".join(str(x).replace("|", "/") for x in
                                    (c.section, c.name, _v(c.value), c.threshold, f"**{c.status}**" if c.status == "FAIL" else c.status, c.note)) + " |")
    L += ["", "Seconds per section: " + ", ".join(f"{k} {s:.1f}" for k, s in meta["seconds"].items()),
          "", "Thresholds and rationale: docs/RELEASE_GATE.md"]
    return "\n".join(L) + "\n"


def _safe(name):
    return re.sub(r"[^A-Za-z0-9.+-]+", "_", name).strip("_") or "x"


def _jsonable(x):
    if isinstance(x, (np.floating, np.integer)):
        return x.item()
    return str(x)


def build_ctx(a):
    from .realdata import list_files
    try:
        table = common.NoiseTable(a.calib)
        assert table.cameras(), "no cameras"
    except Exception as e:  # missing / malformed calib.json: a clean "not enough data", not a traceback
        raise SystemExit(f"cannot read noise calibration {a.calib}: {type(e).__name__}: {e}") from None
    frames = common.clean_frames(a.val, a.meta, a.n or (2 if a.quick else 0), True if a.synthetic else None)
    if frames and frames[0].synthetic and a.synth_size:  # smaller procedural scenes: faster tests / smoke runs
        frames = [common.Frame(f.name, f.camera, common.synthetic_scene(a.synth_size, a.synth_size, common.SEED + i), True)
                  for i, f in enumerate(frames)]
    lst = lambda v, d: list_files(v if v is not None else DEFAULT_LISTS[d])
    ctx = common.Ctx(table=table, frames=frames, isos=tuple(int(i) for i in a.isos.split(",")),
                     real_files=lst(a.real_list, "real"), lowiso_files=lst(a.lowiso_list, "lowiso"), quick=a.quick,
                     out_dir=Path(a.out), model_name=common.short_name(a.model), baseline_name=common.short_name(a.baseline))
    ctx.astro_files = lst(a.astro_list, "astro")  # read via getattr by eval.stars
    return ctx


def parser():
    ap = argparse.ArgumentParser(description="Lumen Denoise release gate (docs/RELEASE_GATE.md)")
    ap.add_argument("--model", required=True, help="spec of the candidate, e.g. net:runs/A/best.pt")
    ap.add_argument("--baseline", required=True, help="spec it must not regress against (previous release, wiener, ...)")
    ap.add_argument("--val", default="data/gt_val"); ap.add_argument("--meta", default="data/gt_meta.json")
    ap.add_argument("--calib", default=str(common.DEFAULT_CALIB))
    ap.add_argument("--real-list", default=None, help=f"high-ISO RAWs (.txt or dir), default {DEFAULT_LISTS['real']}")
    ap.add_argument("--lowiso-list", default=None, help=f"base-ISO RAWs, default {DEFAULT_LISTS['lowiso']}")
    ap.add_argument("--astro-list", default=None, help=f"night-sky RAWs, default {DEFAULT_LISTS['astro']}")
    ap.add_argument("--synthetic", action="store_true", help="force procedural scenes (smoke run, never a release)")
    ap.add_argument("--quick", action="store_true", help="2 frames, fewer crops (~20 s on CPU with cheap methods); never a release")
    ap.add_argument("--isos", default="1600,6400,25600")
    ap.add_argument("--n", type=int, default=0, help="max clean frames (0 = all; quick = 2)")
    ap.add_argument("--synth-size", type=int, default=0, help="side of procedural scenes (0 = 768 default)")
    ap.add_argument("--only", default="", help="comma list of sections: " + ",".join(SECTIONS))
    ap.add_argument("--out", default="reports/gate")
    return ap


def main(argv=None):
    a = parser().parse_args(argv)
    sections = normalize_only(a.only)
    t0 = time.time()
    try:
        ctx = build_ctx(a)
    except SystemExit as e:
        print(e, file=sys.stderr)
        return 2
    synthetic = bool(ctx.frames and ctx.frames[0].synthetic) or not ctx.frames
    print(f"gate: {ctx.model_name} vs {ctx.baseline_name} | {len(ctx.frames)} {'synthetic' if synthetic else 'held-out'} frames, "
          f"ISOs {list(ctx.isos)}, real {len(ctx.real_files)}, low-ISO {len(ctx.lowiso_files)}, astro {len(ctx.astro_files)}"
          f"{', quick' if a.quick else ''}", flush=True)
    try:
        model, baseline = common.get_method(a.model), common.get_method(a.baseline)
        K, r = ctx.table.params(ctx.table.cameras()[0], 6400)
        probe = common.add_noise(np.full((4, 32, 32), 0.1, np.float32), K, r, common.SEED)
        for f in (model, baseline):  # fail fast on lazy imports (bm3d) / broken nets instead of N "module crashed" rows
            assert common.run_padded(f, probe, K, r).shape == probe.shape, "method changed the image shape"
    except Exception as e:
        print(f"cannot load method: {type(e).__name__}: {e}", file=sys.stderr)
        return 2
    checks, secs = run_gate(model, baseline, ctx, sections)
    want = [c for c in common.CAMERAS if c in ctx.table.cameras()]
    cams_missing = [c for c in want if not any(f.camera == c for f in ctx.frames)]
    v = verdict(checks, synthetic, sections, quick=a.quick, cams_missing=cams_missing)
    if a.synthetic and v["exit"] == 2:
        v["exit"] = 0  # asked-for smoke run with no FAIL rows: success for CI, but the verdict line says it is not a release
    print()
    print(format_table(checks))
    print()
    print("\n".join(verdict_lines(v, ctx.model_name, ctx.baseline_name)))
    meta = dict(model=a.model, baseline=a.baseline, when=time.strftime("%Y-%m-%d %H:%M"), frames=len(ctx.frames),
                isos=list(ctx.isos), quick=a.quick, sections=sections, seconds={k: round(s, 2) for k, s in secs.items()},
                total_seconds=round(time.time() - t0, 1), n_real=len(ctx.real_files), n_lowiso=len(ctx.lowiso_files),
                n_astro=len(ctx.astro_files))
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    stem = str(out / f"{_safe(ctx.model_name)}_vs_{_safe(ctx.baseline_name)}")  # str: with_suffix would eat "blur:2.0"
    json.dump(dict(meta=meta, verdict=v, checks=[asdict(c) for c in checks]), open(stem + ".json", "w"),
              indent=1, default=_jsonable)
    Path(stem + ".md").write_text(to_markdown(checks, v, meta))
    print(f"wrote {stem}.json {stem}.md ({meta['total_seconds']} s)")
    return v["exit"]


if __name__ == "__main__":
    sys.exit(main())
