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

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
if not (ROOT / "Package.swift").exists():
    sys.exit("expected to sit in <package>/scripts/")

FILES = sorted(ROOT.glob("Sources/**/*.swift")) + sorted(ROOT.glob("Tests/**/*.swift"))

LINE_COMMENT = re.compile(r"//[^\n]*")
BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
MULTILINE_STR = re.compile(r'"""(?:.|\n)*?"""', re.S)
STRING = re.compile(r'"(?:\\.|[^"\\\n])*"')


def strip_comments(text):
    """Comments and multi-line strings out; ordinary strings kept as delimiters."""
    text = BLOCK_COMMENT.sub(" ", text)
    text = MULTILINE_STR.sub('""', text)
    return LINE_COMMENT.sub(" ", text)


def strip_all(text):
    """Also blanks ordinary string bodies, so prose cannot invent symbols."""
    return STRING.sub('""', strip_comments(text))


# ==========================================================================
# Pass 1 — every capitalized identifier resolves
# ==========================================================================

DECL = re.compile(r"\b(?:struct|class|enum|protocol|actor|typealias)\s+([A-Z]\w*)")
EXTENSION = re.compile(r"\bextension\s+([A-Z]\w*)")
# Not preceded by a dot: `Foo.Bar` and `T.Type` resolve through their base, which
# is checked on its own, and `.RGBAf` is an enum case rather than a type.
CAPITALIZED = re.compile(r"(?<![\w.])([A-Z]\w*)\b")
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


if __name__ == "__main__":
    ok = pass_symbols()
    print()
    ok = pass_inits() and ok
    print()
    ok = pass_actor_await() and ok
    print()
    ok = pass_members() and ok
    sys.exit(0 if ok else 1)
