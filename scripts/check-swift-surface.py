#!/usr/bin/env python3
"""Four mechanical passes over the Swift sources, for when there is no compiler.

This is NOT a type checker and must never be described as one. It catches four classes
of error, all of which a tree that has not been compiled in a while is likely to carry:

  1. a capitalized identifier that is declared nowhere in-tree and is not a known
     platform name — a typo, a rename that missed a site, a type from a module that is
     not imported;
  2. a `Type(...)` call whose argument labels match none of that type's initializers —
     the DECLARED ones, and for a struct with no `init` of its own the MEMBERWISE one
     Swift synthesizes. The memberwise half arrived late and mattered most: 170 of the
     app layer's 195 types declare no init, so every call to them — every
     `LumenSlider(...)` included — was silently unchecked, which is how a `help:`
     passed before `step:` shipped under a green run (docs/31 postscript);
  3. a call to an actor-isolated member with no `await` — written because exactly that
     was found by hand in this codebase, in code that passes 1 and 2 both accept;
  4. a `TypeName.member` reference naming nothing that type has — a rename that updated
     the declaration and missed the references.

Every pass was verified able to fail before being trusted: nine mutations — wrong
label, extra argument, reordered labels, missing required argument, a renamed type, a
type from an unimported module, a stripped `await`, and two renamed statics — are
caught nine times out of nine, and the unmutated tree stays silent. A check that has
never failed proves nothing, which is the rule the rest of this project's verification
is built on. That verification is now PERMANENT rather than anecdotal:
`scripts/test-check-swift-surface.py` runs a fixture suite of known-good and known-bad
trees on every CI push, and the known-bad set includes the exact false negative this
script shipped (the memberwise call with a multi-line ternary argument, out of order).

WHAT IT STILL CANNOT SEE, so that a clean run is not read as more than it is: types.
Every argument here is checked by label and never by type, so passing a Double where an
Int is wanted is invisible. Leading-dot member syntax (`.jpeg`) carries no type name, so
a renamed enum case is invisible. Generic constraints, protocol conformance, optionality
and mutability are all invisible. Only a compiler sees those.

Deliberately conservative — anything it cannot parse cleanly is SKIPPED and counted
rather than reported, because a false report costs a real investigation. The skip count
is printed so the silence is visible rather than implied.

    python3 scripts/check-swift-surface.py     # 0 if clean, 1 if anything is flagged
"""

import collections
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if not (ROOT / "Package.swift").exists():
    sys.exit("expected to sit in <package>/scripts/")

FILES = sorted(ROOT.glob("Sources/**/*.swift")) + sorted(ROOT.glob("Tests/**/*.swift"))

def _scan(text, blank_strings):
    """Blank out comments — and optionally string bodies — in ONE pass, replacing each
    character with a space and preserving every newline.

    One pass, not a sequence of regexes, because the two constructs nest into each
    other and a regex for either alone is wrong in the presence of the other. Stripping
    comments first ate the `//` inside `"http://www.w3.org/…"`, which truncated the
    string, desynced every quote after it, and leaked the following identifiers as bare
    code — a false positive that cost a real investigation. Stripping strings first has
    the mirror problem: a `"` inside a comment desyncs the strings.

    Preserving length and newlines also keeps reported line numbers exact. The previous
    version collapsed multi-line strings to two characters, so every line number after
    one was wrong — which sends you to the wrong place in the file, and a checker that
    points at innocent code is worse than one that says nothing.
    """
    out = list(text)
    i, n = 0, len(text)

    def blank(start, stop):
        for k in range(start, stop):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            j = n if j == -1 else j
            blank(i, j)
            i = j
        elif two == "/*":
            # Swift block comments nest.
            depth, j = 1, i + 2
            while j < n and depth:
                if text[j:j + 2] == "/*":
                    depth += 1
                    j += 2
                elif text[j:j + 2] == "*/":
                    depth -= 1
                    j += 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif text[i:i + 3] == '"""':
            j = text.find('"""', i + 3)
            j = n if j == -1 else j + 3
            if blank_strings:
                blank(i, j)
            i = j
        elif text[i] == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"' or text[j] == "\n":
                    break
                j += 1
            j = min(j + 1, n)
            if blank_strings:
                blank(i, j)
            i = j
        else:
            i += 1
    return "".join(out)


def strip_comments(text):
    """Comments out; string literals left in place as delimiters."""
    return _scan(text, blank_strings=False)


def strip_all_keep_quotes(text):
    """String bodies blanked, delimiter quotes kept.

    Pass 2 needs both halves: prose inside a string must not read as a call (so bodies
    go), but a positional string ARGUMENT must still count as an argument (so the
    quotes stay, and the argument walk sees a non-empty part where `"Tone"` was).
    Blanking the quotes too made `DevelopSection("Tone", isModified: …)` read as a
    call missing its first argument — 70 false reports in one run. `_scan` preserves
    length, so the two variants recombine by position.
    """
    bodies = strip_all(text)
    delims = strip_comments(text)
    return "".join('"' if q == '"' else c for c, q in zip(bodies, delims))


def strip_all(text):
    r"""Comments AND string bodies out, so prose cannot invent symbols.

    Known limit: a string literal NESTED inside an interpolation, as in
    `"\(flag ? "yes" : "no")"`, defeats the quote tracking — the scanner closes the
    outer string at the first inner quote, so the text between the inner quotes is read
    as code. A capitalized word there is reported by pass 1 as an identifier declared
    nowhere in-tree. That is a false POSITIVE, which is the safe direction to fail, and
    the remedy at a call site is to compute the value outside the interpolation. Teaching
    `_scan` to track interpolation depth would fix it and risks false NEGATIVES in a tool
    whose whole value is that it does not miss things, so it is left as a documented
    limit rather than a clever scanner.
    """
    return _scan(text, blank_strings=True)


# ==========================================================================
# Pass 1 — every capitalized identifier resolves
# ==========================================================================

DECL = re.compile(r"\b(?:struct|class|enum|protocol|actor|typealias)\s+([A-Z]\w*)")
EXTENSION = re.compile(r"\bextension\s+([A-Z]\w*)")
# Not preceded by a dot: `Foo.Bar` and `T.Type` resolve through their base, which
# is checked on its own, and `.RGBAf` is an enum case rather than a type.
CAPITALIZED = re.compile(r"(?<![\w.])([A-Z]\w*)\b")
# Pass 5 also needs lower-case module symbols (sqlite3_open), which CAPITALIZED
# by construction cannot see.
SYMBOLISH = re.compile(r"(?<![\w.])([A-Za-z_]\w*)\b")
# Generic parameter lists, so `struct BeforeAfterSplit<Before: View, After: View>`
# declares `Before` and `After` rather than reporting them as unknown types.
GENERIC_LIST = re.compile(
    r"\b(?:struct|class|enum|protocol|actor|func|init)\s+\w*\s*<([^<>]*)>")
GENERIC_NAME = re.compile(r"\b([A-Z]\w*)\s*(?::|,|$)")

# Platform and stdlib names. Anything here is asserted to exist; anything NOT here and
# not declared in-tree gets reported, so adding a genuinely new platform type means
# adding it here — which is the point. Single capital letters are generic parameters.
KNOWN = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ") | {
    # Dispatch: `LUT3D`'s bake fans slices across cores, and libdispatch is available
    # on both platforms this builds for.
    "Dispatch", "DispatchQueue", "DispatchSemaphore", "DispatchGroup",
    # stdlib
    "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32",
    "UInt64", "Double", "Float", "Float32", "Float64", "Bool", "String", "Substring",
    "Character", "Array", "Dictionary", "Set", "Optional", "Result", "Range",
    # `#filePath` and `#line` defaults on a test helper, so a failure reports the
    # CALL site rather than the helper's own line.
    "StaticString",
    "ClosedRange", "Sequence", "Collection", "Comparable", "Equatable", "Hashable",
    "Hasher", "Codable", "Encodable", "Decodable", "Sendable", "Error",
    "LocalizedError", "Any",
    "AnyObject", "AnyHashable", "Void", "Never", "Self", "Swift", "Identifiable",
    "CustomStringConvertible", "RawRepresentable", "CaseIterable", "Numeric",
    "OptionSet",
    "AdditiveArithmetic", "BinaryFloatingPoint", "BinaryInteger", "FloatingPoint",
    "StringProtocol", "ContiguousArray", "ArraySlice", "MemoryLayout", "Mirror",
    "ObjectIdentifier", "OpaquePointer", "UnsafePointer", "UnsafeMutablePointer",
    "UnsafeRawPointer", "UnsafeMutableRawPointer", "UnsafeBufferPointer",
    "UnsafeMutableBufferPointer", "Task", "TaskPriority", "MainActor", "Actor",
    "CheckedContinuation", "AsyncStream", "SystemRandomNumberGenerator",
    "RandomNumberGenerator", "WritableKeyPath", "ReferenceWritableKeyPath", "KeyPath",
    "ObjCBool", "Duration", "ContinuousClock", "SuspendingClock",
    # Foundation
    "Foundation", "Data", "Date", "DateComponents", "DateFormatter", "TimeInterval",
    "URL", "URLResourceKey", "URLSession", "URLRequest", "URLResponse", "UUID",
    "FileManager", "FileHandle", "ProcessInfo", "FileWrapper", "Bundle", "JSONEncoder", "JSONDecoder",
    "JSONSerialization", "PropertyListEncoder", "PropertyListDecoder",
    "PropertyListSerialization", "NSError", "NSString", "NSNumber", "NSObject",
    "NSCondition", "NSLock", "NSRecursiveLock", "NSRegularExpression", "NSRange",
    "NSLog", "NSAttributedString",
    "NSItemProvider", "NSSize", "NSPoint", "Notification", "NotificationCenter", "Locale",
    "Calendar", "TimeZone", "ISO8601DateFormatter", "NumberFormatter",
    "ByteCountFormatter", "CharacterSet", "IndexSet", "Scanner", "Timer", "Process",
    "Pipe", "Thread", "OperationQueue", "DispatchQueue", "DispatchGroup",
    "DispatchSemaphore", "DispatchTime", "Measurement", "UserDefaults",
    "XMLParser", "XMLParserDelegate", "FoundationXML", "Combine", "AnyCancellable",
    "ObservableObject", "Published", "Encoder", "Decoder", "CodingKey", "CodingKeys",
    "DecodingError", "EncodingError", "KeyedDecodingContainer", "KeyedEncodingContainer",
    "SingleValueDecodingContainer", "SingleValueEncodingContainer",
    "UnkeyedDecodingContainer", "UnkeyedEncodingContainer",
    # XCTest
    "XCTest", "XCTestCase", "XCTestExpectation", "XCTSkip", "XCTSkipUnless",
    # `XCTWaiter` for a test that must bound how long it waits rather than
    # assert on a value — a hang produces no failing test to assert on.
    "XCTWaiter", "XCTExpectFailure",
    "XCTUnwrap", "XCTFail", "XCTAssertEqual", "XCTAssertNotEqual", "XCTAssertTrue",
    "XCTAssertFalse", "XCTAssertNil", "XCTAssertNotNil", "XCTAssertGreaterThan",
    "XCTAssertLessThan", "XCTAssertGreaterThanOrEqual", "XCTAssertLessThanOrEqual",
    "XCTAssertThrowsError", "XCTAssertNoThrow",
    # CoreGraphics / ImageIO / CoreImage / CoreText
    "CoreGraphics", "CGFloat", "CGPoint", "CGSize", "CGRect", "CGVector",
    "CGAffineTransform", "CGImage", "CGColor", "CGColorSpace", "CGContext",
    "CGDataProvider", "CGPath", "CGMutablePath", "CGBitmapInfo", "CGImageAlphaInfo",
    "CGColorRenderingIntent", "CGImageSource", "CGImageDestination",
    "CGImagePropertyOrientation", "CGDirectDisplayID",
    "CGImageSourceCreateWithURL", "CGImageSourceCreateThumbnailAtIndex",
    "CGImageDestinationCreateWithURL", "CGImageDestinationAddImage",
    "CGImageDestinationFinalize",
    "ImageIO", "CFString", "CFDictionary", "CFData", "CFURL",
    "CoreImage", "CIImage", "CIContext", "CIFilter", "CIFilterBuiltins", "CIColor",
    "CIVector", "CIRAWFilter", "CIRAWDecoderVersion", "CIKernel", "CIColorKernel", "CIWarpKernel",
    "OSSignposter",
    "CIBlendKernel", "CISampler", "CIFormat", "CIRenderDestination", "CIColorCube",
    "CIImageRepresentationOption", "CIContextOption",
    "RGBAf", "RGBAh", "RGBA8", "RGBA16",
    "CoreText", "CTFontCreateWithName",
    "CVPixelBuffer", "IOSurface", "OSStatus",
    # Compilation conditions, not identifiers: SwiftPM defines DEBUG in the debug
    # configuration, and `#if DEBUG` is how a probe says which build its numbers
    # came from.
    "DEBUG", "SWIFT_PACKAGE",
    # Vision + CoreVideo: the subject / person mattes (docs/08 §8.8). Listed
    # individually rather than by prefix, so a typo in a request's name is still a
    # failure here; the prefixes below are what make the IMPORT check work.
    "Vision", "VNImageRequestHandler", "VNGenerateForegroundInstanceMaskRequest",
    "VNGeneratePersonSegmentationRequest", "VNInstanceMaskObservation",
    "VNPixelBufferObservation", "VNObservation", "VNRequest",
    # CryptoKit: the updater's SHA-256 over the downloaded asset (L-03). Named
    # individually for the same reason Vision's requests are — this tree uses exactly
    # one primitive from it, and a typo in a second should still fail here.
    "CryptoKit", "SHA256", "SHA256Digest",
    "CoreVideo", "CVPixelBufferGetWidth", "CVPixelBufferGetHeight",
    "CVPixelBufferGetPixelFormatType", "CVPixelBufferGetBytesPerRow",
    "CVPixelBufferGetBaseAddress", "CVPixelBufferLockBaseAddress",
    "CVPixelBufferUnlockBaseAddress", "CVPixelBufferLockFlags",
    "CVPixelBufferCreate",
    # Metal
    "MTLDevice", "MTLTexture", "MTLCommandQueue", "MTLPixelFormat",
    "MTLCreateSystemDefaultDevice",
    # AppKit
    "AppKit", "NSApp", "NSApplication", "NSApplicationDelegate", "NSImage", "NSColor",
    "NSView", "NSViewRepresentable", "NSViewController", "NSWindow", "NSEvent",
    "NSCursor", "NSMenu", "NSMenuItem", "NSPasteboard", "NSSavePanel", "NSOpenPanel",
    "NSWorkspace", "NSBezierPath", "NSGraphicsContext", "NSScreen", "NSFont",
    "NSSound", "NSAlert", "NSStatusBar", "NSTextField", "NSTextView", "NSHostingView",
    "NSHostingController", "ModifierFlags", "OK", "NSHapticFeedbackManager",
    "NSLeftArrowFunctionKey", "NSRightArrowFunctionKey", "NSUpArrowFunctionKey",
    "NSDownArrowFunctionKey", "NSDeleteFunctionKey",
    # SwiftUI
    # `Font` arrived with `LumenType`, the app's type scale — `Font.system(size:weight:)`
    # is the only way to build one, so the ramp cannot be declared without it.
    "Font",
    "SwiftUI", "View", "Text", "Image", "Color", "VStack", "HStack", "ZStack",
    "Spacer", "Button", "Slider", "Toggle", "Picker", "ColorPicker", "TextField",
    "SecureField",
    "List", "ForEach", "ScrollView", "ScrollViewReader", "LazyVGrid", "LazyHGrid",
    "LazyVStack", "LazyHStack", "GridItem", "NavigationStack", "NavigationSplitView",
    "NavigationLink", "Divider", "Group", "GroupBox", "Form", "Section", "Menu",
    "Label", "Link", "ProgressView", "Gauge", "Stepper", "DisclosureGroup", "TabView",
    "Table", "TableColumn", "GeometryReader", "GeometryProxy", "Canvas",
    "GraphicsContext", "Path", "Shape", "Rectangle", "RoundedRectangle", "Circle",
    "Ellipse", "Capsule", "Binding", "State", "StateObject", "ObservedObject",
    "EnvironmentObject", "Environment", "EnvironmentValues", "EnvironmentKey",
    "PreferenceKey", "ViewModifier", "ViewBuilder", "App", "Scene", "WindowGroup",
    "Settings", "Commands", "CommandGroup", "CommandMenu", "AppStorage",
    "SceneStorage", "FocusState", "Namespace", "Animation", "Transaction",
    "KeyPress",
    "Alignment", "HorizontalAlignment", "VerticalAlignment", "Edge", "EdgeInsets",
    "Angle", "UnitPoint", "Font", "LinearGradient", "RadialGradient",
    "AngularGradient", "Gradient", "DragGesture", "TapGesture", "Gesture",
    "MagnifyGesture",
    "MagnificationGesture", "RotationGesture", "LongPressGesture", "AnyView",
    "EmptyView", "ToolbarItem", "ToolbarItemGroup", "KeyboardShortcut",
    "KeyEquivalent", "EventModifiers", "ContentMode", "ColorScheme", "Axis",
    "Visibility", "ShapeStyle", "Material", "StrokeStyle", "FillStyle",
    "DismissAction", "MoveCommandDirection", "Value",
    "NSApplicationDelegateAdaptor", "UTType", "UniformTypeIdentifiers",
    # SQLite
    "SQLite3", "SQLITE_OK", "SQLITE_NULL", "SQLITE_MISUSE", "SQLITE_CORRUPT",
    "SQLITE_NOTADB", "SQLITE_FORMAT", "SQLITE_OPEN_READWRITE", "SQLITE_OPEN_CREATE",
    "SQLITE_OPEN_FULLMUTEX", "SQLITE_ERROR", "SQLITE_ROW", "SQLITE_DONE",
    # ImageIO
    "ImageIO", "CGImageSourceCopyPropertiesAtIndex",
    "CChar", "UTF8", "NSNull",
    # this package's own modules
    "LumenCore", "LumenPipeline", "LumenApp",
}


