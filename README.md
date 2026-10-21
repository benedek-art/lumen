# Lumen UI snapshots

PNG renders of every editing panel and the full window, made on a
macOS runner by `Tests/LumenAppTests/PanelSnapshotTests.swift` and
published by `.github/workflows/ui-snapshots.yml`. This branch is
regenerated as a single commit on every publish.

    git fetch origin ui-snapshots
    git show origin/ui-snapshots:<branch>/LATEST
    git show origin/ui-snapshots:<branch>/<sha>/index.md
    git worktree add /tmp/snaps origin/ui-snapshots

| branch | snapshot sets, newest first |
|---|---|
| `claude-inspiring-dirac-ulgpch` | [`488f0ee`](claude-inspiring-dirac-ulgpch/488f0ee/index.md) [`77300dd`](claude-inspiring-dirac-ulgpch/77300dd/index.md) [`552412c`](claude-inspiring-dirac-ulgpch/552412c/index.md) |
| `quality-c1-crop` | [`f38bd29`](quality-c1-crop/f38bd29/index.md) [`b0f7a37`](quality-c1-crop/b0f7a37/index.md) [`5160c5a`](quality-c1-crop/5160c5a/index.md) |
| `quality-c2-geometry` | [`c35e0c3`](quality-c2-geometry/c35e0c3/index.md) [`90b660a`](quality-c2-geometry/90b660a/index.md) |
| `quality-c3-lens` | [`6458d84`](quality-c3-lens/6458d84/index.md) [`a939139`](quality-c3-lens/a939139/index.md) [`7cb0b0b`](quality-c3-lens/7cb0b0b/index.md) |
| `quality-f1-halation` | [`dd791d3`](quality-f1-halation/dd791d3/index.md) |
| `quality-k1-grading-wheels` | [`fde01ec`](quality-k1-grading-wheels/fde01ec/index.md) [`be8d328`](quality-k1-grading-wheels/be8d328/index.md) |
| `quality-k2-color-mixer` | [`39c68a7`](quality-k2-color-mixer/39c68a7/index.md) [`3dc4f91`](quality-k2-color-mixer/3dc4f91/index.md) [`30df1b6`](quality-k2-color-mixer/30df1b6/index.md) |
| `quality-k3-point-colour` | [`cbcb102`](quality-k3-point-colour/cbcb102/index.md) [`88e91aa`](quality-k3-point-colour/88e91aa/index.md) |
| `quality-k4-looks-luts` | [`6dc31f5`](quality-k4-looks-luts/6dc31f5/index.md) |
| `quality-m1-mask-overlay` | [`d839f40`](quality-m1-mask-overlay/d839f40/index.md) [`aec0762`](quality-m1-mask-overlay/aec0762/index.md) |
| `quality-m3-gradient-masks` | [`f2258be`](quality-m3-gradient-masks/f2258be/index.md) |
| `quality-m4-range-masks` | [`fefe563`](quality-m4-range-masks/fefe563/index.md) |
| `quality-m5-ai-masks` | [`9bb22ca`](quality-m5-ai-masks/9bb22ca/index.md) |
| `quality-m6-mask-refine` | [`86b52df`](quality-m6-mask-refine/86b52df/index.md) [`4b83956`](quality-m6-mask-refine/4b83956/index.md) |
| `quality-m7-local-light-colour` | [`03d6a21`](quality-m7-local-light-colour/03d6a21/index.md) [`c0b0e7b`](quality-m7-local-light-colour/c0b0e7b/index.md) |
| `quality-m8-fix-local-softening` | [`f3ec6a5`](quality-m8-fix-local-softening/f3ec6a5/index.md) |
| `quality-m8-local-presence` | [`46a76aa`](quality-m8-local-presence/46a76aa/index.md) |
| `quality-m9-mask-perf` | [`7727e3a`](quality-m9-mask-perf/7727e3a/index.md) [`b74f81e`](quality-m9-mask-perf/b74f81e/index.md) [`ecbe2a2`](quality-m9-mask-perf/ecbe2a2/index.md) |
| `quality-m9b-range-gpu` | [`1cfad55`](quality-m9b-range-gpu/1cfad55/index.md) [`eb75b22`](quality-m9b-range-gpu/eb75b22/index.md) |
| `quality-t1-fix-gpu-parity` | [`6deaf1a`](quality-t1-fix-gpu-parity/6deaf1a/index.md) |
| `quality-t1-tone-spatial` | [`f9519ad`](quality-t1-tone-spatial/f9519ad/index.md) [`9e10bbb`](quality-t1-tone-spatial/9e10bbb/index.md) |
| `quality-t2-curves` | [`014576f`](quality-t2-curves/014576f/index.md) [`f3bc90c`](quality-t2-curves/f3bc90c/index.md) [`6d38aa2`](quality-t2-curves/6d38aa2/index.md) |
| `quality-t3-sharpening` | [`7adaa39`](quality-t3-sharpening/7adaa39/index.md) [`88dcf1d`](quality-t3-sharpening/88dcf1d/index.md) |
| `quality-t4-classic-nr` | [`f7841a6`](quality-t4-classic-nr/f7841a6/index.md) |
| `quality-t5-auto-tone` | [`7630fc8`](quality-t5-auto-tone/7630fc8/index.md) |
| `quality-u1-design-system` | [`3a76bc1`](quality-u1-design-system/3a76bc1/index.md) [`82792d2`](quality-u1-design-system/82792d2/index.md) [`dcd20b4`](quality-u1-design-system/dcd20b4/index.md) |
| `quality-u2-slider-component` | [`5494e77`](quality-u2-slider-component/5494e77/index.md) [`a3b24ed`](quality-u2-slider-component/a3b24ed/index.md) |
| `quality-u3-viewer-workflow` | [`cabb358`](quality-u3-viewer-workflow/cabb358/index.md) [`3685198`](quality-u3-viewer-workflow/3685198/index.md) [`c21fb24`](quality-u3-viewer-workflow/c21fb24/index.md) |
| `quality-ws-02-08-pickers-zones` | [`3454637`](quality-ws-02-08-pickers-zones/3454637/index.md) [`9b39825`](quality-ws-02-08-pickers-zones/9b39825/index.md) [`61b7afd`](quality-ws-02-08-pickers-zones/61b7afd/index.md) |
| `quality-ws-05-on-integration` | [`2b2148d`](quality-ws-05-on-integration/2b2148d/index.md) |
| `quality-ws-56-57-heal` | [`098a57c`](quality-ws-56-57-heal/098a57c/index.md) [`2d67087`](quality-ws-56-57-heal/2d67087/index.md) |
