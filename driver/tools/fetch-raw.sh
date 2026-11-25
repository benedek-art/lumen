#!/bin/bash
# Fetch the pinned CC0 RAW files in driver/fixtures/raw.tsv into DIR, verifying each
# sha256. Sequential, with a naming User-Agent: raw.pixls.us is volunteer-run.
#   driver/tools/fetch-raw.sh DIR
set -u
dir=$1
manifest=$(cd "$(dirname "$0")/../fixtures" && pwd)/raw.tsv
mkdir -p "$dir"
cd "$dir" || exit 2
UA="lumen-driver-ci/1 (+https://github.com/${GITHUB_REPOSITORY:-benedek-art/lumen})"
fail=0
while IFS=';' read -r id local sha bytes lic label url; do
  [ -n "$id" ] || continue
  if [ "$lic" != "CC0" ]; then echo "REFUSED $id: licence '$lic'"; fail=1; continue; fi
  if [ -f "$local" ] && [ "$(shasum -a 256 "$local" | cut -d' ' -f1)" = "$sha" ]; then
    echo "have $local"
    continue
  fi
  echo "fetch $local — $label"
  curl -sS --fail --location --retry 3 --retry-delay 5 --max-time 600 \
       --user-agent "$UA" "$url" -o "$local" || { echo "  fetch failed"; fail=1; continue; }
  got=$(shasum -a 256 "$local" | cut -d' ' -f1)
  if [ "$got" != "$sha" ]; then
    echo "  DIGEST MISMATCH for $local: got $got — deleting"
    rm -f "$local"
    fail=1
  fi
done < "$manifest"
exit $fail
