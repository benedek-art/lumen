"""Render-lane samples per drag: the first frame's window vs the rest, by frame."""
import json, sys, os, collections, re
d = sys.argv[1]
top = int(sys.argv[2]) if len(sys.argv) > 2 else 25
which = sys.argv[3:] or None
r = json.load(open(os.path.join(d, 'report.json')))
rows = [json.loads(l) for l in open(os.path.join(d, 'timeline.jsonl'))]
data = json.load(open(os.path.join(d, 'stalls.json')))
syms = data['symbols']; prof = data['profiles']; stacks = prof['stacks']
SKIP = ('libsystem', 'libdispatch', 'libswift_Concurrency', 'swift_task', 'LumenApp_main')
for s in r['steps']:
    if s['do'] != 'drag' or (which and s['id'] not in which):
        continue
    ins = [x for x in rows if x['k'] == 'in' and s['t0'] <= x['t'] <= s['t0'] + s['ms'] / 1000]
    start = ins[0]['t']; end = start + s['gestureMs'] / 1000
    fr = [x['t'] for x in rows if x['k'] == 'frame' and start <= x['t'] <= end]
    first = fr[0] if fr else end
    samples = prof['steps'].get(f"lane {s['i']} {s['id']}", [])
    for label, a, b in (('to first frame', start, first), ('after', first, end)):
        inside = [x for x in samples if a <= x[0] <= b]
        c = collections.Counter()
        for t, sid, _ in inside:
            names = [re.sub(r' \(in Lumen\).*', '', syms[i]) for i in stacks[sid]]
            for n in set(names):
                if not n.startswith(SKIP):
                    c[n[:170]] += 1
        print(f"== {s['id']} {label}: {1000 * (b - a):.0f} ms, {len(inside)} lane samples")
        for k, v in c.most_common(top):
            print(f'   {v:4} {k}')
