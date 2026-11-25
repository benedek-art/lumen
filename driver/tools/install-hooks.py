#!/usr/bin/env python3
"""Make sure the app sources carry the driver's hooks. Idempotent.

    install-hooks.py [--check]

The driver itself is Sources/LumenApp/Driver; these are the few lines in existing files
that call into it. The lane runs this after copying the driver onto a ref that may
predate it, so any branch can be tested. A hook whose anchor text is no longer found is
reported: the two in LumenApp.swift are required, the rest only cost a named target or
the frame timeline.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
APP = ROOT / "Sources" / "LumenApp"

# (file, marker that means "already installed", text to find, replacement, required)
HOOKS = [
    ("LumenApp.swift", "LumenDriver.makeAppState()",
     "@StateObject private var state = AppState()",
     "@StateObject private var state = LumenDriver.makeAppState()", True),
    ("LumenApp.swift", "LumenDriver.start(state)",
     "let launchedWith = delegate.attach(state)\n",
     "let launchedWith = delegate.attach(state)\n"
     "                    // Under the automation driver: no reopen, no updater.\n"
     "                    if LumenDriver.isActive {\n"
     "                        LumenDriver.start(state)\n"
     "                        return\n"
     "                    }\n", True),
    ("LoupeView.swift", "LumenDriver.frameApplied(",
     "            settledRecipe = recipe\n        }\n        revision &+= 1\n    }\n",
     "            settledRecipe = recipe\n        }\n        revision &+= 1\n"
     "        LumenDriver.frameApplied(result, recipe: recipe, model: self)\n    }\n", False),
    ("LoupeView.swift", '.driverAnchor("viewer.image")',
     "        .frame(width: drawn.width, height: drawn.height)\n        .scaleEffect(stretch)\n",
     "        .frame(width: drawn.width, height: drawn.height)\n"
     '        .driverAnchor("viewer.image")\n        .scaleEffect(stretch)\n', False),
    ("ContentView.swift", '.driverAnchor("viewer")',
     "                    LoupeView(photo: photo)\n",
     '                    LoupeView(photo: photo)\n                        .driverAnchor("viewer")\n',
     False),
    # Same-line edits: tests cite these two files by line number.
    ("LumenControls.swift", 'track.driverAnchor(driverID + "#track")',
     "            track\n\n            valueField\n",
     '            track.driverAnchor(driverID + "#track")\n\n            valueField\n', False),
    ("LumenControls.swift", "}.driverAnchor(driverID)",
     "            @unknown default: break\n            }\n        }\n    }\n\n"
     "    /// One VoiceOver increment or decrement",
     "            @unknown default: break\n            }\n        }.driverAnchor(driverID)\n    }\n\n"
     "    /// One VoiceOver increment or decrement", False),
    ("MaskPanel.swift", '.driverAnchor("mask.row")',
     "        .onHover { inside in state.hoverMaskOverlay(inside ? mask.id : nil) }\n    }\n",
     "        .onHover { inside in state.hoverMaskOverlay(inside ? mask.id : nil) }"
     '.driverAnchor("mask.row")\n    }\n', False),
    ("MaskPanel.swift", '.driverAnchor("mask.kind/"',
     "        .help(MaskPanel.kindPurpose(kind))\n",
     '        .help(MaskPanel.kindPurpose(kind)).driverAnchor("mask.kind/" + MaskPanel.kindName(kind))\n',
     False),
    ("MaskFloatingPanel.swift", '.driverAnchor("mask.create")',
     '        .help("Create a new mask — every kind, on one board")\n',
     '        .help("Create a new mask — every kind, on one board")\n'
     '        .driverAnchor("mask.create")\n', False),
]


def main():
    check = "--check" in sys.argv
    missing_required = False
    for name, marker, find, replace, required in HOOKS:
        path = APP / name
        text = path.read_text() if path.exists() else ""
        if marker in text:
            print(f"present    {name}: {marker}")
            continue
        if not check and text.count(find) == 1:
            path.write_text(text.replace(find, replace))
            print(f"installed  {name}: {marker}")
            continue
        print(f"{'MISSING' if required else 'missing'}    {name}: {marker}"
              + ("" if check else " (anchor text not found exactly once)"))
        missing_required |= required
    return 1 if missing_required else 0


if __name__ == "__main__":
    sys.exit(main())
