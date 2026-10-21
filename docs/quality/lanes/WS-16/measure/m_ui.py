"""WS-16 UI-1..UI-3: the Saturation panel (BasicPanel.saturationRows) draws all four sliders at
all times; Protect Skin is not drawn bipolar; Density is not disabled or hidden by a modifier.
A source-text check (the SwiftUI app does not build on Linux). Usage: python3 m_ui.py"""
import sys, os, re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ws16lib import check, summary, REPO

src = open(os.path.join(REPO, "Sources", "LumenApp", "BasicPanel.swift")).read()
a = src.index("private var saturationRows")
nxt = re.search(r"\n    (?:private |public |fileprivate )?(?:var|func|static) ", src[a + 10:])
body = src[a:a + 10 + nxt.start()] if nxt else src[a:]
code = re.sub(r"//[^\n]*", "", body)


def slider_call(title):
    i = code.find(f'title: "{title}"')
    if i < 0:
        return None, None
    s = code.rfind("LumenSlider(", 0, i)
    depth, j = 0, s + len("LumenSlider")
    while j < len(code):
        depth += {"(": 1, ")": -1}.get(code[j], 0)
        j += 1
        if depth == 0:
            break
    tail = re.match(r"(\s*\.[A-Za-z]+\([^\n]*\))*", code[j:]).group(0)   # trailing modifiers
    return s, code[s:j] + tail


def conditional(pos):
    """Is `pos` inside an if/switch/ForEach-guarded block of saturationRows?"""
    stack = []
    for m in re.finditer(r"\{|\}", code[:pos]):
        if m.group(0) == "{":
            head = code[code.rfind("\n", 0, m.start()) + 1:m.start()]
            stack.append(bool(re.search(r"\b(if|else|switch|guard|case)\b", head)))
        elif stack:
            stack.pop()
    return any(stack)


missing, hidden = [], []
for t in ("Vibrance", "Saturation", "Density", "Protect Skin"):
    pos, call = slider_call(t)
    if pos is None:
        missing.append(t)
    elif conditional(pos) or re.search(r"\.(hidden|opacity\(0|frame\(height: 0)", call):
        hidden.append(t)
check("UI-1", not missing and not hidden, f"missing {missing}; conditionally drawn {hidden}",
      "all four sliders drawn unconditionally in saturationRows")
_, ps = slider_call("Protect Skin")
check("UI-2", ps is not None and "bipolar: true" not in ps, "Protect Skin " + ("bipolar: true" if ps and "bipolar: true" in ps else "not bipolar"),
      "Protect Skin not drawn bipolar")
_, dn = slider_call("Density")
check("UI-3", dn is not None and ".disabled(" not in dn, "Density " + ("has .disabled(...)" if dn and ".disabled(" in dn else "enabled"),
      "Density enabled at all times (like Protect Skin)")
summary()
