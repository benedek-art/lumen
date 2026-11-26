"""The timeline from the last event of each drag to its sharp frame."""
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
    print('==', s['id'], 'relSharp', s.get('releaseToSharpMs'))
    for x in rows:
        if end - 0.25 <= x['t'] <= end + 0.8 and x['k'] in ('tl', 'hitch', 'frame', 'stall', 'pub', 'rx', 'commit'):
            if x['k'] == 'pub' and x.get('o') not in ('AppState', 'PanelEditRevision'):
                pass
            extra = {k: v for k, v in x.items() if k not in ('t', 'k', 'et', 'win', 'flags', 'x', 'y')}
            print(f"   {1000 * (x['t'] - end):7.1f} {x['k']:6} {extra}")