def pass_symbols():
    declared = set()
    for path in FILES:
        text = path.read_text()
        declared |= set(DECL.findall(text))
        declared |= set(EXTENSION.findall(text))
        for params in GENERIC_LIST.findall(text):
            declared |= set(GENERIC_NAME.findall(params))

    unknown = {}
    for path in FILES:
        text = strip_all(path.read_text())
        for lineno, line in enumerate(text.split("\n"), 1):
            for name in CAPITALIZED.findall(line):
                if name in declared or name in KNOWN:
                    continue
                unknown.setdefault(name, []).append(
                    (path.relative_to(ROOT).as_posix(), lineno))

    if not unknown:
        print("symbols:  every capitalized identifier resolves")
        return True

    print(f"symbols:  {len(unknown)} identifiers declared nowhere in-tree and not on "
          f"the known-platform list\n")
    for name in sorted(unknown, key=lambda n: -len(unknown[n])):
        sites = unknown[name]
        where = ", ".join(f"{p}:{l}" for p, l in sites[:3])
        more = f" (+{len(sites) - 3} more)" if len(sites) > 3 else ""
        print(f"  {name:<34} {len(sites):>4}x  {where}{more}")
    print("\n  If one of these is a real platform type, add it to KNOWN in this file.")
    return False


# ==========================================================================
# Pass 2 — every Type(...) matches a declared initializer
# ==========================================================================

LABEL = re.compile(r"^\s*(?:([a-zA-Z_]\w*)\s+)?([a-zA-Z_]\w*)\s*:")
# A parameter can open with attributes — `@ViewBuilder content: () -> Content` — which
# LABEL cannot see past. Stripping them before the match is what kept `ExportFieldRow`'s
# real `init(_:content:)` on the books; losing it both hid the declaration AND (before
# suppression was split from parsing) let a wrong memberwise signature be synthesized
# over it, which reported thirteen perfectly good call sites.
PARAM_ATTRS = re.compile(r"^\s*(?:@\w+(?:\([^()]*\))?\s+)+")


def strip_param_attrs(param):
    return PARAM_ATTRS.sub("", param, count=1)
TYPE_DECL = re.compile(r"\b(?:struct|class|enum|actor)\s+([A-Z]\w*)")
INIT_DECL = re.compile(r"\binit\s*(?:\?|!)?\s*\(")
EXT_DECL = re.compile(r"\bextension\s+([A-Z][\w.]*)")
CALL = re.compile(r"(?<![\w.])([A-Z]\w*)\s*\(")


def match_paren(text, open_index):
    """Index just past the ')' matching the '(' at open_index, honouring strings."""
    depth = 0
    i, n = open_index, len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 1
                i += 1
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return None


def split_top(text):
    """Split on commas not nested in brackets, generic arguments, or strings.

    `<`/`>` cannot be counted as plain brackets: `->` appears in every closure-typed
    parameter and counting its `>` as a close ran the depth negative, which swallowed
    the parameter after it and produced four confident false reports the first time
    this was run.

    But leaving them out entirely was worse, and silently so. A comma inside a generic
    argument list — `WritableKeyPath<LocalAdjust, Double?>` — split one parameter into
    two halves, the second (` Double?>`) matched no label pattern, and `collect_methods`
    dropped the WHOLE METHOD rather than the parameter. Twenty-three method names went
    unrecorded that way, and they were not obscure: `adjustSlider`, `optionalSlider`,
    `refineSlider`, `bipolarSlider`, `wheelValue`, `brushValue` — the panel's slider
    builders, which is to say the most-called helpers in the code that has broken the
    macOS lane three times. Every call site to all twenty-three was unchecked, and one
    of them was the extra-argument error that broke it a fourth.

    So `<` opens a level only where it can only be a generic: immediately after an
    identifier character, and never as part of `->`. `>` closes one only while a level
    is open and it is not the tail of `->`. A comparison in a default value (`= a < b`)
    has a space before its `<` and opens nothing.
    """
    parts, depth, angle, cur, i, n = [], 0, 0, [], 0, len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            cur.append(ch)
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    cur.append(text[i])
                    i += 1
                cur.append(text[i])
                i += 1
            cur.append('"' if i < n else "")
        elif ch in "([{":
            depth += 1
            cur.append(ch)
        elif ch in ")]}":
            depth -= 1
            cur.append(ch)
        elif ch == "<" and i > 0 and (text[i - 1].isalnum() or text[i - 1] == "_"):
            angle += 1
            cur.append(ch)
        elif ch == ">" and angle > 0 and not (i > 0 and text[i - 1] == "-"):
            angle -= 1
            cur.append(ch)
        elif ch == "," and depth == 0 and angle == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    if "".join(cur).strip():
        parts.append("".join(cur))
    return parts


def collect_inits():
    """type name -> [(parameter labels, required labels)].

    Returns (inits, main_body_init_names): the second set records which type names
    declare an explicit `init` in a MAIN type body (not an extension), because that —
    and only that — is what suppresses Swift's memberwise initializer.
    """
    inits = {}
    main_body_init_names = set()
    for path in FILES:
        # Strings blanked, not just comments: `print("… Exposure (draft path) …")`
        # reads as a call to the test fixture's `Exposure` the moment that struct has
        # a synthesized signature, and prose must not be judged as code. Labels and
        # defaults survive blanking — only string BODIES go.
        text = strip_all_keep_quotes(path.read_text())
        scopes, depth, i, n = [], 0, 0, len(text)
        while i < n:
            ch = text[i]
            if ch == "{":
                depth += 1
                i += 1
                continue
            if ch == "}":
                depth -= 1
                while scopes and scopes[-1][1] > depth:
                    scopes.pop()
                i += 1
                continue
            m = TYPE_DECL.match(text, i)
            kind = "type" if m else "ext"
            if not m:
                m = EXT_DECL.match(text, i)
            if m:
                if text.find("{", m.end()) != -1:
                    scopes.append((m.group(1).split(".")[-1], depth + 1, kind))
                i = m.end()
                continue
            m = INIT_DECL.match(text, i)
            if m and scopes:
                # ANY init in a main type body suppresses the memberwise initializer,
                # whether or not its parameters parse below — Swift suppresses on the
                # declaration's existence, so synthesis must too, or an unparseable
                # init leaves a wrong synthesized signature standing in for a real one.
                if scopes[-1][2] == "type":
                    main_body_init_names.add(scopes[-1][0])
                open_i = m.end() - 1
                close = match_paren(text, open_i)
                if close:
                    labels, required, ok = [], [], True
                    for param in split_top(text[open_i + 1:close - 1]):
                        param = strip_param_attrs(param)
                        lm = LABEL.match(param)
                        if not lm:
                            ok = False
                            break
                        external = lm.group(1) or lm.group(2)
                        label = None if external == "_" else external
                        labels.append(label)
                        if "=" not in param.split(":", 1)[1]:
                            required.append(label)
                    if ok:
                        inits.setdefault(scopes[-1][0], []).append((labels, required))
                    i = close
                    continue
            i += 1
    return inits, main_body_init_names


