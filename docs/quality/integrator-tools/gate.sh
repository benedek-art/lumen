#!/bin/bash
# usage: gate.sh <label>  — build + LumenCoreTests + surface check on /home/user/lumen HEAD
S=/tmp/claude-0/-home-user-lumen/2f6f486a-0ba7-5b97-97bd-42718a481ccb/scratchpad
cd /home/user/lumen || exit 2
echo "== $1 at $(git rev-parse --short HEAD)"
PATH=/opt/swift/usr/bin:$PATH swift build --target LumenCore --target LumenRender > $S/build-$1.txt 2>&1
b=$?
grep -E "error:" $S/build-$1.txt | sort -u | head -20
echo "BUILD $b"
[ $b -ne 0 ] && exit 1
python3 scripts/check-swift-surface.py > $S/surface-$1.txt 2>&1 &
sp=$!
$S/tools/coretest.sh /home/user/lumen $S/test-$1.txt
t=$(tail -1 $S/test-$1.txt)
wait $sp; sc=$?
echo "SURFACE $sc"
[ $sc -ne 0 ] && grep -v "^ *$" $S/surface-$1.txt | grep -B1 -A3 "^  Sources\|^  Tests" | head -30
