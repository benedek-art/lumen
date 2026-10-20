"""Blind A/B preference test (original vs ours vs Lightroom ...) as one offline HTML page + tally.

python -m lumen_denoise.eval.abtest build --crops reports/ab_crops --out reports/ab.html [--seed N] [--focus ours]
python -m lumen_denoise.eval.abtest tally reports/ab_results*.json [--json out.json]
Crops: <dir>/<crop_id>/<method>.png (made by `crops.py --ab DIR`), optional <dir>/index.json {crop_id: meta}.
Every pair of methods per crop is one trial; trial order and left/right are shuffled with the seed. Method
names never appear in the page's plain text (images get opaque ids; the id->method map is XOR+base64
obfuscated: a self-blind test, not security) until all trials are done. The page saves progress in
localStorage and downloads ab_results_<page>_<time>.json = {"page", "session", "seed", "results": [{trial_id,
crop_id, left, right, choice: left|right|tie, ms}]}; copy it to reports/ so the release gate picks it up.
"""
import argparse, base64, glob, hashlib, itertools, json, math, random, shutil
from pathlib import Path
from .common import ROOT, Check

S = "a/b"
OURS, LR, ORIG = "ours", "lightroom", "original"
P_MAX = 0.05     # two-sided exact sign test (ties dropped): the conventional 5 % false-"better" rate
MIN_N = 20       # decisive ours-vs-LR judgements needed: below ~20 one odd crop swings the rate by >5 pts
WIN_MIN = 0.5    # ours must be preferred in more than half of the decisive judgements (direction of the test)
Z95 = 1.959964   # normal quantile for the 95 % Wilson interval


# --------------------------------------------------------------- build ----
def discover(crops_dir, methods=None):
    """{crop_id: {method: Path}} from <dir>/<crop_id>/<method>.png; crops with < 2 methods are dropped."""
    d, want = Path(crops_dir), set(methods) if methods else None
    out = {}
    for sub in sorted(p for p in d.iterdir() if p.is_dir()):
        m = {p.stem: p for p in sorted(sub.glob("*.png")) if want is None or p.stem in want}
        if len(m) >= 2:
            out[sub.name] = m
    return out


def make_trials(crops, seed, focus=None):
    """All method pairs per crop (only pairs containing `focus` if given), shuffled; sides random."""
    rng = random.Random(seed)
    tr = []
    for cid, m in sorted(crops.items()):
        for a, b in itertools.combinations(sorted(m), 2):
            if focus and focus not in (a, b):
                continue
            if rng.random() < 0.5:
                a, b = b, a
            # trial id is side/seed independent so result files of different builds/judges merge
            tid = hashlib.sha1(f"{cid}\0{min(a, b)}\0{max(a, b)}".encode()).hexdigest()[:10]
            tr.append({"trial_id": tid, "crop_id": cid, "left": a, "right": b})
    rng.shuffle(tr)
    return tr


def _xor(data, key):
    return bytes(c ^ key[i % len(key)] for i, c in enumerate(data))


def build(pairs_source, out_html, seed=0, methods=None, focus=None, embed=True):
    """Write the self-contained blind A/B page. Returns the trial list (with method names, for tests)."""
    src, out = Path(pairs_source), Path(out_html)
    crops = discover(src, methods)
    if not crops:
        raise SystemExit(f"no <crop_id>/<method>.png with >= 2 methods under {src}")
    meta = {}
    if (src / "index.json").exists():
        try:
            meta = json.load(open(src / "index.json"))
        except (OSError, ValueError):
            meta = {}
    trials = make_trials(crops, seed, focus)
    if not trials:
        raise SystemExit(f"no pairs (focus={focus!r} not among methods?)")
    salt = hashlib.sha256(f"lumen-ab:{seed}:{sorted(crops)}".encode()).digest()
    iid = lambda c, m: hashlib.sha1(salt + f"{c}\0{m}".encode()).hexdigest()[:12]
    used = {(t["crop_id"], k) for t in trials for k in (t["left"], t["right"])}
    imgs, imgdir = {}, out.with_name(out.stem + "_img")
    if not embed:
        imgdir.mkdir(parents=True, exist_ok=True)
    for c, m in sorted(used, key=lambda cm: iid(*cm)):  # id order, not method-name order
        i, p = iid(c, m), crops[c][m]
        if embed:
            imgs[i] = "data:image/png;base64," + base64.b64encode(p.read_bytes()).decode()
        else:
            shutil.copyfile(p, imgdir / f"{i}.png")
            imgs[i] = f"{imgdir.name}/{i}.png"
    page_id = hashlib.sha1(json.dumps(trials, sort_keys=True).encode() + salt).hexdigest()[:10]
    key = salt[:16]
    mapping = dict(sorted((iid(c, m), m) for c, m in used))
    obf = base64.b64encode(_xor(json.dumps(mapping).encode(), key)).decode()
    T = [{"id": t["trial_id"], "c": t["crop_id"], "l": iid(t["crop_id"], t["left"]), "r": iid(t["crop_id"], t["right"]),
          "info": _info(meta.get(t["crop_id"]))} for t in trials]
    data = {"page": page_id, "seed": seed, "T": T, "IMG": imgs, "K": key.hex(), "M": obf}
    blob = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(PAGE.replace("/*DATA*/null", blob))
    return trials