# --------------------------------------------------------------------------
# Memberwise synthesis, for pass 2.
#
# The hole this closes was live and measured: 170 of the app layer's 195 types declare
# no explicit `init`, so every call to them — `LumenSlider(...)` at ~90 sites included —
# was invisible to pass 2, silently, with no entry in the skip count. That is how a
# `help:` passed before `step:` sailed under "2797 call sites match a declared
# initializer, 0 unparseable" and cost a macOS CI round. docs/31's postscript blamed
# `split_top`; the truth was that the site was never looked at.
#
# Swift synthesizes a memberwise initializer for a struct with no init in its MAIN
# body (an init in an extension does not suppress it), taking the stored properties in
# declaration order. The synthesis below models the rules that matter for label
# checking, and BAILS (per struct, counted and printed) on anything it cannot model
# with confidence, because a wrong signature here manufactures false reports:
#   - `let` with a value is not a parameter; `let` without one is required
#   - `var` with a value is defaulted; a plain optional `var` defaults to nil (SE-0242)
#   - a wrapped property whose attribute carries arguments (@Environment(\.x),
#     @AppStorage("k")) is initialized by the attribute and is not a parameter
#   - a private/fileprivate stored property WITH a value is not a parameter and does
#     not restrict the initializer (this is what lets `@State private var` views be
#     built from other files); one WITHOUT a value makes the whole signature
#     unmodelable from here, so the struct is bailed
#   - computed properties (body without willSet/didSet) are not parameters
#   - `lazy`, `#if` in the body, or an unparseable property → bail the struct
# --------------------------------------------------------------------------

STRUCT_DECL = re.compile(r"\bstruct\s+([A-Z]\w*)")
# Wrappers whose no-argument `init()` the compiler reaches for, so the property is no
# parameter at all. Only wrappers KNOWN to self-initialize belong here; an unknown
# wrapper is kept in the labels un-required instead, which cannot false-report.
# Wrappers that build themselves and can therefore never be a memberwise parameter.
# A PRIVATE stored property with no default otherwise forces `synthesize_memberwise` to
# bail on the whole struct — and a bailed struct is one whose every call site goes
# UNCHECKED, silently.
#
# `Environment` arrived here the expensive way. `LumenSlider` holds two of them
# (`@Environment(\.sliderGestureChanged) private var …`), so it was one of thirteen
# bailed structs, so all ninety-odd `LumenSlider(…)` call sites — the most-used control
# in the application — were exempt from the init pass. A new parameter was then added in
# the middle of its property list and called in the wrong position at four sites: the
# `accepts` walk below would have caught it in a second, and never saw the calls. It
# cost four red pushes and the dev build with them.
#
# The list is a claim about SwiftUI, not a guess: none of these has an
# `init(wrappedValue:)`, so none can appear in a synthesized memberwise initializer.
SELF_INITIALIZING_WRAPPERS = {"EnvironmentObject", "Namespace", "GestureState",
                              "FocusState", "Environment", "ScaledMetric",
                              "FocusedValue", "Query"}
PROP_ATTR = r"@\w+(?:\([^()]*(?:\([^()]*\)[^()]*)*\))?"
PROP_MOD = (r"(?:public|internal|open|final|static|lazy|weak|nonisolated|override|"
            r"indirect|dynamic|package|private(?:\(set\))?|fileprivate(?:\(set\))?|"
            r"internal\(set\)|unowned(?:\(safe\)|\(unsafe\))?)")
PROP_DECL = re.compile(
    r"(?:^|\n)[ \t]*((?:(?:" + PROP_ATTR + r")\s+|" + PROP_MOD + r"\s+)*)"
    r"(let|var)\s+([a-zA-Z_]\w*)\s*([:=])")


def _depth0_mask(body):
    """The body with everything inside nested braces blanked, offsets preserved."""
    out, depth = list(body), 0
    for i, ch in enumerate(body):
        if ch == "{":
            depth += 1
            continue
        if ch == "}":
            depth -= 1
            continue
        if depth > 0 and ch != "\n":
            out[i] = " "
    return "".join(out)


def synthesize_memberwise(suppressed):
    """struct name -> (labels, required) for structs with no main-body init."""
    out, bailed = {}, set()
    for path in FILES:
        # strip_all for the same reason as collect_inits: a multi-line string at a
        # struct body's top level (an SQL literal, a help paragraph) must not donate
        # phantom properties to the signature.
        text = strip_all_keep_quotes(path.read_text())
        for m in STRUCT_DECL.finditer(text):
            name = m.group(1)
            if name in suppressed:
                continue
            brace = text.find("{", m.end())
            if brace == -1:
                continue
            body = brace_body(text, brace)
            if "#if" in _depth0_mask(body):
                bailed.add(name)
                continue
            mask = _depth0_mask(body)
            labels, required, ok = [], [], True
            for pm in PROP_DECL.finditer(mask):
                mods, keyword, pname, sep = pm.groups()
                if re.search(r"\bstatic\b", mods):
                    continue
                if re.search(r"\blazy\b", mods):
                    ok = False
                    break
                attrs = re.findall(r"@(\w+)(\()?", mods)
                wrapped = [a for a, _ in attrs if a[0].isupper()]
                attr_initialized = any(p for a, p in attrs if a[0].isupper())
                private = re.search(r"\b(?:private|fileprivate)\b(?!\(set\))", mods)
                has_default, is_computed, type_text = sep == "=", False, ""
                if sep == ":":
                    i, depth, n = pm.end(), 0, len(mask)
                    while i < n:
                        ch = mask[i]
                        if ch in "([":
                            depth += 1
                        elif ch in ")]":
                            depth -= 1
                        elif depth == 0 and ch == "=":
                            has_default = True
                            break
                        elif depth == 0 and ch == "{":
                            inner = brace_body(body, i)
                            is_computed = not re.match(r"\s*(?:willSet|didSet)\b",
                                                       inner)
                            break
                        elif depth == 0 and ch == "\n":
                            break
                        type_text += ch
                        i += 1
                if is_computed:
                    continue
                if attr_initialized:
                    continue                       # the attribute built the wrapper
                if any(w in SELF_INITIALIZING_WRAPPERS for w in wrapped):
                    continue                       # the wrapper builds itself
                if private:
                    # AN OPTIONAL HAS AN IMPLICIT `nil`, which is a default like any
                    # other. `optional_plain` is computed below for exactly this
                    # reason and was consulted only for the non-private branch, so
                    # `@State private var closer: Task<Void, Never>?` — one property,
                    # in one view — vetoed the whole struct.
                    #
                    # That veto is expensive in a way the tally does not show: a bailed
                    # struct is not "partly checked", it is a struct whose EVERY call
                    # site is silently exempt. `LumenSlider` bailed on this line, so all
                    # ninety-odd of its call sites went unchecked, and a parameter added
                    # in the middle of its property list and passed in the wrong
                    # position at four sites reached CI as four red pushes. The
                    # `accepts` walk would have caught it in a second.
                    if has_default or type_text.rstrip().endswith(("?", "!")):
                        continue                   # not a parameter, and not a veto
                    ok = False                     # signature unknowable from here
                    break
                if wrapped:
                    # In the labels, so a reordered call is still caught — but never
                    # REQUIRED, because whether a wrapper self-initializes is the
                    # wrapper's knowledge, not this script's, and a wrong "required"
                    # here reports working calls. `@Binding` omitted at a call site is
                    # the price, and the macOS lanes still catch that.
                    labels.append(pname)
                    continue
                optional_plain = type_text.rstrip().endswith(("?", "!"))
                if keyword == "let":
                    if has_default:
                        continue
                    labels.append(pname)
                    required.append(pname)
                else:
                    labels.append(pname)
                    if not (has_default or optional_plain):
                        required.append(pname)
            if ok:
                out.setdefault(name, []).append((labels, required))
            else:
                bailed.add(name)
    for name in bailed:
        out.pop(name, None)
    return out, bailed


MULTI_TRAILING = re.compile(r"\s*\w+\s*:\s*\{")


def pass_inits():
    inits, suppressed = collect_inits()
    synthesized, bailed = synthesize_memberwise(suppressed)
    for name, sigs in synthesized.items():
        inits.setdefault(name, []).extend(sigs)
    problems, checked, skipped = [], 0, 0

    for path in FILES:
        text = strip_all_keep_quotes(path.read_text())
        for m in CALL.finditer(text):
            name = m.group(1)
            if name not in inits:
                continue
            open_i = m.end() - 1
            close = match_paren(text, open_i)
            if close is None:
                skipped += 1
                continue
            trailing = text[close:close + 40].lstrip().startswith("{")
            if trailing:
                # A second, LABELED trailing closure (`} label: {`) carries its label
                # outside the parentheses, where the argument walk below cannot see
                # it — judging the site on the parenthesized labels alone manufactures
                # a missing-argument report. Skip it, counted, rather than guess.
                brace_i = text.find("{", close)
                inner = brace_body(text, brace_i)
                end = brace_i + len(inner) + 2
                if (end <= len(text) and text[end - 1] == "}"
                        and MULTI_TRAILING.match(text, end)):
                    skipped += 1
                    continue

            call_labels, parse_ok = [], True
            for arg in split_top(text[open_i + 1:close - 1]):
                if not arg.strip():
                    continue
                lm = LABEL.match(arg)
                if lm and lm.group(1) is None:
                    call_labels.append(lm.group(2))
                elif lm is None:
                    call_labels.append(None)
                else:
                    parse_ok = False
                    break
            if not parse_ok:
                skipped += 1
                continue

            def accepts(sig):
                labels, required = sig
                if trailing and labels:
                    labels = labels[:-1]                       # the closure fills it
                    required = [r for r in required if r in labels]
                gi = 0
                for label in labels:
                    if gi < len(call_labels) and call_labels[gi] == label:
                        gi += 1
                return gi == len(call_labels) and all(r in call_labels for r in required)

            checked += 1
            if not any(accepts(s) for s in inits[name]):
                line = text.count("\n", 0, m.start()) + 1
                problems.append((path.relative_to(ROOT).as_posix(), line, name,
                                 call_labels, inits[name]))

    tally = (f"({skipped} unparseable, skipped; {len(synthesized)} memberwise "
             f"signatures synthesized, {len(bailed)} structs too odd to synthesize)")
    if not problems:
        print(f"inits:    {checked} call sites match a declared or memberwise "
              f"initializer {tally}")
        return True

    print(f"inits:    {len(problems)} of {checked} call sites match NO declared "
          f"or memberwise initializer {tally}\n")
    for path, line, name, labels, sigs in problems:
        shown = [l if l else "_" for l in labels]
        print(f"  {path}:{line}  {name}({', '.join(shown)})")
        for lab, req in sigs[:3]:
            rendered = ", ".join(f"{l or '_'}{'' if l in req else '='}" for l in lab)
            print(f"      declared: init({rendered})")
        print()
    return False


# ==========================================================================
# Pass 3 — an actor's isolated method needs `await`
# ==========================================================================
#
# Written because exactly this was found by hand: `RenderCoordinator` is an actor and
# `nativeSize(for:)` was called without one. Resolves identifiers, matches its
# initializer labels, and does not compile.

ACTOR_DECL = re.compile(r"\bactor\s+([A-Z]\w*)")
ACTOR_FUNC = re.compile(r"(?:^|\n)\s*((?:\w+\s+)*)func\s+(\w+)\s*\(")


def brace_body(text, brace_index):
    """The text between the brace at `brace_index` and its match."""
    depth, i, n = 0, brace_index, len(text)
    while i < n:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[brace_index + 1:i]
        i += 1
    return ""


METHOD_DECL = re.compile(
    r"(private\s+|fileprivate\s+)?(?:static\s+|class\s+|mutating\s+|nonmutating\s+"
    r"|final\s+|override\s+|@\w+(?:\([^)]*\))?\s+)*"
    r"\bfunc\s+([a-z]\w*)\s*(?:<[^<>]*>)?\s*\(")
METHOD_CALL = re.compile(r"(?<![\w.])([a-z]\w*|\))\s*\.\s*([a-z]\w*)\s*\(")

# Words that can sit immediately before a leading-dot expression WITHOUT being a
# receiver. `case .mask(let id):` and `return .failure(error)` are an enum case pattern
# and an implicit-member expression; neither is a method call on anything named `case` or
# `return`, but the regex above cannot tell — a keyword is spelled like an identifier.
#
# This was a live false positive rather than a hypothetical one: three `case .mask(let
# id):` patterns in `CurveEditorView` were being judged against `MaskPanel`'s private
# `mask(_:)`, and passed only because the labels happened to line up. Once private
# declarations stopped being visible across files the disguise came off, which is how the
# older bug got found.
RECEIVER_KEYWORDS = {
    "case", "return", "try", "await", "throw", "throws", "in", "else", "where", "is",
    "as", "do", "catch", "default", "break", "continue", "guard", "if", "while", "for",
    "let", "var", "repeat", "switch", "yield", "some", "any", "init", "deinit",
}

# The same call, but through a TYPE rather than a value: `Self.applyLocalAdjust(...)`,
# `RenderGraph.gaussianBlur(...)`. METHOD_CALL requires a lowercase receiver, so every
# static call site was invisible to this pass — which matters most in exactly the code
# this script exists for: `RenderGraph` reaches its stages through `Self.` throughout,
# and none of it compiles on the machine the script runs on. Found by deleting a newly
# required argument at one of those call sites and watching the checker stay silent.
#
# Gated on the receiver being `Self` or a type declared IN-TREE, so a platform call like
# `CGImageDestination.finalize()` is never judged against an in-tree signature that
# happens to share its name.
METHOD_CALL_TYPED = re.compile(r"(?<![\w.])(Self|[A-Z]\w*)\s*\.\s*([a-z]\w*)\s*\(")

