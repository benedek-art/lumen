# Per-patch chroma ratio vs the 00_reference tile, for each render in a job dir.
import json, sys, glob
for d in sys.argv[1:]:
    files = sorted(glob.glob(d + '/*.json'))
    ref = None
    rows = {}
    for f in files:
        if f.endswith('series.json'):
            continue
        j = json.load(open(f))
        ps = j['stats'].get('patches') or []
        if f.split('/')[-1].startswith('00_'):
            ref = {p['name']: p for p in ps}
            continue
        rows[j['label']] = {p['name']: p for p in ps}
    names = list(ref.keys())
    print(d)
    print('patch'.ljust(22), 'h_ref  C_ref ', ' '.join(l[:14].rjust(14) for l in rows))
    for n in names:
        r = ref[n]
        line = f"{n[:22].ljust(22)} {r['h']:5.1f} {r['C']:.4f} "
        line += ' '.join(f"{rows[l][n]['C'] / max(r['C'], 1e-9):14.2f}" for l in rows)
        print(line)