def _info(m):
    """Neutral crop caption from index.json meta (camera/ISO/region; never a method name)."""
    if not isinstance(m, dict):
        return ""
    return " ".join(str(m[k]) for k in ("model", "iso", "kind") if m.get(k) is not None)


# --------------------------------------------------------------- tally ----
def load_results(paths):
    """Valid judgements from result files. The page lets you download mid-way and again at the end, so the same
    (page, session, trial_id) can appear in several files: keep only the newest ("created") answer, else it is
    double-counted. "session" is a per-browser id, so different judges of the same page are all kept."""
    best = {}
    for n, p in enumerate(paths):
        d = json.load(open(p))
        page, sess, created = ((d.get("page"), d.get("session"), str(d.get("created", ""))) if isinstance(d, dict)
                               else (None, None, ""))
        for j, r in enumerate(d.get("results", []) if isinstance(d, dict) else d):
            if not (isinstance(r, dict) and r.get("choice") in ("left", "right", "tie")
                    and isinstance(r.get("left"), str) and isinstance(r.get("right"), str) and r["left"] != r["right"]):
                continue
            # page/session-less files (older or hand-made): no dedupe
            k = (page, sess, r["trial_id"]) if page and sess and r.get("trial_id") else (n, j)
            if k not in best or (created, n) >= best[k][0]:
                best[k] = ((created, n), r)
    return [r for _, r in best.values()]


def binom_two_sided(k, n, p=0.5):
    """Exact two-sided binomial test p-value ("minlike": sum of outcomes no likelier than k), as scipy.stats.binomtest."""
    if n == 0:
        return 1.0
    if p <= 0 or p >= 1:
        return 1.0 if k == round(p * n) else 0.0
    lp = [math.lgamma(n + 1) - math.lgamma(i + 1) - math.lgamma(n - i + 1) + i * math.log(p) + (n - i) * math.log1p(-p)
          for i in range(n + 1)]  # log pmf: math.comb * p**i overflows a float for n > ~1000
    ref = lp[k] + math.log1p(1e-7)
    return min(1.0, sum(math.exp(q) for q in lp if q <= ref))


def wilson(k, n, z=Z95):
    """Wilson score interval for a proportion (Wilson 1927, JASA 22:209)."""
    if n == 0:
        return (0.0, 1.0)
    ph, z2 = k / n, z * z
    c = (ph + z2 / (2 * n)) / (1 + z2 / n)
    h = z * math.sqrt(ph * (1 - ph) / n + z2 / (4 * n * n)) / (1 + z2 / n)
    return (max(0.0, c - h), min(1.0, c + h))


def bradley_terry(wins, methods, iters=500, prior=0.1):
    """Bradley-Terry strengths by Hunter's MM iteration (Hunter 2004, Ann. Stat. 32:384):
    p_i <- W_i / sum_j n_ij/(p_i+p_j). wins[a][b] = (ties as 0.5) wins of a over b; `prior` pseudo-wins
    each way on every compared pair keep never-winning methods finite. Normalized to geometric mean 1."""
    w = {a: {b: wins[a][b] + (prior if wins[a][b] + wins[b][a] > 0 else 0) for b in methods} for a in methods}
    p = {a: 1.0 for a in methods}
    for _ in range(iters):
        q = {}
        for i in methods:
            Wi = sum(w[i][j] for j in methods if j != i)
            den = sum((w[i][j] + w[j][i]) / (p[i] + p[j]) for j in methods if j != i)
            q[i] = Wi / den if den > 0 else p[i]
        g = math.exp(sum(math.log(max(v, 1e-300)) for v in q.values()) / len(q))
        p = {a: v / g for a, v in q.items()}
    return p