# The same call with NO receiver at all: `optionalSlider(id, i, …)` inside the type that
# declares it. Both regexes above require something before the dot, so every implicit-
# `self` call in the application was invisible to this pass — which is most of the calls
# in a SwiftUI view, and it is where the extra-argument error that broke the macOS lane
# lived.
#
# Three filters make it report nothing false over the tree, and each one is a real
# language rule rather than a patch:
#
#   SHADOWING. `commit(edit)` in `MaskCanvas` calls a stored closure PROPERTY, and there
#   is a `func commit` elsewhere in the tree. A bare name that is also bound as a value
#   or a parameter anywhere in the file is a call on that value.
#
#   VARIADICS. `run("/usr/bin/ditto", "-x", …)` is one declared parameter and five
#   arguments, and the label walk counts them. A variadic declaration is skipped whole.
#
#   ENUM CASES. `case mask(String)` inside an enum body is a declaration, not a call.
METHOD_CALL_BARE = re.compile(r"(?<![\w.$@\\#?])([a-z_]\w*)\s*\(")
VALUE_BOUND = re.compile(r"(?:^|[^\w.])(?:let|var)\s+([a-z_]\w*)")
PARAM_LABELLED = re.compile(r"[(,]\s*(?:[a-z_]\w*|_)\s+([a-z_]\w*)\s*:")
PARAM_PLAIN = re.compile(r"[(,]\s*([a-z_]\w*)\s*:")
VARIADIC_DECL = re.compile(
    r"\bfunc\s+([a-z]\w*)\s*(?:<[^<>]*>)?\s*\(([^)]*\.\.\.[^)]*)\)")

# Method names that also exist on stdlib or platform types, where an in-tree
# declaration of the same name says nothing about a call on something else.
METHOD_SKIP = {
    "append", "insert", "remove", "removeAll", "contains", "map", "flatMap",
    "compactMap", "filter", "reduce", "forEach", "sorted", "sort", "first", "last",
    "min", "max", "joined", "split", "prefix", "suffix", "dropFirst", "dropLast",
    "hasPrefix", "hasSuffix", "replacingOccurrences", "trimmingCharacters", "encode",
    "decode", "write", "read", "index", "distance", "advanced", "rounded", "clamped",
    "cropped", "transformed", "applying", "union", "intersection", "subtracting",
    "randomElement", "shuffled", "reversed", "enumerated", "zip", "withUnsafeBytes",
    "withUnsafeBufferPointer", "load", "store", "apply", "callAsFunction", "sync",
    "async", "resume", "cancel", "lock", "unlock", "wait", "signal", "sample",
    "value", "values", "keys", "count", "isEmpty", "description", "hash", "copy",
    "move", "stroke", "fill", "draw", "render", "string", "step", "prepare", "bind",
    "addLine", "closeSubpath", "component", "components", "preview", "artifact",
    "parse", "start", "stop", "reset", "update", "scale", "rotate", "translate",
    "combine", "cgImage",
}


def collect_methods():
    """method name -> [(labels, required labels, file, file_local)] for every in-tree func.

    THE FILE AND THE ACCESS LEVEL COME WITH IT, and they have to, because this pass is
    name-based. `EventRate` declares `private mutating func trim(before:)`; SwiftUI
    declares `Shape.trim(from:to:)`. Without the access level the checker read a
    `Circle().trim(from:to:)` in a different target as a call to the private helper and
    reported a real platform call as a mistake — the exact false positive that trains
    people to add names to `METHOD_SKIP` until the pass stops finding anything.

    A `private` or `fileprivate` declaration is invisible outside its own file, so it
    cannot be what a call in another file resolves to, and must not be judged against.
    """
    out = {}
    for path in FILES:
        text = strip_comments(path.read_text())
        for m in METHOD_DECL.finditer(text):
            file_local = m.group(1) is not None
            name = m.group(2)
            open_i = m.end() - 1
            close = match_paren(text, open_i)
            if close is None:
                continue
            labels, required, ok = [], [], True
            for param in split_top(text[open_i + 1:close - 1]):
                if not param.strip():
                    continue
                param = strip_param_attrs(param)
                lm = LABEL.match(param)
                if not lm:
                    ok = False
                    break
                external = lm.group(1) or lm.group(2)
                label = None if external == "_" else external
                labels.append(label)
                rest = param.split(":", 1)
                if len(rest) > 1 and "=" not in rest[1]:
                    required.append(label)
            if ok:
                out.setdefault(name, []).append((labels, required, path, file_local))
    return out


def pass_method_labels():
    """Argument labels at a method call site must match some in-tree declaration.

    Pass 2 does this for initializers and stops there, which is how
    `store.saveRecipe(recipe, photoID: id, at: now)` reached CI: `saveRecipe` exists,
    so pass 4 and pass 7 both resolve it happily, and neither looks at the labels. The
    real declarations take `isCurrent:` or `kind:name:isCurrent:`, and there is no
    overload ending at `at:`. It cost a macOS round trip to find out, on a build that
    had been green.

    Deliberately name-based rather than type-resolved: this is a text checker, not a
    compiler, and a name declared in-tree with NO declaration accepting the labels
    used is wrong whatever the receiver turns out to be. Names shared with the stdlib
    are skipped, because there an in-tree declaration proves nothing about the call.
    """
    methods = collect_methods()
    problems, checked = [], 0

    variadic = set()
    for path in FILES:
        for m in VARIADIC_DECL.finditer(strip_comments(path.read_text())):
            variadic.add(m.group(1))

    intree_types = set()
    for path in FILES:
        body = strip_comments(path.read_text())
        intree_types.update(DECL.findall(body))
        intree_types.update(EXTENSION.findall(body))

    def call_sites(text, shadowed):
        """Every method call this pass can judge: value-, type- and no-receiver."""
        for m in METHOD_CALL.finditer(text):
            if m.group(1) in RECEIVER_KEYWORDS:
                continue
            yield m, m.group(2)
        for m in METHOD_CALL_TYPED.finditer(text):
            receiver = m.group(1)
            if receiver == "Self" or receiver in intree_types:
                yield m, m.group(2)
        for m in METHOD_CALL_BARE.finditer(text):
            name = m.group(1)
            if name in RECEIVER_KEYWORDS or name in shadowed or name in variadic:
                continue
            before = text[max(0, m.start() - 40):m.start()]
            # The declaration itself, and an enum case with an associated value.
            if re.search(r"\b(?:func|case)\s+$", before):
                continue
            yield m, name

    for path in FILES:
        # Bodies blanked so prose — the schema strings in `CatalogStore`, above all —
        # cannot invent a call, but the delimiter quotes kept so a positional string
        # argument still counts as one. `strip_comments` alone read `photo(added_at)`
        # out of a CREATE INDEX as twenty-three calls to `func photo`.
        text = strip_all_keep_quotes(path.read_text())
        shadowed = (set(VALUE_BOUND.findall(text)) | set(PARAM_LABELLED.findall(text))
                    | set(PARAM_PLAIN.findall(text)))
        for m, name in call_sites(text, shadowed):
            if name in METHOD_SKIP or name not in methods:
                continue
            open_i = m.end() - 1
            close = match_paren(text, open_i)
            if close is None:
                continue
            trailing = text[close:close + 40].lstrip().startswith("{")

            call_labels, parse_ok = [], True
            for arg in split_top(text[open_i + 1:close - 1]):
                if not arg.strip():
                    continue
                lm = LABEL.match(arg)
                if lm and lm.group(1) is None:
                    call_labels.append(lm.group(2))
                elif lm is None:
                    call_labels.append(None)
                else:
                    parse_ok = False
                    break
            if not parse_ok:
                continue

            def matches(labels, required):
                gi = 0
                for label in labels:
                    if gi < len(call_labels) and call_labels[gi] == label:
                        gi += 1
                return gi == len(call_labels) and all(r in call_labels for r in required)

            def accepts(sig):
                labels, required, _, _ = sig
                # A `{` after a method call is a trailing closure OR the body of the
                # `if`/`guard`/`while` the call sits in. Pass 2 can assume the former
                # because `Type(...) {` is nearly always a closure; here both readings
                # are live, so accept either. Costs a narrow class of miss and removes
                # every `if x.f(y) {` false positive.
                if matches(labels, required):
                    return True
                if trailing and labels:
                    trimmed = labels[:-1]
                    return matches(trimmed, [r for r in required if r in trimmed])
                return False

            # Only the declarations this file can actually SEE. A `private` or
            # `fileprivate` func is invisible outside its own file, so a call elsewhere
            # cannot be resolving to it — and judging against it turns a real platform
            # call into a reported mistake. See `collect_methods`.
            visible = [s for s in methods[name] if not s[3] or s[2] == path]
            if not visible:
                continue

            checked += 1
            if not any(accepts(s) for s in visible):
                line = text.count("\n", 0, m.start()) + 1
                problems.append((path.relative_to(ROOT).as_posix(), line, name,
                                 call_labels, visible))

    if not problems:
        print(f"labels:   {checked} method call sites match a declared signature")
        return True
    print(f"labels:   {len(problems)} method calls whose labels match no declaration\n")
    for rel, line, name, used, known in problems[:20]:
        shown = ", ".join(l or "_" for l in used)
        forms = " | ".join(", ".join(l or "_" for l in sig[0]) for sig in known[:3])
        print(f"  {rel}:{line}  {name}({shown})")
        print(f"      declared: {forms}")
    return False


def pass_actor_await():
    actors = {}
    for path in FILES:
        text = strip_comments(path.read_text())
        for m in ACTOR_DECL.finditer(text):
            brace = text.find("{", m.end())
            if brace == -1:
                continue
            body = brace_body(text, brace)
            members = {
                name for mods, name in ACTOR_FUNC.findall(body)
                if "nonisolated" not in mods and "static" not in mods
            }
            actors.setdefault(m.group(1), set()).update(members)

    if not actors:
        print("actors:   no actors declared, nothing to check")
        return True

    # Variables of an actor type, by name. Module-wide and best effort: a local named
    # the same thing as an actor-typed property would be checked too, which errs toward
    # reporting rather than missing.
    variables = {}
    for path in FILES:
        text = strip_comments(path.read_text())
        for actor in actors:
            for m in re.finditer(
                    r"\b(?:let|var)\s+(\w+)\s*(?::\s*%s\b|=\s*%s\s*\()" % (actor, actor),
                    text):
                variables[m.group(1)] = actor

    problems = []
    for path in FILES:
        text = strip_comments(path.read_text())
        for var, actor in variables.items():
            for member in actors[actor]:
                pattern = r"(?<![\w.])(?:self\.)?%s\.%s\s*\(" % (var, member)
                for m in re.finditer(pattern, text):
                    head = text.rfind("\n", 0, m.start())
                    if "await" in text[head + 1:m.start()]:
                        continue
                    previous = text.rfind("\n", 0, head)
                    if previous != -1 and "await" in text[previous + 1:head]:
                        continue
                    line = text.count("\n", 0, m.start()) + 1
                    problems.append((path.relative_to(ROOT).as_posix(), line,
                                     var, member, actor))

    total = sum(len(v) for v in actors.values())
    if not problems:
        print(f"actors:   every call to the {total} isolated members of "
              f"{', '.join(sorted(actors))} is awaited")
        return True

    print(f"actors:   {len(problems)} calls to actor-isolated members with no await\n")
    for path, line, var, member, actor in problems:
        print(f"  {path}:{line}  {var}.{member}(…)   — {actor} is an actor")
    return False


# ==========================================================================
# Pass 4 — TypeName.member must exist on that type
# ==========================================================================
#
# Catches a rename that updated the declaration and missed the references.
#
# WHAT IT CANNOT SEE, stated so nobody reads a clean run as more than it is: leading-dot
# member syntax (`.jpeg`, `.bottomRight`), which is how enum cases are almost always
# written, carries no type name to check against and would need real type inference.
# Renaming an enum case is therefore NOT covered. Renaming a static that is referenced
# by qualified name IS.

MODIFIER = (r"(?:@\w+(?:\([^)]*\))?\s+|\w+\([\w ]*\)\s+|"
            r"(?:public|internal|private|fileprivate|final|static|class|nonisolated|"
            r"mutating|lazy|weak|unowned|override|open|indirect|dynamic|convenience|"
            r"required)\s+)*")

TYPE_BLOCK = re.compile(
    r"\b(actor|struct|class|enum|protocol|extension)\s+([A-Z][\w.]*)"
    r"(?:\s*<[^<>]*>)?(?:\s*:[^{]*)?\s*\{")
