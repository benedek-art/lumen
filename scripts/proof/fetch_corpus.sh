#!/usr/bin/env bash
# fetch_corpus.sh -- (re)build the Lumen proof corpus, idempotently.
#
#   corpus/raw/        CC0 camera RAWs from raw.pixls.us, verified by sha256
#   corpus/lfi/        each RAW decoded by decode_raw.py (+ .json sidecar)
#   corpus/synthetic/  synthetic frames from gen_synthetic.py (+ .json sidecars)
#
# Everything is driven by scripts/proof/corpus.manifest.json. Re-running only does
# what is missing or stale: a RAW is downloaded only if absent or failing its digest; a
# .lfi is re-decoded only if older than its RAW or than decode_raw.py; synthetic frames
# are regenerated only if older than gen_synthetic.py. corpus/ is git-ignored.
#
# Environment:
#   CORPUS_DIR   output directory (default: <repo>/corpus)
#   LONG_EDGE    decode long edge in px, 0 = native (default 2400)
#   RAW_CACHE    optional directory searched for already-downloaded RAWs, by manifest
#                file name or <id>.<ext> (e.g. /home/user/corpus/raw); digest-checked
#   NO_DOWNLOAD  set to 1 to fail instead of downloading
#
# Etiquette (raw.pixls.us asks for no bulk crawling; see docs/audit-2026-09/w6/
# raw-corpus-plan.md section 1.5): a fixed list, sequential, retried with backoff,
# downloaded once. Every row is checked to be CC0 before it is fetched.
#
# Requires: bash, curl, python3 with numpy and rawpy (0.27 tested), sha256sum.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MANIFEST="$HERE/corpus.manifest.json"
CORPUS_DIR="${CORPUS_DIR:-$REPO/corpus}"
LONG_EDGE="${LONG_EDGE:-2400}"
RAW_CACHE="${RAW_CACHE:-}"
UA="Lumen-proof-corpus/1 (fixed CC0 list; see scripts/proof/CORPUS.md)"

mkdir -p "$CORPUS_DIR/raw" "$CORPUS_DIR/lfi" "$CORPUS_DIR/synthetic"

python3 -c 'import numpy, rawpy' 2>/dev/null || {
    echo "fetch_corpus: python3 needs numpy and rawpy (pip install rawpy numpy)" >&2; exit 1; }

sha_ok() { [ -f "$1" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$2" ]; }

# id <TAB> name <TAB> local <TAB> url <TAB> sha256 <TAB> license
rows="$(python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for f in m["files"]:
    if f["kind"] != "raw":
        continue
    print("\t".join([f["id"], f["name"], f["local"], f["url"], f["sha256"], f["license"]]))
PY
)"

n_dl=0; n_dec=0; fail=0
while IFS=$'\t' read -r id name local url sha lic; do
    [ -n "$id" ] || continue
    case "$lic" in CC0*) ;; *) echo "REFUSE $id: licence is '$lic', not CC0" >&2; fail=1; continue;; esac
    dest="$CORPUS_DIR/$local"
    ext="${local##*.}"
    if ! sha_ok "$dest" "$sha"; then
        found=""
        if [ -n "$RAW_CACHE" ]; then
            for cand in "$RAW_CACHE/$(basename "$local")" "$RAW_CACHE/$id.$ext" \
                        "$RAW_CACHE/$id.$(echo "$ext" | tr a-z A-Z)"; do
                if sha_ok "$cand" "$sha"; then cp "$cand" "$dest"; found="$cand"; break; fi
            done
        fi
        if [ -z "$found" ]; then
            if [ "${NO_DOWNLOAD:-0}" = 1 ]; then echo "MISSING $id ($local)" >&2; fail=1; continue; fi
            echo "download $id  $name"
            curl -sS -f -L -A "$UA" --retry 4 --retry-delay 5 -o "$dest.part" "$url"
            if ! sha_ok "$dest.part" "$sha"; then
                echo "SHA MISMATCH $id: got $(sha256sum "$dest.part" | cut -d' ' -f1)" >&2
                rm -f "$dest.part"; fail=1; continue
            fi
            mv "$dest.part" "$dest"; n_dl=$((n_dl + 1))
        else
            echo "cached   $id  <- $found"
        fi
    fi
    out="$CORPUS_DIR/lfi/$name.lfi"
    if [ ! -f "$out" ] || [ ! -f "${out%.lfi}.json" ] || [ "$dest" -nt "$out" ] \
            || [ "$HERE/decode_raw.py" -nt "$out" ]; then
        python3 "$HERE/decode_raw.py" "$dest" "$out" --long-edge "$LONG_EDGE" || { fail=1; continue; }
        n_dec=$((n_dec + 1))
    fi
done <<< "$rows"

syn="$CORPUS_DIR/synthetic"
stale=0
for f in colorchecker grey_ramp hue_wheel zone_plate hard_edge skin_tones flat_grey; do
    if [ ! -f "$syn/$f.lfi" ] || [ ! -f "$syn/$f.json" ] || [ "$HERE/gen_synthetic.py" -nt "$syn/$f.lfi" ] \
            || [ "$HERE/decode_raw.py" -nt "$syn/$f.lfi" ]; then stale=1; fi
done
if [ "$stale" = 1 ]; then python3 "$HERE/gen_synthetic.py" "$syn"; fi

cp "$MANIFEST" "$CORPUS_DIR/corpus.manifest.json"
echo "fetch_corpus: $n_dl downloaded, $n_dec decoded, synthetic $([ "$stale" = 1 ] && echo regenerated || echo up to date) -> $CORPUS_DIR"
exit "$fail"
