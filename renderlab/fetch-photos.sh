#!/usr/bin/env bash
# Fetch the render lab's CC0 RAW files (raw.pixls.us) listed in a corpus TSV into a
# directory, verifying sha256 and size. Files already present and correct are kept.
# Usage: renderlab/fetch-photos.sh renderlab/photos.tsv <dir>
set -u
tsv="$1"; dir="$2"
mkdir -p "$dir"
sum() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
UA="lumen-renderlab/1 (+https://github.com/benedek-art/lumen)"
fail=0
while IFS=';' read -r id local sha bytes make orient flags lic label url; do
  [ -n "$id" ] || continue
  [ "$lic" = "CC0" ] || { echo "REFUSED $id: licence $lic"; fail=1; continue; }
  f="$dir/$local"
  if [ -f "$f" ] && [ "$(sum "$f")" = "$sha" ]; then echo "ok $id (cached)"; continue; fi
  curl -sS --fail --location --retry 3 --retry-delay 5 --max-time 600 \
       --user-agent "$UA" "$url" -o "$f" || { echo "fetch failed $id"; fail=1; continue; }
  got=$(sum "$f")
  if [ "$got" != "$sha" ]; then echo "DIGEST MISMATCH $id"; rm -f "$f"; fail=1; continue; fi
  echo "ok $id $(wc -c < "$f" | tr -d '[:space:]') bytes"
done < "$tsv"
exit $fail
