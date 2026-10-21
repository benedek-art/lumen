#!/usr/bin/env bash
# Linux cloud-session bootstrap: Swift 6.0.3 for the LumenCore build and lumen-render,
# rawpy for scripts/proof/decode_raw.py. Idempotent; safe to run at every session start.
set -euo pipefail
SWIFT_DIR=/opt/swift
if [ ! -x "$SWIFT_DIR/usr/bin/swift" ]; then
  curl -sSL https://download.swift.org/swift-6.0.3-release/ubuntu2404/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-ubuntu24.04.tar.gz -o /tmp/swift.tgz
  mkdir -p "$SWIFT_DIR"
  tar xzf /tmp/swift.tgz -C "$SWIFT_DIR" --strip-components=1
  rm -f /tmp/swift.tgz
fi
python3 -c "import rawpy" 2>/dev/null || pip install -q rawpy numpy
echo "export PATH=$SWIFT_DIR/usr/bin:\$PATH" > /etc/profile.d/swift.sh 2>/dev/null || true
"$SWIFT_DIR/usr/bin/swift" --version | head -1