def pair_stats(wins, ties, a, b):
    k, l = wins[a][b], wins[b][a]
    n = k + l
    return {"a": a, "b": b, "wins": k, "losses": l, "ties": ties[a][b], "n": n,
            "rate": k / n if n else None, "ci95": wilson(k, n), "p": binom_two_sided(k, n)}


def tally(results_json_paths):
    """Per-method W/L/T, pairwise win-rate matrix, Bradley-Terry scores, ours-vs-lightroom/original sign tests."""
    rec = load_results(results_json_paths)
    methods = sorted({r[s] for r in rec for s in ("left", "right")})
    wins = {a: {b: 0 for b in methods} for a in methods}
    ties = {a: {b: 0 for b in methods} for a in methods}
    for r in rec:
        L, R = r["left"], r["right"]
        if r["choice"] == "tie":
            ties[L][R] += 1; ties[R][L] += 1
        else:
            w, l = (L, R) if r["choice"] == "left" else (R, L)
            wins[w][l] += 1
    per = {m: {"wins": sum(wins[m].values()), "losses": sum(wins[o][m] for o in methods),
               "ties": sum(ties[m].values())} for m in methods}
    rate = {a: {b: (wins[a][b] / (wins[a][b] + wins[b][a]) if wins[a][b] + wins[b][a] else None)
                for b in methods if b != a} for a in methods}
    btw = {a: {b: wins[a][b] + 0.5 * ties[a][b] for b in methods} for a in methods}
    bt = bradley_terry(btw, methods) if methods else {}
    out = {"n_files": len(results_json_paths), "n_trials": len(rec), "methods": methods, "per_method": per,
           "win_rate": rate, "bradley_terry": bt, "ranking": sorted(methods, key=lambda m: -bt[m])}
    for other in (LR, ORIG):
        if OURS in methods and other in methods:
            out[f"ours_vs_{other}"] = pair_stats(wins, ties, OURS, other)
    return out


def print_tally(t):
    ms = t["methods"]
    print(f"{t['n_trials']} judgements from {t['n_files']} file(s)")
    print(f"{'method':12s} {'W':>4s} {'L':>4s} {'T':>4s} {'BT':>7s}")
    for m in t["ranking"]:
        d = t["per_method"][m]
        print(f"{m:12s} {d['wins']:4d} {d['losses']:4d} {d['ties']:4d} {t['bradley_terry'][m]:7.3f}")
    print("win rate (row beats column, ties excluded):")
    print(" " * 12 + "".join(f"{m[:9]:>10s}" for m in ms))
    for a in ms:
        print(f"{a:12s}" + "".join(f"{'-' if b == a or t['win_rate'][a][b] is None else format(t['win_rate'][a][b], '.2f'):>10s}" for b in ms))
    for other in (LR, ORIG):
        s = t.get(f"ours_vs_{other}")
        if s:
            r = "-" if s["rate"] is None else f"{s['rate']:.3f}"
            print(f"ours vs {other}: {s['wins']}-{s['losses']} (ties {s['ties']}), preference {r} "
                  f"95% CI [{s['ci95'][0]:.3f}, {s['ci95'][1]:.3f}], sign test p={s['p']:.4g}")


# ---------------------------------------------------------------- gate ----
def find_results(ctx=None):
    pats = [ROOT / "reports" / "ab_results*.json", Path("reports") / "ab_results*.json"]
    if ctx is not None and getattr(ctx, "out_dir", None) is not None:
        pats.append(Path(ctx.out_dir).parent / "ab_results*.json")
    return sorted({str(Path(p).resolve()) for pat in pats for p in glob.glob(str(pat))})


