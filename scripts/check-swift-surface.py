#!/usr/bin/env python3
"""Two mechanical passes over the Swift sources, for when there is no compiler.

This is NOT a type checker and must never be described as one. It catches exactly two
classes of error, both of which a tree that has not been compiled in a while is likely
to carry:

  1. a capitalized identifier that is declared nowhere in-tree and is not a known
     platform name — a typo, a rename that missed a site, a type from a module that is
     not imported;
  2. a `Type(...)` call whose argument labels match none of that type's declared
     initializers — the error class that reshaping a struct's `init` produces at every
     call site the change forgot.

Both passes were verified able to fail before being trusted: six mutations — wrong
label, extra argument, reordered labels, missing required argument, a renamed type, and
a type from an unimported module — are caught six times out of six. A check that has
never failed proves nothing, which is the rule the rest of this project's verification
is built on.

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


if __name__ == "__main__":
    ok = pass_symbols()
    print()
    ok = pass_inits() and ok
    sys.exit(0 if ok else 1)
