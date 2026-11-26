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
    ("ContentView.swift", '.driverAnchor("sidebar")',
     "            Sidebar()\n", '            Sidebar()\n                .driverAnchor("sidebar")\n', False),
    ("ContentView.swift", '.driverAnchor("filterbar")',
     "                    FilterBar()\n",
     '                    FilterBar()\n                        .driverAnchor("filterbar")\n', False),
    ("ContentView.swift", '.driverAnchor("develop.column")',
     "                        DevelopPanel()\n",
     '                        DevelopPanel()\n                            .driverAnchor("develop.column")\n',
     False),
    ("ContentView.swift", '.driverAnchor("rail")',
     "                        WorkspaceRail()\n",
     '                        WorkspaceRail()\n                            .driverAnchor("rail")\n', False),
    ("ContentView.swift", '.driverAnchor("filmstrip")',
     "                    FilmstripView()\n",
     '                    FilmstripView()\n                        .driverAnchor("filmstrip")\n', False),
    ("ContentView.swift", '.driverAnchor("statusbar")',
     "                    StatusBar()\n",
     '                    StatusBar()\n                        .driverAnchor("statusbar")\n', False),
    ("ContentView.swift", '.driverAnchor("grid")',
     "            case .grid:\n                GridView()\n",
     '            case .grid:\n                GridView()\n                    .driverAnchor("grid")\n', False),
    ("ContentView.swift", '.driverAnchor("compare")',
     "                CompareView()\n",
     '                CompareView()\n                    .driverAnchor("compare")\n', False),
    # Same-line edits: tests cite these two files by line number.
    ("LumenControls.swift", 'track.driverAnchor(driverID + "#track")',
     "            track\n\n            valueField\n",
     '            track.driverAnchor(driverID + "#track")\n\n            valueField\n', False),
    ("LumenControls.swift", "}.driverAnchor(driverID)",
     "            @unknown default: break\n            }\n        }\n    }\n\n"
     "    /// One VoiceOver increment or decrement",
     "            @unknown default: break\n            }\n        }.driverAnchor(driverID)\n    }\n\n"
     "    /// One VoiceOver increment or decrement", False),
    ("MaskPanel.swift", '.driverAnchor("mask-row")',
     "        .onHover { inside in state.hoverMaskOverlay(inside ? mask.id : nil) }\n    }\n",
     "        .onHover { inside in state.hoverMaskOverlay(inside ? mask.id : nil) }"
     '.driverAnchor("mask-row")\n    }\n', False),
    ("MaskPanel.swift", '.driverAnchor("mask-kind/"',
     "        .help(MaskPanel.kindPurpose(kind))\n",
     '        .help(MaskPanel.kindPurpose(kind)).driverAnchor("mask-kind/" + MaskPanel.kindName(kind))\n',
     False),
    ("MaskFloatingPanel.swift", '.driverAnchor("mask-create")',
     '        .help("Create a new mask — every kind, on one board")\n',
     '        .help("Create a new mask — every kind, on one board")\n'
     '        .driverAnchor("mask-create")\n', False),
    # Names for the shared controls, each appended to an existing line so no line moves.
    ("LumenControls.swift", '.driverAnchor("section/" + title)',
     "        .animation(Lumen.motionState, value: hovering)\n        .padding(.top, topRhythm)\n",
     '        .animation(Lumen.motionState, value: hovering).driverAnchor("section/" + title)\n'
     "        .padding(.top, topRhythm)\n", False),
    ("LumenControls.swift", '.driverAnchor("segment/" + option.label)',
     "                .lumenClickCursor()\n            }\n        }\n"
     "        // One group, so the options read as a set",
     '                .lumenClickCursor().driverAnchor("segment/" + option.label)\n            }\n'
     "        }\n        // One group, so the options read as a set", False),
    ("LumenControls.swift", '.driverAnchor("toggle/" + title)',
     "        .accessibilityAction { if isEnabled { isOn.toggle() } }\n",
     '        .accessibilityAction { if isEnabled { isOn.toggle() } }.driverAnchor("toggle/" + title)\n',
     False),
    ("LumenMenu.swift", '.driverAnchor("menu/" + title)',
     "        .help(help ?? title)\n",
     '        .help(help ?? title).driverAnchor("menu/" + title)\n', False),
    ("LumenMenu.swift", '.driverAnchor("menuitem/" + title)',
     "        .onHover { hovering = $0 }\n        .animation(Lumen.motionState, value: hovering)\n"
     "    }\n}\n",
     "        .onHover { hovering = $0 }\n"
     '        .animation(Lumen.motionState, value: hovering).driverAnchor("menuitem/" + title)\n'
     "    }\n}\n", False),
    ("LumenMenu.swift", '.driverAnchor("picker/" + title)',
     "                        selection = option.value\n                    }\n                }\n"
     "            }\n            Spacer(minLength: 0)\n",
     "                        selection = option.value\n                    }\n                }\n"
     '            }.driverAnchor("picker/" + title)\n            Spacer(minLength: 0)\n', False),
    ("SettingsSubsetSheet.swift", '.driverAnchor("checkbox/" + group.title)',
     "                    LumenCheckbox(isOn: binding(for: group))\n",
     '                    LumenCheckbox(isOn: binding(for: group)).driverAnchor("checkbox/" + group.title)\n',
     False),
    ("FilmstripView.swift", '.driverAnchor("filmstrip-cell/"',
     "                                      loader: state.thumbnails)\n",
     "                                      loader: state.thumbnails)"
     '.driverAnchor("filmstrip-cell/" + photo.filename)\n', False),
    ("GridView.swift", '.driverAnchor("grid-cell/"',
     "                                      loader: state.thumbnails)\n",
     "                                      loader: state.thumbnails)"
     '.driverAnchor("grid-cell/" + photo.filename)\n', False),
    ("ContentView.swift", '.driverAnchor("source/" + title)',
     '        .accessibilityLabel(Text("\\(title), \\(count) photograph\\(count == 1 ? "" : "s")"))\n',
     '        .accessibilityLabel(Text("\\(title), \\(count) photograph\\(count == 1 ? "" : "s")"))'
     '.driverAnchor("source/" + title)\n', False),
    ("DevelopColumn.swift", '.driverAnchor("rail/" + workspace.title)',
     '        .help("\\(workspace.title) (⌘\\(workspace.shortcutDigit))")\n',
     '        .help("\\(workspace.title) (⌘\\(workspace.shortcutDigit))")'
     '.driverAnchor("rail/" + workspace.title)\n', False),
    ("ViewerOverlays.swift", '.driverAnchor("crop-corner/"',
     '                .help("Drag to reframe from this corner.")\n',
     '                .help("Drag to reframe from this corner.")'
     '.driverAnchor("crop-corner/" + handle.rawValue)\n', False),
    ("ViewerOverlays.swift", '.driverAnchor("crop-edge/"',
     '                .help("Drag to move this edge on its own.")\n',
     '                .help("Drag to move this edge on its own.")'
     '.driverAnchor("crop-edge/" + handle.rawValue)\n', False),
    ("HealCanvas.swift", '.driverAnchor("heal.canvas")',
     "        .gesture(press)\n        .lumenPickCursor(true)\n",
     '        .gesture(press)\n        .lumenPickCursor(true).driverAnchor("heal.canvas")\n', False),
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
