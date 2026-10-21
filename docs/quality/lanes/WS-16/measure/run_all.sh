#!/bin/bash
# WS-16 acceptance run: builds lumen-render and the stage probe (release), runs every measurement,
# renders the visual sheets. Prints one PASS/FAIL line per spec id.
set -e
export PATH=/opt/swift/usr/bin:$PATH
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../../../.." && pwd)
(cd "$REPO" && swift build -c release --product lumen-render > /dev/null)
(cd "$HERE/probe" && swift build -c release > /dev/null)
cd "$HERE"
for m in m_identity m_saturation m_vibrance m_skin m_density m_bw m_parity m_ui m_tests; do
  echo "== $m"; python3 "$m.py"
done
echo "== visual sheets"; python3 visual.py
