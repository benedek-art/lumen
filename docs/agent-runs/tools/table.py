"""The owner's bar per drag, from report.json + timeline.jsonl. Prints a markdown table."""
import json, sys, os, statistics
print('| run | drag | frames | need | distinct values (shown) | first frame after first move ms | longest gap after first ms | gap bar ms | median draft ms | p50/p90 latency ms | longest hitch ms | release to final ms | release to sharp ms |')
print('|---|---|---|---|---|---|---|---|---|---|---|---|---|')
evs = set()
for d in sys.argv[1:]:
    label = d.split('/runs/')[-1]
    r = json.load(open(os.path.join(d, 'report.json')))
    rows = [json.loads(l) for l in open(os.path.join(d, 'timeline.jsonl'))]
    for s in r['steps']:
        if s['do'] != 'drag':
            continue
        ins = [x for x in rows if x['k'] == 'in' and s['t0'] <= x['t'] <= s['t0'] + s['ms'] / 1000]
        down = next(x for x in ins if x.get('ev') == 'down')
        move = next(x for x in ins if x['t'] > down['t'] and x.get('ev') != 'up' and x.get('x') != down.get('x'))
        start = ins[0]['t']; end = start + s['gestureMs'] / 1000
        fr = [x['t'] for x in rows if x['k'] == 'frame' and start <= x['t'] <= end]
        draft = [x['ms'] for x in rows if x['k'] == 'tl' and x.get('stage') == 'frame'
                 and x.get('draft') and start <= x['t'] <= end + 0.3 and x.get('ms')]
        med = statistics.median(draft) if draft else None
        span = (end - start) * 1000
        need = 0.7 * span / max(med, 16.7) if med else None
        first = (fr[0] - move['t']) * 1000 if fr else None
        after = max([(b - a) * 1000 for a, b in zip(fr, fr[1:] + [end])], default=None)
        hitch = max([x['ms'] for x in rows if x['k'] == 'hitch' and start <= x['t'] - x['ms'] / 1000 <= end], default=0)
        lat = s.get('latencyMs', {})
        f = lambda v: '—' if v is None else f'{v:.0f}'
        print(f"| {label} | {s['id']} | {s.get('framesDuring')} | {f(need)} | {s.get('distinctValues')} ({s.get('distinctValuesShown')}) | {f(first)} | {f(after)} | "
              f"{f(2 * med + 50 if med else None)} | {f(med)} | {f(lat.get('p50'))}/{f(lat.get('p90'))} | {hitch:.0f} | {f(s.get('releaseToFinalValueMs'))} | {f(s.get('releaseToSharpMs'))} |")