def gate_checks(model, baseline, ctx):
    """Judged by a human, not computed: model/baseline are unused (the page shows whatever was rendered as 'ours')."""
    files = find_results(ctx)
    how = ("no reports/ab_results*.json: crops.py --ab reports/ab_crops --ours <method>, then "
           "abtest build --crops reports/ab_crops --out reports/ab.html, judge, save the download to reports/")
    if not files:
        return [Check(S, "ab_ours_vs_lightroom", None, f"rate>{WIN_MIN}, p<{P_MAX}", "SKIP", how)]
    try:
        t = tally(files)
    except (OSError, ValueError, KeyError, TypeError) as e:
        return [Check(S, "ab_ours_vs_lightroom", None, f"rate>{WIN_MIN}, p<{P_MAX}", "SKIP", f"unreadable results: {e}")]
    import datetime
    newest = datetime.datetime.fromtimestamp(max(Path(f).stat().st_mtime for f in files)).strftime("%Y-%m-%d")
    out = []
    s = t.get("ours_vs_lightroom")
    if not s:
        out.append(Check(S, "ab_ours_vs_lightroom", None, f"rate>{WIN_MIN}, p<{P_MAX}", "SKIP",
                         f"no ours-vs-lightroom trials in {len(files)} file(s) (methods {t['methods']})"))
    else:
        ok = s["n"] >= MIN_N and s["rate"] is not None and s["rate"] > WIN_MIN and s["p"] < P_MAX
        note = (f"{s['wins']}-{s['losses']} ties {s['ties']}, CI95 [{s['ci95'][0]:.2f},{s['ci95'][1]:.2f}], "
                f"p={s['p']:.3g}, {len(files)} file(s), newest {newest} (check it judged this model)" + ("" if s["n"] >= MIN_N else f"; need >= {MIN_N} decisive"))
        out.append(Check(S, "ab_ours_vs_lightroom", None if s["rate"] is None else round(s["rate"], 3),
                         f"rate>{WIN_MIN}, p<{P_MAX}, n>={MIN_N}", "PASS" if ok else "FAIL", note))
    s = t.get("ours_vs_original")
    if s:
        out.append(Check(S, "ab_ours_vs_original", None if s["rate"] is None else round(s["rate"], 3), "report", "INFO",
                         f"{s['wins']}-{s['losses']} ties {s['ties']}, CI95 [{s['ci95'][0]:.2f},{s['ci95'][1]:.2f}], p={s['p']:.3g}"))
    return out


