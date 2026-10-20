#!/bin/bash
# Compiles the Foundation-only sources (Engine.swift, Core.swift) with the tests and runs them.
# Works on Linux (cloud, /opt/swift toolchain) and on the Mac (Xcode toolchain). Uses Tests/fake_engine, never the real engine.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d /opt/swift/usr/bin ] && export PATH=/opt/swift/usr/bin:$PATH
export PYTHONDONTWRITEBYTECODE=1
export LUMEN_PYTHON="${LUMEN_PYTHON:-$(command -v python3)}"
BIN="${TMPDIR:-/tmp}/lumen-tests-$$"
trap 'rm -f "$BIN"' EXIT
swiftc -swift-version 5 Sources/LumenDenoise/Engine.swift Sources/LumenDenoise/Core.swift Tests/*.swift -o "$BIN"
"$BIN"
