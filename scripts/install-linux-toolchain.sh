#!/bin/sh
# Install a Linux Swift toolchain, so LumenCore can be compiled and tested WITHOUT a
# seventeen-minute round trip through CI.
#
# Why this exists: for most of this project's life the only feedback on whether the
# Swift compiled at all was a GitHub Actions run — first unavailable entirely (a private
# repo out of Actions minutes), then seventeen minutes per answer, of which sixteen and
# a half were the test suite. Two bugs shipped in one afternoon that a compiler would
# have caught in seconds: a member that did not exist on a type, and an overlay drawing
# against the wrong rectangle.
#
# What this DOES cover: LumenCore. Eighteen thousand lines — the whole colour science,
# tone, grade, film, detail, denoise, mask algebra, catalog and XMP — plus the tests in
# LumenCoreTests. It builds in about ten seconds.
#
# The catalog is included only because `Sources/CSQLite3` exists. Apple ships an
# `SQLite3` module in the SDK; Ubuntu ships a header and a shared object and no
# modulemap, so `canImport(SQLite3)` was FALSE here and `CatalogStore` and every one of
# its tests compiled out — `swift test` reported green having never built a third of
# LumenCore. This script claimed that coverage before the modulemap existed, which is
# the same shape of failure as a check that cannot fail.
#
# Three table-accuracy tests used to fail here (and on macOS — they were never a Linux
# artefact): asserted bounds that had never been met, hidden behind lanes that did not
# run them. 1bca87f resolved that by MEASURING what each table size actually delivers
# and pinning the convergence ladder instead of a wished-for bound;
# testExportTableErrorStaysUnderOnePercent was reshaped away in the same work. The
# whole of LumenCoreTests is green on this toolchain now. The paragraph that stood here
# survived two rewrites while being wrong in different directions — if a test fails on
# this toolchain, the answer is `git log -S <testname>`, not this comment.
#
# What it does NOT cover: LumenPipeline and LumenApp are `#if os(macOS)` and need Core
# Image, AppKit and SwiftUI. They still need the macOS runner. The mechanical checker
# (scripts/check-swift-surface.py) remains the only local feedback on those, which is
# why it has eight passes rather than one.
#
# Requires outbound access to download.swift.org. If the environment's network policy is
# "trusted" rather than "all", this returns 403 at CONNECT and there is nothing to do
# here but change the policy.

set -eu

VERSION="${SWIFT_VERSION:-6.1.2}"          # matches what CI's macOS runner reports
PREFIX="${SWIFT_PREFIX:-/opt/swift}"
UBUNTU="${UBUNTU_RELEASE:-ubuntu24.04}"
SLUG="$(echo "$UBUNTU" | tr -d '.')"

URL="https://download.swift.org/swift-${VERSION}-release/${SLUG}/swift-${VERSION}-RELEASE/swift-${VERSION}-RELEASE-${UBUNTU}.tar.gz"

if [ -x "$PREFIX/usr/bin/swift" ]; then
    echo "Already installed:"
    "$PREFIX/usr/bin/swift" --version
    exit 0
fi

echo "Fetching Swift $VERSION for $UBUNTU…"
TARBALL="$(mktemp -d)/swift.tar.gz"
if ! curl -fsSL -o "$TARBALL" "$URL"; then
    echo "Could not download the toolchain." >&2
    echo "If this is a 403, the environment's network policy is blocking" >&2
    echo "download.swift.org — see /root/.ccr/README.md." >&2
    exit 1
fi

mkdir -p "$PREFIX"
tar xzf "$TARBALL" -C "$PREFIX" --strip-components=1
rm -f "$TARBALL"

"$PREFIX/usr/bin/swift" --version
echo
echo "Build:  $PREFIX/usr/bin/swift build --target LumenCore"
echo "Test:   $PREFIX/usr/bin/swift test --filter LumenCoreTests"
echo
echo "Add to PATH for the session:  export PATH=\"$PREFIX/usr/bin:\$PATH\""