CASE_LINE = re.compile(r"(?:^|\n)\s*case\s+([^\n:={]+)")
QUALIFIED = re.compile(r"(?<![\w.])([A-Z]\w*)\.([a-zA-Z_]\w*)")

MEMBER_OF_BODY = [
    re.compile(r"(?:^|\n)\s*" + MODIFIER + r"(?:let|var)\s+(\w+)"),
    re.compile(r"(?:^|\n)\s*" + MODIFIER + r"func\s+(\w+)"),
    re.compile(r"(?:^|\n)\s*" + MODIFIER
               + r"(?:struct|class|enum|actor|typealias|protocol)\s+([A-Z]\w*)"),
]

# Names every type effectively has, or that mean something other than a member.
UNIVERSAL = {"self", "init", "Type", "Protocol", "allCases", "rawValue", "RawValue",
             "CodingKeys", "some", "none"}


def pass_members():
    members, declared = {}, set()
    for path in FILES:
        text = strip_comments(path.read_text())
        for m in TYPE_BLOCK.finditer(text):
            name = m.group(2).split(".")[-1]
            body = brace_body(text, m.end() - 1)
            declared.add(name)
            found = set()
            for pattern in MEMBER_OF_BODY:
                found |= set(pattern.findall(body))
            if m.group(1) in ("enum", "extension"):
                for line in CASE_LINE.findall(body):
                    for part in line.split(","):
                        hit = re.match(r"^\s*(\w+)", part)
                        if hit:
                            found.add(hit.group(1))
            members.setdefault(name, set()).update(found)

    problems = []
    for path in FILES:
        text = strip_all(path.read_text())
        for m in QUALIFIED.finditer(text):
            tname, member = m.group(1), m.group(2)
            if tname not in declared or member in UNIVERSAL:
                continue
            if member in members.get(tname, set()):
                continue
            line = text.count("\n", 0, m.start()) + 1
            problems.append((path.relative_to(ROOT).as_posix(), line, tname, member))

    if not problems:
        print(f"members:  every TypeName.member reference resolves "
              f"({len(members)} types)")
        return True

    grouped = {}
    for path, line, tname, member in problems:
        grouped.setdefault(f"{tname}.{member}", []).append(f"{path}:{line}")
    print(f"members:  {len(grouped)} TypeName.member references naming nothing "
          f"on that type\n")
    for key in sorted(grouped, key=lambda k: -len(grouped[k])):
        sites = grouped[key]
        more = f" (+{len(sites) - 3} more)" if len(sites) > 3 else ""
        print(f"  {key:<44} {len(sites):>3}x  {', '.join(sites[:3])}{more}")
    return False




# ==========================================================================
# Pass 5 — a platform symbol is in scope only where its module is imported
# ==========================================================================
#
# Pass 1 resolves a name against KNOWN, which is one list for the whole tree. But
# imports are per-file, so "this is a real platform symbol" and "this symbol is in
# scope here" are different questions, and pass 1 only ever asked the first. That is
# how `SQLITE_CORRUPT` sailed through: CatalogStore.swift matched on it while importing
# no SQLite3, and pass 1 saw a name on the list and said yes. The macOS compiler said
# `cannot find 'SQLITE_CORRUPT' in scope`, which is the whole error this pass exists
# to have caught first.
#
# Scope is deliberately narrow. A prefix is only listed when it is a real namespace —
# every symbol carrying it comes from that one module and from nowhere else. CG* is
# absent for exactly this reason: CGFloat and CGRect arrive with Foundation, so
# requiring `import CoreGraphics` for them would be wrong. NS* likewise straddles
# Foundation and AppKit. When in doubt the prefix is left out and this pass says
# nothing about it, rather than saying something false.
MODULE_PREFIXES = {
    "SQLite3": ("SQLITE_", "sqlite3"),
    # `CGImageSource`/`kCGImageProperty` are ImageIO, not CoreGraphics, and are
    # unambiguous where bare `CG` is not — CGFloat and CGRect arrive with Foundation,
    # which is why the plain prefix is deliberately absent below.
    "ImageIO": ("CGImageSource", "kCGImageProperty", "kCGImageSource",
                "CGImageDestination", "kCGImageDestination"),
    "CoreImage": ("CI", "kCI"),
    "Metal": ("MTL",),
    # `VN` is unambiguous — nothing else in this tree or in the SDKs it uses starts
    # with it. CoreVideo gets the two long prefixes rather than a bare `CV`, which
    # would swallow ordinary words the same way a bare `CG` would.
    "Vision": ("VN",),
    "CoreVideo": ("CVPixelBuffer", "kCVPixelFormatType"),
    # No prefix convention at all — `SHA256` is the whole name — so the import check
    # matches the two symbols themselves.
    "CryptoKit": ("SHA256",),
}

# `import CoreImage.CIFilterBuiltins` imports CoreImage. Submodule paths count.
IMPORT = re.compile(r"(?:^|\n)\s*(?:@\w+\s+)?import\s+([\w.]+)")

def owning_module(name):
    for module, prefixes in MODULE_PREFIXES.items():
        for prefix in prefixes:
            if name.startswith(prefix) and len(name) > len(prefix):
                # "CI" must be followed by an upper-case letter or the rule catches
                # ordinary words like "Circle" and "Color".
                # "CI" must be followed by an upper-case letter. Without this the
                # rule swallows ordinary words (Circle, Color) and Swift's own
                # C-interop shims — CIntegerType is the only one that even reaches
                # here, and the lower-case "n" turns it away. An exception list was
                # written for those and then measured: every entry on it was already
                # rejected by this line or never matched the prefix at all, so it was
                # inert and is gone.
                if prefix in ("CI", "kCI") and not name[len(prefix)].isupper():
                    continue
                return module
    return None


def pass_module_imports():
    problems = []
    checked = collections.Counter()
    for path in FILES:
        raw = path.read_text()
        imported = set(IMPORT.findall(raw))
        # A submodule import brings its parent in.
        imported |= {name.split(".")[0] for name in imported}
        text = strip_all(raw)
        seen = {}
        for lineno, line in enumerate(text.split("\n"), 1):
            for name in SYMBOLISH.findall(line):
                module = owning_module(name)
                if module is None:
                    continue
                checked[module] += 1
                if module in imported:
                    continue
                seen.setdefault((module, name), lineno)
        for (module, name), lineno in seen.items():
            problems.append(
                (path.relative_to(ROOT).as_posix(), lineno, module, name))

    # Per-module counts, not one total. Metal is listed and currently matches nothing
    # in the tree, and a single clean number would let "imports: ok" be read as "Metal
    # is checked" when no Metal symbol exists to check.
    tally = ", ".join(f"{m} {checked[m]}" for m in sorted(MODULE_PREFIXES))
    if not problems:
        print(f"imports:  every platform symbol whose module is identifiable is used "
              f"in a file that imports it\n          uses seen: {tally}")
        return True

    print(f"imports:  {len(problems)} platform symbols used where their module is "
          f"not imported\n")
    for path, lineno, module, name in sorted(problems):
        print(f"  {name:<28} needs `import {module}`  {path}:{lineno}")
    return False


# ==========================================================================
# Pass 5b — an IN-TREE type used where its own module is not imported
# ==========================================================================
#
# Pass 1 resolves every capitalised identifier against the whole tree at once, with no
# idea which of the four targets each file belongs to. So `CaptureMetadataReader`, which
# lives in LumenPipeline, read as perfectly resolved from `Sources/LumenApp/Catalog
# Service.swift`, whose imports are Foundation and LumenCore. It is a hard compile error
# and it was invisible to seven passes.
#
# Only unambiguous names are checked: a type declared in exactly one module. Anything
# declared in two (a test double shadowing a real type, say) is skipped rather than
# guessed at, and so is anything a file declares locally.

MODULE_DEPENDENCIES = {
    # Which modules a target may import at all, from Package.swift. A use of something
    # from a module the target does not depend on is a different error with a different
    # fix, so it is reported as itself rather than as a missing import line.
    "LumenCore": set(),
    "LumenPipeline": {"LumenCore"},
    "LumenApp": {"LumenCore", "LumenPipeline"},
    "LumenCoreTests": {"LumenCore"},
    "LumenPipelineTests": {"LumenCore", "LumenPipeline"},
}


def _module_of(path):
    parts = path.relative_to(ROOT).parts
    return parts[1] if len(parts) > 2 and parts[0] in ("Sources", "Tests") else None


def pass_intree_imports():
    # type -> the set of modules declaring it, and per-file local declarations.
    declared_in = {}
    for path in FILES:
        module = _module_of(path)
        if module is None:
            continue
        text = strip_comments(path.read_text())
        spans = _enclosing_types(text)
        for m in TYPE_BLOCK.finditer(text):
            if m.group(1) == "extension":
                continue
            # TOP-LEVEL only. A nested type is `Outer.Inner`, so a bare `Inner` in
            # another module is never a reference to it — and indexing nested names
            # is what made SwiftUI's `@State` look like `XMPSidecar.State` and a
            # `<Content: View>` generic parameter look like a test's `Content`.
            if any(start < m.start() < end for start, end, _ in spans):
                continue
            declared_in.setdefault(m.group(2).split(".")[-1], set()).add(module)

    unique = {name: next(iter(mods)) for name, mods in declared_in.items()
              if len(mods) == 1}

    problems = []
    for path in FILES:
        module = _module_of(path)
        if module is None:
            continue
        raw = path.read_text()
        imported = set(IMPORT.findall(raw))
        # `@testable import X` is an import; so is a submodule's parent.
        imported |= {name.split(".")[0] for name in imported}
        text = strip_all(raw)
        # `<Content: View>` declares `Content` for this file; `@State` is an attribute.
        local = set()
        for m in re.finditer(r"<([^<>]{1,200})>", text):
            for part in m.group(1).split(","):
                hit = re.match(r"\s*([A-Z]\w*)\s*(?::|$)", part)
                if hit:
                    local.add(hit.group(1))
        seen = {}
        for lineno, line in enumerate(text.split("\n"), 1):
            for name in SYMBOLISH.findall(line):
                home = unique.get(name)
                if home is None or home == module or home in imported:
                    continue
                if name in local or f"@{name}" in line:
                    continue
                seen.setdefault((home, name), lineno)
        for (home, name), lineno in seen.items():
            reachable = home in MODULE_DEPENDENCIES.get(module, set())
            problems.append((path.relative_to(ROOT).as_posix(), lineno, home, name,
                             module, reachable))

    problems = sorted(set(problems))
    if not problems:
        print(f"targets:  every in-tree type is used in a file whose module imports "
              f"its own ({len(unique)} unambiguously placed)")
        return True

    print(f"targets:  {len(problems)} in-tree types used where their module is not "
          f"imported\n")
    for path, lineno, home, name, module, reachable in problems[:25]:
        if reachable:
            print(f"  {name:<28} needs `import {home}`  {path}:{lineno}")
        else:
            print(f"  {name:<28} is in {home}, which {module} does not depend on"
                  f"  {path}:{lineno}")
    return False




# ==========================================================================
# Pass 6 — member access on a value whose type is written down
# ==========================================================================
#
# Pass 4 checks `TypeName.member`. This checks `value.member`, for the one case where
# the value's type is knowable without inference: it was declared with an explicit
# annotation, in the same function.
#
# That gap is not theoretical. `photo.url` reached a compiler and cost a CI round —
# `PhotoItem.id` IS the URL and the type has no `url` member — from a parameter
# declared `on photo: PhotoItem` three lines above the use.
#
# Deliberately narrow, because the alternative is type inference:
#   - only parameters and `let`/`var` with an explicit `: TypeName`
#   - only types declared in-tree, so the member list is complete (extensions included)
#   - protocols are skipped: a value typed as one may be used at its concrete type
#   - a type that inherits or conforms to anything is skipped, because members can come
#     from a superclass or a protocol extension this script does not resolve
# The type is captured WITH its dots. A nested name like `ClippingOverlay.Mode` that
# the pattern could not see used to leave the value looking unambiguously typed as
# whatever it was annotated somewhere else in the file — which is how `mode` read as a
# `BeforeAfterMode` at a line where it was a `ClippingOverlay.Mode`. Dotted names are
# recorded so uniqueness fails, then skipped as unresolvable.
ANNOTATED = re.compile(
    r"(?:^|[(,\s])(?:let\s+|var\s+)?([a-z_]\w*)\s*:\s*([A-Z][\w.]*)\??\s*(?=[,)={\n])")
USE = re.compile(r"(?<![\w.])([a-z_]\w*)\??\.([a-zA-Z_]\w*)")

