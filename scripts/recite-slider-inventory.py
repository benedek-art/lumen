#!/usr/bin/env python3
"""Re-point SliderInventory's `File.swift:N` citations after the cited files changed.

`LayoutMetricSelfTests.testEveryCitationInTheInventoryLandsOnTheRowItNames` holds every
row's citation to a line that constructs the slider it names. Those are hand-written line
numbers, so any edit above a slider call moves them and the lane goes red on an address
rather than on a measurement. This script carries each citation through the diff of its
file since BASE (a commit where the test was green): an unchanged line follows the diff
exactly; a line inside a changed hunk is re-found by the row's literal title (or, for a
computed title, the nearest slider construction to the mapped position). It then runs the
test's own rule over the result and exits non-zero if any row still misses, so it can
never paper over a citation it could not place.

    python3 scripts/recite-slider-inventory.py <BASE> [--write]
"""
import difflib, re, subprocess, sys

INV = "Tests/LumenAppTests/LayoutMetricSupport.swift"
CITE = re.compile(r"([A-Za-z]+\.swift):(\d+)")
SPEC = re.compile(r'SliderSpec\("((?:[^"\\]|\\.)*)",\s*"([^"]*)"')

def show(rev, path):
    try:
        return subprocess.run(["git", "show", f"{rev}:{path}"], capture_output=True,
                              text=True, check=True).stdout.split("\n")
    except subprocess.CalledProcessError:
        return None

def is_call(s):
    return "Slider(" in s or "LumenColorWheel(" in s

def spelled(lines, i):
    window = " ".join(lines[i - 1:i + 1])
    m = re.search(r'(?:Slider|LumenColorWheel)\(\s*(?:title:\s*)?"((?:[^"\\]|\\.)*)"', window)
    return m.group(1) if m else None

def lands(lines, n, title):
    for c in (n, n - 1, n + 1):
        if 1 <= c <= len(lines) and is_call(lines[c - 1]):
            s = spelled(lines, c)
            return s is None or not title or s == title
    return False

def main():
    base, write = sys.argv[1], "--write" in sys.argv
    inv = open(INV).read().split("\n")
    maps, new_files = {}, {}

    def mapping(f):
        if f not in maps:
            old = show(base, f"Sources/LumenApp/{f}") or []
            new = open(f"Sources/LumenApp/{f}").read().split("\n")
            m = {}
            for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes():
                if tag == "equal":
                    for k in range(i2 - i1):
                        m[i1 + k + 1] = j1 + k + 1
            maps[f], new_files[f] = m, new
        return maps[f], new_files[f]

    def place(f, n, title):
        m, new = mapping(f)
        if n in m and lands(new, m[n], title):
            return m[n]
        # approximate position: nearest mapped line at or below n
        below = [m[k] for k in range(n, 0, -1) if k in m][:1]
        guess = below[0] if below else n
        cands = [i + 1 for i, s in enumerate(new) if is_call(s)]
        if title:
            exact = [c for c in cands if spelled(new, c) == title]
            if exact:
                return min(exact, key=lambda c: abs(c - guess))
        near = [c for c in cands if abs(c - guess) <= 40 and spelled(new, c) is None]
        return min(near, key=lambda c: abs(c - guess)) if near else None

    misses, moved = [], 0
    for idx, line in enumerate(inv):
        spec = SPEC.search(line)
        title = spec.group(1) if spec else ""
        def sub(mo):
            nonlocal moved
            f, n = mo.group(1), int(mo.group(2))
            if spec is None:          # prose mention: follow the diff only
                m, _ = mapping(f)
                return f"{f}:{m.get(n, n)}"
            p = place(f, n, title)
            if p is None:
                misses.append(f"{title or '(untitled)'} {f}:{n}")
                return mo.group(0)
            moved += p != n
            return f"{f}:{p}"
        inv[idx] = CITE.sub(sub, line) if CITE.search(line) else line

    # The test's own rule, over the result.
    for line in inv:
        spec = SPEC.search(line)
        if not spec:
            continue
        for f, n in CITE.findall(spec.group(2)):
            _, new = mapping(f)
            if not lands(new, int(n), spec.group(1)):
                misses.append(f"{spec.group(1)} {f}:{n} (fails the test's rule)")
    print(f"{moved} citations moved; {len(misses)} unplaced")
    for m in misses:
        print("  MISS", m)
    if write and not misses:
        open(INV, "w").write("\n".join(inv))
    sys.exit(1 if misses else 0)

main()
