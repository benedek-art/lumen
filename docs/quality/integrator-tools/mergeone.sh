#!/bin/bash
# usage: mergeone.sh <lane>  — merge origin/quality/<lane> into the integration branch,
# applying the known semantic resolutions, then build.
T=/tmp/claude-0/-home-user-lumen/2f6f486a-0ba7-5b97-97bd-42718a481ccb/scratchpad/tools
S=/tmp/claude-0/-home-user-lumen/2f6f486a-0ba7-5b97-97bd-42718a481ccb/scratchpad
b=$1
cd /home/user/lumen || exit 2
sha=$(git rev-parse --short origin/quality/$b)
if ! git merge -q --no-ff -m "Merge quality/$b ($sha) into claude/inspiring-dirac-ulgpch" origin/quality/$b >/dev/null 2>&1; then
  u=$(git diff --name-only --diff-filter=U)
  echo "$b conflicts: $u"
  for f in $u; do
    case "$b:$f" in
      m3-gradient-masks:Tests/LumenCoreTests/MaskEdgeShiftTests.swift) git checkout --ours $f ;;
      t2-curves:Tests/LumenAppTests/PanelSnapshotTests.swift) python3 $T/resolve_snap_t2.py $f ;;
      m1-mask-overlay:Tests/LumenAppTests/PanelSnapshotTests.swift) python3 $T/resolve_snap_m1.py $f ;;
      t1-tone-spatial:Tests/LumenCoreTests/Proof/records/tone.contrast*.json) cp $S/$(basename $f) $f ;;
      m8-local-presence:Sources/LumenRender/CLI.swift) python3 $T/resolve_cli_m8.py $f ;;
      t5-auto-tone:Sources/LumenRender/CLI.swift) python3 $T/union.py $f ;;
      m1-mask-overlay:Tests/LumenAppTests/LayoutMetricSupport.swift) git checkout --ours $f ;;  # line numbers only; re-cited after the batch
      t2-curves:Tests/LumenAppTests/LayoutMetricSupport.swift) git checkout --ours $f ;;
      *) echo "UNKNOWN conflict $f"; exit 1 ;;
    esac
    git add -- $f
  done
  git diff --name-only --diff-filter=U | grep -q . && { echo unresolved; exit 1; }
  git commit -q --no-edit || exit 1
fi
echo "$b $sha -> $(git rev-parse --short HEAD)"
PATH=/opt/swift/usr/bin:$PATH swift build -j 4 --target LumenCore --target LumenRender 2>&1 | grep -E "error:|Build of" | sort -u | head -8