# A name bound anywhere by INFERENCE is not reliably the type it was annotated with
# somewhere else in the same file. Both false positives the first version produced were
# exactly this: `GeometryReader { geometry in }` is a GeometryProxy colliding with a
# `let geometry: Geometry` property, and `var c = m.adjust.curve ?? CurveSet()` is a
# CurveSet colliding with a `c: MaskComponent` parameter. Per-file scoping is what makes
# this pass simple; this is the price, and refusing the ambiguous names is cheaper than
# parsing scopes.
INFERRED = re.compile(r"(?:^|[^\w.])(?:let|var)\s+([a-z_]\w*)\s*=")
CLOSURE_ARG = re.compile(r"[{(]\s*((?:[a-z_]\w*\s*,\s*)*[a-z_]\w*)\s+in\b")

# The platform value types this pass knows the whole surface of.
#
# `_type_index` indexes IN-TREE types only, so a value annotated with a platform type
# was skipped entirely — and `CGRect.isFinite`, which does not exist, parsed cleanly on
# this Linux box, passed every pass here, and failed on the first Mac that compiled
# LumenPipeline. That target is not built or tested on the free lane at all, so this
# checker plus `swiftc -parse` are the ONLY guards it gets, and `-parse` does not
# type-check. This table is what makes the geometry structs a real check rather than a
# skipped one.
#
# Only these four, and deliberately: they are small, closed, and stable across OS
# releases, they are the platform types this codebase's geometry is actually written
# in, and every member below is verifiable from the CoreGraphics headers rather than
# remembered. A type whose surface this file cannot enumerate confidently does not
# belong here — a checker with false positives gets ignored, which is the argument the
# unbound-receiver pass already makes about itself.
#
# In-tree extensions still contribute: `_type_index` collects `extension CGRect` bodies
# under the same name, and the lookup below unions the two.
CG_COMMON = {
    # Equatable/Hashable/Codable/CustomStringConvertible, and the bridging surface
    # every CG struct carries.
    "hashValue", "hash", "encode", "description", "debugDescription",
    "dictionaryRepresentation", "applying", "init", "self",
}

PLATFORM_MEMBERS = {
    "CGPoint": CG_COMMON | {"x", "y", "zero"},
    "CGSize": CG_COMMON | {"width", "height", "zero"},
    "CGVector": CG_COMMON | {"dx", "dy", "zero"},
    "CGRect": CG_COMMON | {
        "origin", "size", "width", "height",
        "minX", "midX", "maxX", "minY", "midY", "maxY",
        "standardized", "integral", "isEmpty", "isNull", "isInfinite",
        "zero", "null", "infinite",
        "insetBy", "offsetBy", "union", "intersection", "intersects", "contains",
        "divided", "standardize", "makeIntegral", "formUnion", "formIntersection",
    },
}

# What a CONFORMANCE supplies, for the few protocols whose surface this file can
# enumerate confidently.
#
# `_type_index` records each type's declared conformances but has never known what any
# of them CONTRIBUTES, so a protocol extension's members read as absent. That was
# invisible while every in-tree type conformed only to protocols whose members it also
# declares itself (Codable, Equatable, Sendable). The first `OptionSet` in this codebase
# broke it: `SidecarStatedFields` gets `subtracting` from `SetAlgebra` and declares
# nothing, so the values pass reported a member that is unquestionably there.
#
# The same rule as PLATFORM_MEMBERS applies to what goes in here — a protocol whose
# surface this file cannot enumerate confidently does not belong, because a checker with
# false positives gets switched off. This is NOT a fix for K-014 ("the checker cannot see
# protocol conformance"): it is one table for one protocol family, and a conformance
# absent from it is treated exactly as before.
SET_ALGEBRA_MEMBERS = {
    "contains", "insert", "remove", "update",
    "union", "intersection", "symmetricDifference", "subtracting",
    "formUnion", "formIntersection", "formSymmetricDifference", "subtract",
    "isSubset", "isSuperset", "isStrictSubset", "isStrictSuperset", "isDisjoint",
    "isEmpty", "rawValue",
}

PROTOCOL_MEMBERS = {
    "OptionSet": SET_ALGEBRA_MEMBERS,
    "SetAlgebra": SET_ALGEBRA_MEMBERS,
}

# Members every value effectively has, or that are not member lookups at all.
VALUE_UNIVERSAL = {
    "self", "init", "map", "flatMap", "compactMap", "filter", "reduce", "forEach",
    "first", "last", "count", "isEmpty", "sorted", "reversed", "contains", "append",
    "description", "hashValue", "rawValue", "hash", "encode", "decode", "utf8",
    "isFinite", "isNaN", "rounded", "magnitude", "indices", "enumerated", "joined",
    "prefix", "suffix", "dropFirst", "dropLast", "min", "max", "keys", "values",
    "insert", "remove", "removeAll", "sort", "allSatisfy", "firstIndex", "lastIndex",
    "split", "trimmingCharacters", "lowercased", "uppercased", "replacingOccurrences",
    "hasPrefix", "hasSuffix", "components", "withUnsafeBytes", "withUnsafeMutableBytes",
}


def _type_index():
    """type -> members, plus what kind it is and whether it inherits/conforms."""
    members, kinds, conforms = {}, {}, {}
    for path in FILES:
        text = strip_comments(path.read_text())
        for m in TYPE_BLOCK.finditer(text):
            name = m.group(2).split(".")[-1]
            body = brace_body(text, m.end() - 1)
            kind = m.group(1)
            header = text[m.start():m.end()].split("{")[0]
            if kind != "extension":
                kinds[name] = kind
                # The `:` list is conformances and, for a class, possibly a superclass.
                # Skipping every type that has one threw out nearly all of Swift —
                # PhotoItem is `: Identifiable, Hashable, Sendable`, which is why the
                # first version of this pass missed the very bug it was written for.
                # Resolve the list instead: in-tree names contribute their members
                # below, and the standard protocols contribute names that live in
                # VALUE_UNIVERSAL. Only an UNKNOWN parent is a reason to give up.
                after = header.split(":", 1)[1] if ":" in header else ""
                parents = [p.strip().split("<")[0]
                           for p in after.split(",") if p.strip()]
                conforms[name] = [p for p in parents if p and p[0].isupper()]
            found = set()
            for pattern in MEMBER_OF_BODY:
                found |= set(pattern.findall(body))
            if kind in ("enum", "extension"):
                for line in CASE_LINE.findall(body):
                    for part in line.split(","):
                        hit = re.match(r"^\s*(\w+)", part)
                        if hit:
                            found.add(hit.group(1))
            members.setdefault(name, set()).update(found)

    # A conformer gets whatever an in-tree protocol's extensions gave it. Resolved to a
    # fixed point so a chain of in-tree protocols does not need ordering.
    for _ in range(4):
        for name, parents in conforms.items():
            for parent in parents:
                if parent in members:
                    members.setdefault(name, set()).update(members[parent])
    return members, kinds, conforms


FUNC_HEAD = re.compile(r"(?<![\w.])(?:func\s+\w+|init)\s*(?:<[^<>]*>)?\s*\(")


def _function_scopes(text):
    """(offset, text) for each function, signature included so parameters are in scope.

    Per FUNCTION, not per file. Per-file scoping looked simpler and was useless exactly
    where it mattered: in a thousand-line view model a common name like `photo` is bound
    by inference somewhere, so the rule that refuses ambiguous names refused all of
    them, and the pass reported a clean tree while being structurally unable to see the
    bug it was written for.
    """
    for m in FUNC_HEAD.finditer(text):
        depth, i, n = 0, m.end() - 1, len(text)
        while i < n:
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        brace = text.find("{", i)
        if brace == -1 or i >= n:
            continue
        # A `{` too far past the signature is a different construct (a computed
        # property, a trailing closure on a default value) rather than this body.
        if text.count("\n", i, brace) > 3:
            continue
        body = brace_body(text, brace)
        yield m.start(), text[m.start():brace] + body


def pass_value_members():
    members, kinds, conforms = _type_index()
    problems = []
    for path in FILES:
        text = strip_all(path.read_text())
        for offset, scope in _function_scopes(text):
            seen = {}
            for m in ANNOTATED.finditer(scope):
                seen.setdefault(m.group(1), set()).add(m.group(2))
            ambiguous = set(INFERRED.findall(scope))
            for m in CLOSURE_ARG.finditer(scope):
                for part in m.group(1).split(","):
                    ambiguous.add(part.strip())
            typed = {}
            for name, names in seen.items():
                if len(names) != 1 or name in ambiguous:
                    continue
                tname = next(iter(names))
                if "." in tname:
                    continue
                # A platform geometry type is checked against its own table rather
                # than against the in-tree index, which does not have it.
                if tname in PLATFORM_MEMBERS:
                    typed[name] = tname
                    continue
                if tname not in members or tname not in kinds:
                    continue
                if kinds[tname] == "protocol":
                    continue
                if any(p not in members and p not in KNOWN
                       for p in conforms.get(tname, [])):
                    continue
                typed[name] = tname
            if not typed:
                continue
            for m in USE.finditer(scope):
                name, member = m.group(1), m.group(2)
                tname = typed.get(name)
                if tname is None:
                    continue
                if tname in PLATFORM_MEMBERS:
                    # NOT exempted by VALUE_UNIVERSAL: that set exists because an
                    # in-tree member list is incomplete for anything a protocol
                    # extension supplies, and these tables are complete. Letting it
                    # through here is exactly what would have waved `CGRect.isFinite`
                    # past — `isFinite` is in VALUE_UNIVERSAL, for the Doubles that
                    # really do have it.
                    if member in PLATFORM_MEMBERS[tname]:
                        continue
                    if member in members.get(tname, set()):
                        continue  # an in-tree `extension CGRect` added it
                else:
                    if member in VALUE_UNIVERSAL:
                        continue
                    if member in members.get(tname, set()):
                        continue
                    # A member the type does not declare but a conformance supplies.
                    if any(member in PROTOCOL_MEMBERS.get(proto, ())
                           for proto in conforms.get(tname, [])):
                        continue
                line = text.count("\n", 0, offset + m.start()) + 1
                problems.append((path.relative_to(ROOT).as_posix(), line,
                                 name, tname, member))

    # One report per site: a name used twice in one scope is one mistake.
    problems = sorted(set(problems))
    if not problems:
        print(f"values:   every member read off an explicitly typed value exists "
              f"({len(members)} types indexed)")
        return True
    print(f"values:   {len(problems)} members read off a value whose type does not "
          f"have them\n")
    for path, line, name, tname, member in problems[:25]:
        print(f"  {name}.{member:<22} {name} is {tname}, which has no {member}"
              f"   {path}:{line}")
    return False


# Pass 7 — a receiver that is not bound to anything.
#
# `context.render(...)` inside a static method of a type whose statistics context is
# called `statisticsContext`. Three CI jobs failed on it, twice, and none of the six
# passes above could see it: they resolve capitalised identifiers, or members read off a
# value carrying an explicit type annotation, and a bare lowercase receiver is neither.
# The name existed on two OTHER types in the tree, which is exactly why a whole-tree
# member set would not have caught it either — the scope has to be the enclosing type.
#
# Deliberately permissive, because a checker with false positives gets ignored:
#   - anything bound ANYWHERE in the enclosing function counts, at any nesting depth
#   - members of the enclosing type, its extensions, and anything it conforms to
#   - every file-level binding in the tree, since a global is in scope everywhere
#   - functions not inside a type are skipped rather than guessed at
# What is left is a name with no binder in any of those places, which in Swift is a
# compile error and nothing else.
#
# What it does NOT cover, so nobody reads more into a green line than is there: only
# RECEIVERS. An undeclared name passed as a bare argument — `boxBlur(tensr, …)` — has no
# `.member` after it and this pass says nothing about it. Bodies of computed properties
# and standalone closures are not scanned either, because only `func` and `init` heads
# are located. It is a check on one specific mistake, which is the one that has now
# reached CI twice.

BINDERS = [
    # `let x`, `var x`, `guard let x`, `if var x`, `case let x`, `catch let x`
    re.compile(r"(?:^|[^\w.])(?:let|var)\s+([a-z_]\w*)"),
    # tuple destructuring: `let (a, b) = ...`
    re.compile(r"(?:^|[^\w.])(?:let|var)\s*\(\s*((?:[a-z_]\w*\s*,\s*)*[a-z_]\w*)\s*\)"),
    # `for x in`, `for (a, b) in`
    re.compile(r"\bfor\s+(?:case\s+)?\(?\s*((?:[a-z_]\w*\s*,\s*)*[a-z_]\w*)\s*\)?\s+in\b"),
    # closure parameters: `{ raw in`, `{ u, v in`, `{ (a, b) in`
    re.compile(r"[{(]\s*\(?\s*((?:[a-z_]\w*\s*,\s*)*[a-z_]\w*)\s*\)?\s+in\b"),
    # …and with a return type in the way: `{ raw -> Bool in`, `{ photo -> (…) in`,
    # where the type may run over several lines and the `in` is far away.
    re.compile(r"[{(]\s*\(?\s*((?:[a-z_]\w*\s*,\s*)*[a-z_]\w*)\s*\)?\s*->"),
    # function parameters, with or without an external label
    re.compile(r"[(,]\s*(?:[a-z_]\w*|_)\s+([a-z_]\w*)\s*:"),
    re.compile(r"[(,]\s*([a-z_]\w*)\s*:"),
    # associated values: `case .thing(let x)` is covered by the let rule; `x)` in a
    # pattern with `case let .thing(x, y)` is not, so take those too
    re.compile(r"\bcase\s+let\s+[.\w]*\(\s*((?:[a-z_]\w*\s*,\s*)*[a-z_]\w*)\s*\)"),
    # …and with a capture list in the way: `{ [weak self] event in`. Both closure
    # binders above want the `{` and the first name adjacent, so every escaping closure
    # in the application — which is to say every one that touches `self` — lost its
    # parameter.
    re.compile(r"\{\s*\[[^\]]*\]\s*\(?\s*((?:[a-z_]\w*\s*,\s*)*[a-z_]\w*)\s*\)?\s+in\b"),
]

