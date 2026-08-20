#!/usr/bin/env python3
"""Four mechanical passes over the Swift sources, for when there is no compiler.

This is NOT a type checker and must never be described as one. It catches four classes
of error, all of which a tree that has not been compiled in a while is likely to carry:

  1. a capitalized identifier that is declared nowhere in-tree and is not a known
     platform name — a typo, a rename that missed a site, a type from a module that is
     not imported;
  2. a `Type(...)` call whose argument labels match none of that type's declared
     initializers — the error class that reshaping a struct's `init` produces at every
     call site the change forgot;
  3. a call to an actor-isolated member with no `await` — written because exactly that
     was found by hand in this codebase, in code that passes 1 and 2 both accept;
  4. a `TypeName.member` reference naming nothing that type has — a rename that updated
     the declaration and missed the references.

Every pass was verified able to fail before being trusted: nine mutations — wrong
label, extra argument, reordered labels, missing required argument, a renamed type, a
type from an unimported module, a stripped `await`, and two renamed statics — are
caught nine times out of nine, and the unmutated tree stays silent. A check that has
never failed proves nothing, which is the rule the rest of this project's verification
is built on.

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


def strip_all(text):
    """Comments AND string bodies out, so prose cannot invent symbols."""
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
    # stdlib
    "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32",
    "UInt64", "Double", "Float", "Float32", "Float64", "Bool", "String", "Substring",
    "Character", "Array", "Dictionary", "Set", "Optional", "Result", "Range",
    "ClosedRange", "Sequence", "Collection", "Comparable", "Equatable", "Hashable",
    "Hasher", "Codable", "Encodable", "Decodable", "Sendable", "Error", "Any",
    "AnyObject", "AnyHashable", "Void", "Never", "Self", "Swift", "Identifiable",
    "CustomStringConvertible", "RawRepresentable", "CaseIterable", "Numeric",
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
    "FileManager", "FileWrapper", "Bundle", "JSONEncoder", "JSONDecoder",
    "JSONSerialization", "PropertyListEncoder", "PropertyListDecoder",
    "PropertyListSerialization", "NSError", "NSString", "NSNumber", "NSObject",
    "NSLock", "NSRecursiveLock", "NSRegularExpression", "NSLog", "NSAttributedString",
    "NSItemProvider", "NSSize", "Notification", "NotificationCenter", "Locale",
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
    "XCTUnwrap", "XCTFail", "XCTAssertEqual", "XCTAssertNotEqual", "XCTAssertTrue",
    "XCTAssertFalse", "XCTAssertNil", "XCTAssertNotNil", "XCTAssertGreaterThan",
    "XCTAssertLessThan", "XCTAssertGreaterThanOrEqual", "XCTAssertLessThanOrEqual",
    # CoreGraphics / ImageIO / CoreImage / CoreText
    "CoreGraphics", "CGFloat", "CGPoint", "CGSize", "CGRect", "CGVector",
    "CGAffineTransform", "CGImage", "CGColor", "CGColorSpace", "CGContext",
    "CGDataProvider", "CGPath", "CGMutablePath", "CGBitmapInfo", "CGImageAlphaInfo",
    "CGColorRenderingIntent", "CGImageSource", "CGImageDestination",
    "CGImagePropertyOrientation", "CGDirectDisplayID",
    "CGImageSourceCreateWithURL", "CGImageSourceCreateThumbnailAtIndex",
    "ImageIO", "CFString", "CFDictionary", "CFData", "CFURL",
    "CoreImage", "CIImage", "CIContext", "CIFilter", "CIFilterBuiltins", "CIColor",
    "CIVector", "CIRAWFilter", "CIKernel", "CIColorKernel", "CIWarpKernel",
    "CIBlendKernel", "CISampler", "CIFormat", "CIRenderDestination", "CIColorCube",
    "CIImageRepresentationOption", "CIContextOption",
    "RGBAf", "RGBAh", "RGBA8", "RGBA16",
    "CoreText", "CTFontCreateWithName",
    "CVPixelBuffer", "IOSurface", "OSStatus",
    # Vision + CoreVideo: the subject / person mattes (docs/08 §8.8). Listed
    # individually rather than by prefix, so a typo in a request's name is still a
    # failure here; the prefixes below are what make the IMPORT check work.
    "Vision", "VNImageRequestHandler", "VNGenerateForegroundInstanceMaskRequest",
    "VNGeneratePersonSegmentationRequest", "VNInstanceMaskObservation",
    "VNPixelBufferObservation", "VNObservation", "VNRequest",
    "CoreVideo", "CVPixelBufferGetWidth", "CVPixelBufferGetHeight",
    "CVPixelBufferGetPixelFormatType", "CVPixelBufferGetBytesPerRow",
    "CVPixelBufferGetBaseAddress", "CVPixelBufferLockBaseAddress",
    "CVPixelBufferUnlockBaseAddress", "CVPixelBufferLockFlags",
    # Metal
    "MTLDevice", "MTLTexture", "MTLCommandQueue", "MTLPixelFormat",
    "MTLCreateSystemDefaultDevice",
    # AppKit
    "AppKit", "NSApp", "NSApplication", "NSApplicationDelegate", "NSImage", "NSColor",
    "NSView", "NSViewRepresentable", "NSViewController", "NSWindow", "NSEvent",
    "NSCursor", "NSMenu", "NSMenuItem", "NSPasteboard", "NSSavePanel", "NSOpenPanel",
    "NSWorkspace", "NSBezierPath", "NSGraphicsContext", "NSScreen", "NSFont",
    "NSSound", "NSAlert", "NSStatusBar", "NSTextField", "NSTextView", "NSHostingView",
    "NSHostingController", "ModifierFlags", "OK",
    "NSLeftArrowFunctionKey", "NSRightArrowFunctionKey", "NSUpArrowFunctionKey",
    "NSDownArrowFunctionKey", "NSDeleteFunctionKey",
    # SwiftUI
    "SwiftUI", "View", "Text", "Image", "Color", "VStack", "HStack", "ZStack",
    "Spacer", "Button", "Slider", "Toggle", "Picker", "TextField", "SecureField",
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
    "Alignment", "HorizontalAlignment", "VerticalAlignment", "Edge", "EdgeInsets",
    "Angle", "UnitPoint", "Font", "LinearGradient", "RadialGradient",
    "AngularGradient", "Gradient", "DragGesture", "TapGesture", "Gesture",
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
    """Split on commas not nested in brackets or strings.

    `<`/`>` are NOT treated as brackets: `->` appears in every closure-typed parameter
    and counting its `>` as a close ran the depth negative, which swallowed the
    parameter after it. That produced four confident false reports the first time this
    was run, which is the whole reason the note is here.
    """
    parts, depth, cur, i, n = [], 0, [], 0, len(text)
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
        elif ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    if "".join(cur).strip():
        parts.append("".join(cur))
    return parts


def collect_inits():
    """type name -> [(parameter labels, required labels)]."""
    inits = {}
    for path in FILES:
        text = strip_comments(path.read_text())
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
            m = TYPE_DECL.match(text, i) or EXT_DECL.match(text, i)
            if m:
                if text.find("{", m.end()) != -1:
                    scopes.append((m.group(1).split(".")[-1], depth + 1))
                i = m.end()
                continue
            m = INIT_DECL.match(text, i)
            if m and scopes:
                open_i = m.end() - 1
                close = match_paren(text, open_i)
                if close:
                    labels, required, ok = [], [], True
                    for param in split_top(text[open_i + 1:close - 1]):
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
    return inits


def pass_inits():
    inits = collect_inits()
    problems, checked, skipped = [], 0, 0

    for path in FILES:
        text = strip_comments(path.read_text())
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

    if not problems:
        print(f"inits:    {checked} call sites match a declared initializer "
              f"({skipped} unparseable, skipped)")
        return True

    print(f"inits:    {len(problems)} of {checked} call sites match NO declared "
          f"initializer ({skipped} unparseable, skipped)\n")
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
                if "." in tname or tname not in members or tname not in kinds:
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
                if tname is None or member in VALUE_UNIVERSAL:
                    continue
                if member in members.get(tname, set()):
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


if __name__ == "__main__":
    ok = pass_symbols()
    print()
    ok = pass_inits() and ok
    print()
    ok = pass_actor_await() and ok
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
    sys.exit(0 if ok else 1)
