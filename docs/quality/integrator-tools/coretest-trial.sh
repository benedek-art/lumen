#!/bin/bash
# usage: coretest.sh <dir> <outfile>
# LumenCoreTests as CI's engine-linux runs them: parallel, ControlProofTests skipped
# (those run in release in the Proof sweep workflow).
cd "$1" || exit 2
/opt/swift612/usr/bin/swift test --scratch-path /home/user/lumen-build612-trial --parallel \
    --filter LumenCoreTests --skip ControlProofTests > "$2" 2>&1
s=$?
echo "STATUS $s" >> "$2"
grep -E "error:|\] Testing .* failed|failed \(|Test Case .* failed" "$2" | grep -v ": error: -\[" | cut -c1-300 | sort -u | head -40
grep -E "^\[[0-9]+/[0-9]+\]" "$2" | tail -1 | cut -c1-120
echo "EXIT $s"