# Not member lookups on a value: language keywords, and the property-wrapper and
# key-path forms whose leading punctuation the USE pattern cannot see.
RECEIVER_EXEMPT = {"self", "super", "true", "false", "nil", "try", "await", "some",
                   "any", "each", "repeat", "borrowing", "consuming"}


def _declaration_list_names(text):
    """Names bound by `let a = …, b = …` — every top-level comma segment, not just the
    first. `let cx = center[0], cy = center[1]` binds two things; taking one is how a
    perfectly ordinary line reads as a use of something undeclared."""
    names = set()
    for m in re.finditer(r"(?:^|[^\w.])(?:let|var)\s+", text):
        i, n = m.end(), len(text)
        depth, segment_start = 0, i
        while i < n:
            ch = text[i]
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                if depth == 0:
                    break
                depth -= 1
            elif ch == "\n" and depth == 0:
                break
            elif ch == "," and depth == 0:
                hit = re.match(r"\s*([a-z_]\w*)", text[segment_start:i])
                if hit:
                    names.add(hit.group(1))
                segment_start = i + 1
            i += 1
        hit = re.match(r"\s*([a-z_]\w*)", text[segment_start:i])
        if hit:
            names.add(hit.group(1))
    return names


def _bindings(scope):
    """Every name this scope binds, by any of the forms Swift offers."""
    names = _declaration_list_names(scope)
    for pattern in BINDERS:
        for hit in pattern.findall(scope):
            for part in hit.split(","):
                names.add(part.strip())
    return names


def _file_level_names():
    """Every top-level binding in the tree. A global is in scope in every file."""
    names = set()
    for path in FILES:
        text = strip_all(path.read_text())
        for piece in split_top(text):
            names |= _declaration_list_names(piece.split("{")[0])
    return names


def _enclosing_types(text):
    """(start, end, name) for each named type block, innermost last."""
    spans = []
    for m in TYPE_BLOCK.finditer(text):
        brace = text.find("{", m.end() - 1)
        if brace == -1:
            continue
        body = brace_body(text, brace)
        spans.append((brace, brace + len(body), m.group(2).split(".")[-1]))
    return spans


def pass_unbound_receivers():
    members, _kinds, conforms = _type_index()
    globals_ = _file_level_names()
    problems = []
    for path in FILES:
        text = strip_all(path.read_text())
        spans = _enclosing_types(text)
        functions = list(_function_scopes(text))
        records = [(off, off + len(sc), sc) for off, sc in functions]
        for offset, scope in functions:
            owners = [name for start, end, name in spans if start <= offset < end]
            if not owners:
                continue                      # a free function: no type to scope against
            available = set(globals_)
            for owner in owners:
                available |= members.get(owner, set())
                for parent in conforms.get(owner, []):
                    available |= members.get(parent, set())
            # Anything the function itself binds, at any depth — plus, for a nested
            # function, everything the functions it sits inside bind. A local `func`
            # captures the enclosing scope, so `space` declared as the outer
            # function's parameter is genuinely in scope in the inner one.
            for start, end, enclosing in records:
                if start <= offset < end:
                    available |= _bindings(enclosing)
            for m in USE.finditer(scope):
                name = m.group(1)
                if name in available or name in RECEIVER_EXEMPT:
                    continue
                # `$0.foo`, `$binding.foo`: the sigil is invisible to USE.
                if m.start() > 0 and scope[m.start() - 1] == "$":
                    continue
                line = text.count("\n", 0, offset + m.start()) + 1
                problems.append((path.relative_to(ROOT).as_posix(), line, name,
                                 m.group(2), owners[-1]))

    problems = sorted(set(problems))
    if not problems:
        print("scopes:   every lowercase receiver is bound by a parameter, a local, "
              "a member or a global")
        return True
    print(f"scopes:   {len(problems)} receivers are not bound in their scope\n")
    for path, line, name, member, owner in problems[:25]:
        print(f"  {name}.{member:<22} no {name} in scope inside {owner}"
              f"   {path}:{line}")
    return False



# ==========================================================================
# Pass 9 — a member reached across a module boundary must be public
# ==========================================================================
#
# Pass 4 asks whether `TypeName.member` NAMES something. It does not ask whether the
# caller is allowed to see it, and those are different questions the moment a reference
# crosses one of the four targets.
#
# `PipelineRenderer.maskSourceFingerprint` cost a CI round for exactly this. The
# function existed, pass 4 resolved it, `swiftc -parse` had no opinion — and it was
# `static func` with no access modifier, which is internal, so `AppState` in LumenApp
# could not reach into LumenPipeline for it. Nothing on this Linux box could say so,
# because the two macOS targets are never built here.
#
# Swift's rule, which this encodes:
#   - a declaration with no modifier is INTERNAL, visible only inside its own module
#   - `public` and `open` cross the boundary
#   - a type being public does NOT make its members public — `public struct S { let x }`
#     has an internal `x` — with two exceptions, both of which are here:
#       * members of a `public extension` are public unless marked otherwise
#       * an enum's CASES carry the enum's own access level
#
# Two directions of caution, both chosen to under-report rather than over-report:
#   - a member name declared more than once is accessible if ANY declaration is public,
#     because the crude member scan cannot tell a nested type's members from the outer
#     one's, and a wrong report is how a checker gets ignored
#   - `Tests/` is skipped entirely: `@testable import` grants internal access, so a test
#     file reaching for an internal member is correct code

ACCESS_LEVEL = re.compile(
    r"(?:^|\n)([ \t]*(?:@\w+(?:\([^)]*\))?[ \t]*)*"
    r"(?:public|open|internal|private|fileprivate|final|static|class|nonisolated"
    r"|mutating|nonmutating|lazy|weak|unowned|override|indirect|dynamic|convenience"
    r"|required|unsafe|package)?"
    r"(?:[ \t]+(?:public|open|internal|private|fileprivate|final|static|class"
    r"|nonisolated|mutating|nonmutating|lazy|weak|unowned|override|indirect|dynamic"
    r"|convenience|required|unsafe|package))*[ \t]+)"
    r"(?:let|var|func|struct|class|enum|actor|typealias|protocol|init|subscript)"
    r"(?:[ \t]+([A-Za-z_]\w*))?")

CROSSES = ("public", "open")


def _leading_modifiers(text, index):
    """The modifier words immediately before `index`, back to the line start."""
    line_start = text.rfind("\n", 0, index) + 1
    return set(re.findall(r"[a-z]+", text[line_start:index]))


def _module_surface():
    """(module, TypeName) -> {member: reachable}, and whether the type itself is."""
    surface, type_public = {}, {}
    for path in FILES:
        module = _module_of(path)
        if module is None or path.relative_to(ROOT).parts[0] == "Tests":
            continue
        text = strip_comments(path.read_text())
        for m in TYPE_BLOCK.finditer(text):
            name = m.group(2).split(".")[-1]
            kind = m.group(1)
            outer = _leading_modifiers(text, m.start())
            opens = bool(outer & set(CROSSES))
            key = (module, name)
            if kind != "extension":
                type_public[key] = type_public.get(key, False) or opens
            elif opens:
                type_public.setdefault(key, False)
            body = brace_body(text, m.end() - 1)
            found = surface.setdefault(key, {})
            # A `public extension` hands its access to every member that does not
            # override it; anywhere else a member starts internal.
            inherited = opens and kind == "extension"
            for hit in ACCESS_LEVEL.finditer(body):
                member = hit.group(2)
                if not member:
                    continue
                words = set(re.findall(r"[a-z]+", hit.group(1)))
                reachable = bool(words & set(CROSSES)) or (
                    inherited and not (words & {"private", "fileprivate", "internal"}))
                found[member] = found.get(member, False) or reachable
            # An enum's cases carry the enum's own access level, and `public` is not
            # spellable on a `case` line, so they are read off the container.
            if kind in ("enum", "extension"):
                cases = opens if kind == "extension" else (
                    type_public.get(key, False) or opens)
                for line in CASE_LINE.findall(body):
                    for part in line.split(","):
                        hit = re.match(r"^\s*(\w+)", part)
                        if hit:
                            found[hit.group(1)] = found.get(hit.group(1), False) or cases
    return surface, type_public


def pass_cross_module_access():
    surface, type_public = _module_surface()
    modules_of = {}
    for module, name in surface:
        modules_of.setdefault(name, set()).add(module)

    problems = []
    for path in FILES:
        module = _module_of(path)
        if module is None or path.relative_to(ROOT).parts[0] == "Tests":
            continue
        text = strip_all(path.read_text())
        for m in QUALIFIED.finditer(text):
            tname, member = m.group(1), m.group(2)
            homes = modules_of.get(tname)
            # Declared nowhere in tree, in this very module, or in two modules at once:
            # not this pass's question.
            if not homes or module in homes or len(homes) != 1 or member in UNIVERSAL:
                continue
            home = next(iter(homes))
            here = surface[(home, tname)]
            line = text.count("\n", 0, m.start()) + 1
            site = (path.relative_to(ROOT).as_posix(), line)
            if not type_public.get((home, tname), True):
                problems.append((*site, tname, "", home))
                continue
            # Absent means the crude scan did not see it — an inherited member, a
            # protocol requirement, a synthesized conformance. Pass 4 owns existence.
            if here.get(member, True):
                continue
            problems.append((*site, tname, member, home))

    problems = sorted(set(problems))
    if not problems:
        print(f"access:   every cross-module TypeName.member reference is public "
              f"({len(surface)} type/module pairs)")
        return True
    grouped = {}
    for path, line, tname, member, home in problems:
        key = f"{tname}.{member}" if member else tname
        grouped.setdefault((key, home), []).append(f"{path}:{line}")
    print(f"access:   {len(grouped)} references reach a non-public declaration "
          f"in another module\n")
    for (key, home) in sorted(grouped, key=lambda k: -len(grouped[k])):
        sites = grouped[(key, home)]
        more = f" (+{len(sites) - 3} more)" if len(sites) > 3 else ""
        print(f"  {key:<44} internal in {home}   {', '.join(sites[:3])}{more}")
    return False



# ==========================================================================
# Pass 10 — an argument's value must be a name that exists
# ==========================================================================
#
# The receiver pass asks whether `name` in `name.member` is bound. It never looks at a
# bare name passed AS an argument, and that is where the second of the two errors that
# went red on macOS lived: `swatchSlider` carried a copy of two trailing arguments from
# a neighbouring helper — `behaviour: behaviour, behaviourValue: (current - …)` — and
# neither name existed anywhere in its scope.
#
# WHY THE RECEIVER PASS'S OWN BINDING SET CANNOT BE REUSED. `BINDERS` reads a function
# parameter as `[(,] name :`, which is also exactly what a call-site LABEL looks like.
# Over a whole function body that binds every label the function passes to anything — so
# `behaviour: behaviour` binds `behaviour` from its own left-hand side, and the bug
# makes itself invisible. That over-broad rule is deliberate and correct for receivers,
# where a false positive is expensive and a miss is cheap. Here it is fatal, so this
# pass builds its own set: the label rule applies to the SIGNATURE only, and everything
# else — locals, `for`, `case let`, closure parameters — applies to the whole scope.
#
# Two more things this pass needs that the receiver pass does not:
#   - a nested `func`'s body is lexically inside its parent's scope, so its parameters
#     read as unbound there. Nested spans are subtracted; each nested function is
#     checked separately against its own signature.
#   - `kCGImagePropertyOrientation` and its family are genuine globals from a C header,
#     and the `k`-prefix convention is the only thing in the file that identifies them.
#
# Run against the whole tree it reports nothing, and against the commit that was red it
# reports the one line. That is the entire claim.

ARGUMENT_VALUE = re.compile(
    r"(?<![\w.$@\\#])[a-z_]\w*\s*:\s*\(?\s*([a-z_]\w*)\s*(?=[,)\-+*/<>=!&|?\s])")
