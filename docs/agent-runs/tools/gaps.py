"""For each drag: the largest frame gaps, and what the timeline holds inside each."""
import json, sys, os
d = sys.argv[1]
which = sys.argv[2:] or None
r = json.load(open(os.path.join(d, 'report.json')))
rows = [json.loads(l) for l in open(os.path.join(d, 'timeline.jsonl'))]
for s in r['steps']:
    if s['do'] != 'drag' or (which and s['id'] not in which):
        continue
    ins = [x for x in rows if x['k'] == 'in' and s['t0'] <= x['t'] <= s['t0'] + s['ms'] / 1000]
    start = ins[0]['t']; end = start + s['gestureMs'] / 1000
    fr = [x['t'] for x in rows if x['k'] == 'frame' and start <= x['t'] <= end]
    marks = [start] + fr + [end]
    gaps = sorted(((b - a, a, b) for a, b in zip(marks, marks[1:])), reverse=True)[:3]
    print('==', s['id'], 'frames', len(fr))
    for g, a, b in gaps:
        print(f'  gap {1000 * g:.0f} ms at +{1000 * (a - start):.0f}')
        for x in rows:
            if a < x['t'] < b and x['k'] in ('tl', 'hitch', 'stall') and not (x['k'] == 'tl' and x.get('stage') in ('input', 'request')):
                extra = {k: v for k, v in x.items() if k not in ('t', 'k')}
                print(f"      +{1000 * (x['t'] - start):6.0f} {x['k']} {extra}")