# ---------------------------------------------------------------- page ----
PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Blind A/B</title>
<style>
:root{--bg:#222;--panel:#2a2a2a;--line:#3a3a3a;--fg:#d8d8d8;--dim:#8a8a8a;--sel:#e8e8e8}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.4 -apple-system,system-ui,Segoe UI,Helvetica,Arial,sans-serif}
header{display:flex;gap:16px;align-items:center;padding:10px 16px;border-bottom:1px solid var(--line);flex-wrap:wrap}
header .sp{flex:1}
#prog{font-variant-numeric:tabular-nums}
#bar{height:3px;background:var(--line)}#bar i{display:block;height:3px;background:#777;width:0}
main{padding:16px;display:flex;flex-direction:column;align-items:center;gap:12px}
#pair{display:flex;gap:16px;flex-wrap:wrap;justify-content:center}
.side{display:flex;flex-direction:column;align-items:center;gap:6px}
.vp{overflow:hidden;background:#000;outline:1px solid var(--line);cursor:crosshair;max-width:calc(100vw - 32px)}
.vp img{display:block;image-rendering:pixelated;image-rendering:crisp-edges;max-width:none}
.side.picked .vp{outline:2px solid var(--sel)}
.lab{color:var(--dim);font-size:12px;letter-spacing:.08em;text-transform:uppercase}
#btns{display:flex;gap:10px;flex-wrap:wrap;justify-content:center}
button{background:var(--panel);color:var(--fg);border:1px solid var(--line);border-radius:4px;padding:8px 14px;font:inherit;cursor:pointer}
button:hover{border-color:#666}
.k{color:var(--dim);font-size:12px}
#info{color:var(--dim);font-size:12px;min-height:1em}
#done{display:none;max-width:640px;width:100%}
table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
td,th{border-bottom:1px solid var(--line);padding:6px 8px;text-align:right}td:first-child,th:first-child{text-align:left}
.help{color:var(--dim);font-size:12px;text-align:center;max-width:720px}
</style></head><body>
<header><b>Blind A/B</b><span id="prog"></span><span class="sp"></span>
<button id="zoom" title="Z">Zoom 1x</button><button id="undo" title="Backspace">Undo</button>
<button id="dl">Download results</button><button id="reset">Reset</button></header>
<div id="bar"><i></i></div>
<main>
<div id="info"></div>
<div id="pair">
 <div class="side" id="sL"><div class="vp" id="vL"><img id="iL" alt="left"></div><div class="lab">Left</div></div>
 <div class="side" id="sR"><div class="vp" id="vR"><img id="iR" alt="right"></div><div class="lab">Right</div></div>
</div>
<div id="btns">
 <button id="bL">Left better <span class="k">A / &larr;</span></button>
 <button id="bT">Can't tell <span class="k">S / space</span></button>
 <button id="bR">Right better <span class="k">L / &rarr;</span></button>
</div>
<div class="help">Pick the crop that looks like the better photo at 100 %: real detail kept, no smearing, no blotches or
artifacts. Images are shown 1 image pixel = 1 screen pixel. Z toggles 2x nearest-neighbour zoom; move the mouse over
either image to pan both together. Sides and order are random; labels are revealed after the last trial.</div>
<div id="done"><h3>Finished</h3><div id="sum"></div>
<p class="help">Click "Download results" and copy the JSON file into reports/ (name ab_results*.json) for the release gate.</p></div>
</main>
<script>
const D=/*DATA*/null;
const KEY="lumen_ab_"+D.page;
function sid(){try{return crypto.randomUUID();}catch(e){return Date.now().toString(36)+Math.random().toString(36).slice(2);}}
let st={i:0,ans:{},sid:sid()};
try{const s=localStorage.getItem(KEY);if(s){const o=JSON.parse(s);if(o&&o.ans)st=o;}}catch(e){}
if(!st.sid)st.sid=sid();
function save(){try{localStorage.setItem(KEY,JSON.stringify(st));}catch(e){}}
function hex(h){const a=[];for(let i=0;i<h.length;i+=2)a.push(parseInt(h.substr(i,2),16));return a;}
function unmask(){const k=hex(D.K),b=atob(D.M);let s="";for(let i=0;i<b.length;i++)s+=String.fromCharCode(b.charCodeAt(i)^k[i%k.length]);return JSON.parse(s);}
let zoom=1,t0=performance.now(),busy=false;
const $=id=>document.getElementById(id);
function fit(){
  const dpr=window.devicePixelRatio||1;
  for(const s of ["L","R"]){const im=$("i"+s),vp=$("v"+s);if(!im.naturalWidth)continue;
    const w=im.naturalWidth/dpr,h=im.naturalHeight/dpr;
    vp.style.width=w+"px";vp.style.height=h+"px";im.style.width=w*zoom+"px";im.style.height=h*zoom+"px";}
  $("zoom").textContent="Zoom "+zoom+"x";
}
function pan(e){
  if(zoom===1)return;const r=e.currentTarget.getBoundingClientRect();
  const fx=Math.min(1,Math.max(0,(e.clientX-r.left)/r.width)),fy=Math.min(1,Math.max(0,(e.clientY-r.top)/r.height));
  for(const s of ["L","R"]){const vp=$("v"+s);vp.scrollLeft=fx*(vp.scrollWidth-vp.clientWidth);vp.scrollTop=fy*(vp.scrollHeight-vp.clientHeight);}
}
$("vL").addEventListener("mousemove",pan);$("vR").addEventListener("mousemove",pan);
function show(){
  const n=D.T.length,i=st.i;
  $("prog").textContent=Math.min(i+1,n)+" / "+n;$("bar").firstChild.style.width=(100*Math.min(i,n)/n)+"%";
  $("sL").classList.remove("picked");$("sR").classList.remove("picked");
  if(i>=n){finish();return;}
  $("done").style.display="none";$("pair").style.display="";$("btns").style.display="";
  const t=D.T[i];$("info").textContent=t.c+(t.info?" · "+t.info:"");
  $("iL").onload=$("iR").onload=fit;$("iL").src=D.IMG[t.l];$("iR").src=D.IMG[t.r];fit();
  for(const s of ["L","R"]){$("v"+s).scrollLeft=0;$("v"+s).scrollTop=0;}
  t0=performance.now();busy=false;
}
function pick(c){
  if(busy||st.i>=D.T.length)return;busy=true;const t=D.T[st.i];
  if(document.activeElement&&document.activeElement.blur)document.activeElement.blur();
  st.ans[t.id]={choice:c,ms:Math.round(performance.now()-t0)};
  if(c!=="tie")$(c==="left"?"sL":"sR").classList.add("picked");
  st.i++;save();setTimeout(show,c==="tie"?0:120);
}
function undo(){if(!busy&&st.i>0){st.i--;delete st.ans[D.T[st.i].id];save();show();}}
function results(){
  const m=unmask(),out=[];
  for(const t of D.T){const a=st.ans[t.id];if(!a)continue;
    out.push({trial_id:t.id,crop_id:t.c,left:m[t.l],right:m[t.r],choice:a.choice,ms:a.ms});}
  return out;
}
function finish(){
  $("pair").style.display="none";$("btns").style.display="none";$("info").textContent="";$("done").style.display="block";
  const r=results(),agg={};
  for(const x of r){for(const k of [x.left,x.right])agg[k]=agg[k]||{w:0,l:0,t:0};
    if(x.choice==="tie"){agg[x.left].t++;agg[x.right].t++;}
    else{const w=x.choice==="left"?x.left:x.right,l=x.choice==="left"?x.right:x.left;agg[w].w++;agg[l].l++;}}
  let h="<table><tr><th>method</th><th>wins</th><th>losses</th><th>can't tell</th><th>win rate</th></tr>";
  Object.keys(agg).sort((a,b)=>(agg[b].w-agg[b].l)-(agg[a].w-agg[a].l)).forEach(k=>{const a=agg[k],n=a.w+a.l;
    h+="<tr><td>"+k.replace(/[<&]/g,"")+"</td><td>"+a.w+"</td><td>"+a.l+"</td><td>"+a.t+"</td><td>"+(n?(a.w/n).toFixed(2):"-")+"</td></tr>";});
  $("sum").innerHTML=h+"</table>";
}
function download(){
  const blob=new Blob([JSON.stringify({page:D.page,session:st.sid,seed:D.seed,created:new Date().toISOString(),results:results()},null,1)],{type:"application/json"});
  const a=document.createElement("a");a.href=URL.createObjectURL(blob);
  a.download="ab_results_"+D.page+"_"+new Date().toISOString().replace(/[:.]/g,"-").slice(0,19)+".json";
  document.body.appendChild(a);a.click();setTimeout(()=>{URL.revokeObjectURL(a.href);a.remove();},500);
}
$("bL").onclick=()=>pick("left");$("bR").onclick=()=>pick("right");$("bT").onclick=()=>pick("tie");
$("undo").onclick=undo;$("dl").onclick=download;
$("zoom").onclick=()=>{zoom=zoom===1?2:1;fit();};
$("reset").onclick=()=>{if(confirm("Discard all answers on this page?")){st={i:0,ans:{},sid:sid()};busy=false;save();show();}};
document.addEventListener("keydown",e=>{
  if(e.metaKey||e.ctrlKey||e.altKey)return;const k=e.key.toLowerCase();
  if(e.repeat&&k!=="z"){e.preventDefault();return;}  // a held key must not answer trials you have not seen
  if(k==="arrowleft"||k==="a"){pick("left");e.preventDefault();}
  else if(k==="arrowright"||k==="l"){pick("right");e.preventDefault();}
  else if(k===" "||k==="s"){pick("tie");e.preventDefault();}
  else if(k==="z"){zoom=zoom===1?2:1;fit();}
  else if(k==="backspace"||k==="u"){undo();e.preventDefault();}
});
window.addEventListener("resize",fit);
show();
</script></body></html>
"""


# ----------------------------------------------------------------- cli ----
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--crops", default="reports/ab_crops"); b.add_argument("--out", default="reports/ab.html")
    b.add_argument("--seed", type=int, default=0); b.add_argument("--methods", default="", help="comma list to include")
    b.add_argument("--focus", default="", help="only pairs involving this method, e.g. ours")
    b.add_argument("--no-embed", action="store_true", help="copy images next to the page (opaque names) instead of base64")
    t = sub.add_parser("tally")
    t.add_argument("results", nargs="+"); t.add_argument("--json", default="")
    a = ap.parse_args()
    if a.cmd == "build":
        tr = build(a.crops, a.out, a.seed, [m for m in a.methods.split(",") if m] or None, a.focus or None, not a.no_embed)
        print(f"{a.out}: {len(tr)} trials over {len({x['crop_id'] for x in tr})} crops")
    else:
        files = sorted({f for p in a.results for f in (glob.glob(p) or [p])})
        r = tally(files)
        print_tally(r)
        if a.json:
            json.dump(r, open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