LABEL_BINDER = re.compile(r"[(,]\s*([a-z_]\w*)\s*:")
EXTERNAL_LABEL_BINDER = re.compile(r"[(,]\s*(?:[a-z_]\w*|_)\s+([a-z_]\w*)\s*:")
PLATFORM_CONSTANT = re.compile(r"^k[A-Z]")

# Words that are grammar rather than values. `inout` is the one that matters most:
# `_ context: inout GraphicsContext` reads as a label followed by a value, sixty times.
GRAMMAR = set("""
if else guard return for in while switch case default break continue fallthrough
throw throws rethrows defer do catch as is where inout async await try lazy weak
unowned mutating nonmutating static final class public private internal fileprivate
open override required convenience indirect nonisolated dynamic package unsafe
consume copy discard let var func init deinit subscript
""".split())


def _value_bindings(scope):
    """Every name in scope, WITHOUT reading call-site labels as parameters."""
    names = _declaration_list_names(scope)
    for pattern in BINDERS:
        if pattern.pattern == LABEL_BINDER.pattern:
            continue
        for hit in pattern.findall(scope):
            for part in hit.split(","):
                names.add(part.strip())
    # `catch { … error … }` binds `error` with nothing written down.
    if re.search(r"\bcatch\b", scope):
        names.add("error")
    return names | _signature_parameters(scope)


def _signature_parameters(scope):
    """The label rule, applied only where a label really is a parameter."""
    m = FUNC_HEAD.search(scope)
    if not m:
        return set()
    depth, i, n = 0, m.end() - 1, len(scope)
    while i < n:
        if scope[i] == "(":
            depth += 1
        elif scope[i] == ")":
            depth -= 1
            if depth == 0:
                break
        i += 1
    signature = scope[m.start():i + 1]
    return set(LABEL_BINDER.findall(signature)) | set(
        EXTERNAL_LABEL_BINDER.findall(signature))


def pass_argument_values():
    members, _kinds, conforms = _type_index()
    globals_ = _file_level_names()
    problems = []
    for path in FILES:
        text = strip_all(path.read_text())
        spans = _enclosing_types(text)
        functions = list(_function_scopes(text))
        records = [(off, off + len(sc), sc) for off, sc in functions]
        for offset, scope in functions:
            owners = [name for start, end, name in spans if start <= offset < end]
            if not owners:
                continue
            available = set(globals_)
            for owner in owners:
                available |= members.get(owner, set())
                for parent in conforms.get(owner, []):
                    available |= members.get(parent, set())
            for start, end, enclosing in records:
                if start <= offset < end:
                    available |= _value_bindings(enclosing)
            nested = [(start - offset, end - offset) for start, end, _ in records
                      if start > offset and end <= offset + len(scope)]
            for m in ARGUMENT_VALUE.finditer(scope):
                name = m.group(1)
                if any(a <= m.start() < b for a, b in nested):
                    continue
                if (name in available or name in GRAMMAR
                        or name in RECEIVER_EXEMPT
                        or PLATFORM_CONSTANT.match(name)):
                    continue
                line = text.count("\n", 0, offset + m.start()) + 1
                problems.append((path.relative_to(ROOT).as_posix(), line, name,
                                 owners[-1]))

    problems = sorted(set(problems))
    if not problems:
        print("args:     every bare name passed as an argument is bound in its scope")
        return True
    plural = "argument names" if len(problems) == 1 else "arguments name"
    print(f"args:     {len(problems)} {plural} something that is not in scope\n")
    for path, line, name, owner in problems[:25]:
        print(f"  {name:<28} no {name} in scope inside {owner}   {path}:{line}")
    return False



# ==========================================================================
# Pass 11 — a switch over an in-tree enum must handle every case
# ==========================================================================
#
# The one thing this checker could not see that a compiler catches for free, and it cost
# real time: adding `MaskKind.luminosity` and `.polygon` meant finding five switches in
# `MaskPanel` by hand, with a throwaway script, because LumenApp is behind
# `#if os(macOS)` and nothing on this machine compiles it. Miss one and the macOS lane
# goes red on an error that was mechanical.
#
# HOW THE ENUM IS IDENTIFIED, since a text checker has no types. Every case in the switch
# is written as `.name`, the union of those names is collected, and the in-tree enums
# whose case list CONTAINS that union are looked up. Exactly one candidate means the
# switch is identified; zero or several means it is skipped. That is a heuristic, and it
# is the conservative half of one: it can decline to check a switch, and it can only
# report when one enum in the whole tree could be the subject.
#
# Two things had to be right about the index before this reported nothing false:
#
#   NESTED TYPES. `MaskKind` contains `enum MatteProvider { case none, vision, model }`,
#   and reading the outer enum's body whole gave `MaskKind` three cases it does not have
#   — which made every switch over it look non-exhaustive. Nested type bodies are blanked
#   before the case lines are read.
#
#   NAME COLLISIONS. `Mode` is declared in several types with different cases. Merging
#   them made each look larger than it is. Two declarations of one name that disagree
#   means the name cannot identify an enum, so it is refused rather than merged.
#
# Skipped by design: any switch with a `default` (it is exhaustive by construction), and
# any whose cases carry a `where` clause — `case .a where p:` does NOT exhaust `.a`, and
# Swift demands a default there, so nothing is lost by declining.

ENUM_BLOCK = re.compile(r"\benum\s+([A-Z]\w*)(?:\s*:[^{]*)?\s*\{")
NESTED_TYPE = re.compile(
    r"\b(?:enum|struct|class|actor|extension)\s+[A-Z]\w*(?:\s*:[^{]*)?\s*\{")
SWITCH_HEAD = re.compile(r"(?<![\w.])switch\s+[^\n{]{1,200}\{")
SWITCH_CASE = re.compile(r"(?:^|\n)\s*case\s+((?:\.\w+(?:\([^)]*\))?\s*,?\s*)+):")
HAS_DEFAULT = re.compile(r"(?:^|\n)\s*(?:@unknown\s+)?default\s*:")
CASE_WHERE = re.compile(r"case[^:\n]*\bwhere\b")


def _own_body(body):
    """`body` with every nested type block blanked, so an enum's cases are its own."""
    out = list(body)
    i = 1
    while True:
        m = NESTED_TYPE.search(body, i)
        if not m:
            break
        brace = body.find("{", m.end() - 1)
        if brace == -1:
            break
        inner = brace_body(body, brace)
        for j in range(m.start(), min(brace + len(inner), len(out))):
            if out[j] != "\n":
                out[j] = " "
        i = brace + len(inner)
    return "".join(out)


def _enum_index():
    """enum name -> its own cases, for names that identify exactly one enum."""
    cases_of, seen = {}, {}
    for path in FILES:
        text = strip_all_keep_quotes(path.read_text())
        for m in ENUM_BLOCK.finditer(text):
            brace = text.find("{", m.end() - 1)
            if brace == -1:
                continue
            body = _own_body(brace_body(text, brace))
            found = set()
            for line in CASE_LINE.findall(body):
                for part in line.split(","):
                    hit = re.match(r"^\s*(\w+)", part)
                    if hit:
                        found.add(hit.group(1))
            if not found:
                continue
            name = m.group(1)
            if seen.get(name, found) is None:
                continue
            if name in seen and seen[name] != found:
                cases_of.pop(name, None)
                seen[name] = None
                continue
            seen[name] = found
            cases_of[name] = found
    return cases_of


def pass_switch_exhaustive():
    cases_of = _enum_index()
    problems, checked = [], 0
    for path in FILES:
        text = strip_all_keep_quotes(path.read_text())
        for m in SWITCH_HEAD.finditer(text):
            brace = text.rfind("{", 0, m.end())
            inner = brace_body(text, brace)[1:-1]
            if HAS_DEFAULT.search(inner) or CASE_WHERE.search(inner):
                continue
            used, parsed = set(), True
            for cm in SWITCH_CASE.finditer(inner):
                for part in cm.group(1).split(","):
                    hit = re.match(r"\s*\.(\w+)", part)
                    if hit:
                        used.add(hit.group(1))
                    elif part.strip():
                        parsed = False
            # One case identifies far too many enums to be worth a guess.
            if not parsed or len(used) < 2:
                continue
            candidates = [n for n, all_cases in cases_of.items() if used <= all_cases]
            if len(candidates) != 1:
                continue
            name = candidates[0]
            checked += 1
            missing = cases_of[name] - used
            if missing:
                line = text.count("\n", 0, m.start()) + 1
                problems.append((path.relative_to(ROOT).as_posix(), line, name,
                                 tuple(sorted(missing))))

    problems = sorted(set(problems))
    if not problems:
        print(f"switches: {checked} switches over {len(cases_of)} in-tree enums handle "
              f"every case")
        return True
    plural = "switch misses" if len(problems) == 1 else "switches miss"
    print(f"switches: {len(problems)} {plural} a case of the enum "
          f"they are over\n")
    for rel, line, name, missing in problems[:25]:
        print(f"  {rel}:{line}  switch over {name}: missing {', '.join(missing)}")
    return False


# ── Pass 13: Core Image kernel sources ─────────────────────────────────────────
#
# The one thing in this tree the compiler does not compile: every GPU kernel is a Swift
# string literal in Core Image Kernel Language, handed to `CIKernel(source:)` at
# runtime. A kernel that does not parse is not a build error — it is a `nil` in
# `KernelLibrary`, an honest CPU fallback, and a lane that stays green. Two of the four
# parametric-mask kernels shipped that way for their whole life: `float long = …` and
# `float out;` — both GLSL reserved words used as identifiers, both parse errors, both
# invisible to `swiftc`, to this checker's other twelve passes, and to a sentinel test
# whose roster did not include them.
#
# This pass is the mechanical half of the fix. It finds every triple-quoted literal that
# declares a `kernel`, and flags any declared identifier — a parameter or a local — that
# is a keyword of the language. It does not parse CIKL; it only knows the keyword list,
# which is what a person checking by eye did not.
KERNEL_RESERVED = set("""
attribute const uniform varying buffer shared coherent volatile restrict readonly writeonly
atomic_uint layout centroid flat smooth noperspective patch sample break continue do for
while switch case default if else subroutine in out inout float double int void bool true
false invariant precise discard return lowp mediump highp precision struct common
partition active asm class union enum typedef template this resource goto inline noinline
public static extern external interface long short half fixed unsigned superp input output
hvec2 hvec3 hvec4 fvec2 fvec3 fvec4 filter sizeof cast namespace using
mat2 mat3 mat4 vec2 vec3 vec4 ivec2 ivec3 ivec4 bvec2 bvec3 bvec4 uint uvec2 uvec3 uvec4
sampler1D sampler2D sampler3D samplerCube sampler2DRect
kernel __sample __color __table
""".split())
KERNEL_LITERAL = re.compile(r'"""\n(.*?)\n[ \t]*"""', re.S)
KERNEL_DECL = re.compile(
    r"\b(?:float|int|bool|uint|vec[234]|ivec[234]|bvec[234]|mat[234]|__sample|__color|sampler)"
    r"\s+([A-Za-z_]\w*)")


def pass_kernel_reserved():
    problems, kernels = [], 0
    for path in FILES:
        text = path.read_text()
        for lit in KERNEL_LITERAL.finditer(text):
            body = lit.group(1)
            if not re.search(r"\bkernel\s+\w+\s+\w+\s*\(", body):
                continue
            kernels += 1
            base = text.count("\n", 0, lit.start(1)) + 1
            for m in KERNEL_DECL.finditer(body):
                ident = m.group(1)
                if ident in KERNEL_RESERVED:
                    line = base + body.count("\n", 0, m.start())
                    problems.append((path.relative_to(ROOT).as_posix(), line, ident,
                                     body.splitlines()[line - base].strip()))
    problems = sorted(set(problems))
    if not problems:
        print(f"kernels:  {kernels} kernel sources declare no reserved-word identifier")
        return True
    plural = "kernel declares" if len(problems) == 1 else "kernels declare"
    print(f"kernels:  {len(problems)} {plural} a reserved word of the kernel language "
          f"as an identifier — a parse error at runtime, a nil in KernelLibrary, and a "
          f"CPU fallback nothing reports\n")
    for rel, line, ident, src in problems[:25]:
        print(f"  {rel}:{line}  `{ident}` is reserved: {src}")
    return False


if __name__ == "__main__":
    ok = pass_symbols()
    print()
    ok = pass_inits() and ok
    print()
    ok = pass_actor_await() and ok
    ok = pass_method_labels() and ok
    print()
    ok = pass_members() and ok
    print()
    ok = pass_module_imports() and ok
    print()
    ok = pass_intree_imports() and ok
    print()
    ok = pass_value_members() and ok
    print()
    ok = pass_unbound_receivers() and ok
    print()
    ok = pass_cross_module_access() and ok
    print()
    ok = pass_argument_values() and ok
    print()
    ok = pass_switch_exhaustive() and ok
    print()
    ok = pass_kernel_reserved() and ok
    sys.exit(0 if ok else 1)
