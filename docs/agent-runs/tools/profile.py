"""Continuous main-thread profiles of drag steps, restricted to the gesture span."""
import json, sys, os, collections, re
d = sys.argv[1]
top = int(sys.argv[2]) if len(sys.argv) > 2 else 25
which = sys.argv[3:] or None
r = json.load(open(os.path.join(d, 'report.json')))
rows = [json.loads(l) for l in open(os.path.join(d, 'timeline.jsonl'))]
data = json.load(open(os.path.join(d, 'stalls.json')))
syms = data['symbols']
prof = data.get('profiles', {})
stacks = prof.get('stacks', [])
MARK = {'layout': 'NSHostingView.layout', 'viewGraph': 'updateViewGraph', 'body': 'DynamicBody',
        'sendEvent': 'NSHostingView.sendEvent', 'CAcommit': 'CA11Transaction6commit',
        'idle': 'mach_msg2_trap'}
agg_inc = collections.Counter(); agg_busy = 0
for s in r['steps']:
    if s['do'] != 'drag' or (which and s['id'] not in which):
        continue
    key = f"{s['i']} {s['id']}"
    samples = prof.get('steps', {}).get(key, [])
    ins = [x for x in rows if x['k'] == 'in' and s['t0'] <= x['t'] <= s['t0'] + s['ms'] / 1000]
    start = ins[0]['t']; end = start + s['gestureMs'] / 1000
    inside = [x for x in samples if start <= x[0] <= end]
    busy = [x for x in inside if x[2]]
    mk = collections.Counter(); inc = collections.Counter()
    for t, sid, b in busy:
        names = [re.sub(r' \(in Lumen\).*', '', syms[i]) for i in stacks[sid]]
        for k, m in MARK.items():
            if any(m in x for x in names):
                mk[k] += 1
        for x in set(n for n in names if n.startswith('Lumen`') and 'LumenApp_main' not in n):
            inc[x] += 1
    agg_inc.update(inc); agg_busy += len(busy)
    print(f"== {s['id']}: {len(inside)} samples, busy {len(busy)} ({100 * len(busy) / max(len(inside), 1):.0f}%)  "
          + ', '.join(f'{k} {100 * v / max(len(busy), 1):.0f}%' for k, v in mk.most_common()))
print('-- inclusive app frames over busy samples, all drags', agg_busy)
for k, v in agg_inc.most_common(top):
    print(f'{v:5} {100 * v / max(agg_busy, 1):5.1f}%  {k[:190]}')
