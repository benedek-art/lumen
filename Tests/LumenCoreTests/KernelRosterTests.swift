// KernelRosterTests.swift
// I2-01 / F2-02: every kernel this codebase compiles must be in an availability roster.
//
// THE ROSTERS HAVE BEEN THE BUG THREE TIMES NOW.
//
// N-001: four mask kernels were "absent from every roster, so two of them failed to
// compile on every build without a single test noticing, and the fast path this file
// exists to provide never ran" — that sentence is in `Kernels.swift`, written when it
// was fixed. `blendMaskMode` was absent from every roster at the time it was written and
// stayed absent, which is the point: the fix enumerated the four kernels the author was
// looking at, and enumeration by hand is exactly the thing that goes stale.
//
// `testEveryKernelCompiles` asserts both rosters are EMPTY. It cannot see a kernel that
// is in neither, because a name that is on no list can never appear on a list of
// failures — so the test passes most loudly for precisely the kernel it is blind to.
//
// The check has to be mechanical, and this is it: diff the declarations against the
// rosters. Two independent auditors found `blendMaskMode` this way within an hour of
// each other, which is what a mechanical check is for.
//
// It reads `Kernels.swift` as text because `LumenPipeline` is `#if os(macOS)` and does
// not build on the Linux lane at all — the same reason `check-swift-surface.py` exists.

import XCTest
@testable import LumenCore

final class KernelRosterTests: XCTestCase {

    /// Kernels deliberately outside both rosters, each with the reason. Empty, and it
    /// should stay that way — the entry exists so that an exemption has to be argued for
    /// in the same commit that makes it, rather than being invisible.
    private static let exempt: Set<String> = []

    func testEveryDeclaredKernelIsInAnAvailabilityRoster() throws {
        let source = try Self.kernelSource()

        // There are TWO factories, `make` and `makeGeneral`, and this test's first
        // draft matched only the first — so it checked 32 of 38 kernels while claiming
        // to check all of them, which is the very failure it exists to prevent. It was
        // caught by the companion test below, and that is the argument for having both:
        // one asks "is every kernel rostered", the other asks "is every rostered name a
        // kernel", and a pattern that silently narrows fails the second one loudly.
        let declared = Self.declaredKernels(in: source)
        XCTAssertGreaterThan(declared.count, 30,
                             "the declaration pattern stopped matching; this test would "
                             + "otherwise pass by checking nothing")

        let rostered = Self.rosterNames(in: source)
        let missing = declared.subtracting(rostered).subtracting(Self.exempt)

        XCTAssertEqual(missing, [],
                       "these kernels are in no availability roster, so `isAvailable` "
                       + "stays true when they fail to compile and the failure is "
                       + "discovered by the picture being wrong: \(missing.sorted())")
    }

    /// And the rosters must not name a kernel that no longer exists — the other way a
    /// hand-maintained list rots, and the one that makes a roster look complete.
    func testNoRosterNamesAKernelThatIsGone() throws {
        let source = try Self.kernelSource()
        let declared = Self.declaredKernels(in: source)
        let rostered = Self.rosterNames(in: source)
        XCTAssertEqual(rostered.subtracting(declared), [],
                       "a roster names a kernel that is not declared any more")
    }

    // MARK: - helpers

    /// The names quoted inside the two `[(String, CIKernel?)]` roster literals. Quoted
    /// names only: the roster's shape is `("name", kernel)`, and reading the STRING is
    /// what makes this a check on the list a human maintains rather than on the symbol.
    private static func rosterNames(in source: String) -> Set<String> {
        var names: Set<String> = []
        for roster in ["unavailableKernels", "unavailableMaskKernels"] {
            guard let start = source.range(of: "public static var \(roster): [String] {")
            else { continue }
            let rest = source[start.upperBound...]
            let end = rest.range(of: "return all.filter")?.lowerBound ?? rest.endIndex
            names.formUnion(quotedNames(in: String(rest[..<end])))
        }
        return names
    }

    /// Every `("name",` in a roster literal.
    private static func quotedNames(in body: String) -> Set<String> {
        var names: Set<String> = []
        var rest = Substring(body)
        while let open = rest.range(of: "(\"") {
            let after = rest[open.upperBound...]
            guard let close = after.firstIndex(of: "\"") else { break }
            let name = String(after[..<close])
            // `("name", kernel)` and nothing else: a bare string elsewhere in the body
            // is not a roster entry.
            if after[close...].dropFirst().first == "," { names.insert(name) }
            rest = after[close...]
        }
        return names
    }

    /// Every `static let NAME = make…(` in the file.
    ///
    /// There are TWO factories, `make` and `makeGeneral`, and matching only the first is
    /// how this test's own first draft came to check 32 of 38 kernels while claiming to
    /// check all of them. Hand-rolled rather than a regular expression on purpose: the
    /// pattern is three tokens, and the alternative reaches for a platform API whose
    /// signature the surface checker cannot model.
    private static func declaredKernels(in source: String) -> Set<String> {
        var names: Set<String> = []
        for line in source.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("static let ") || trimmed.hasPrefix("public static let ")
            else { continue }
            guard let equals = trimmed.range(of: " = ") else { continue }
            let call = trimmed[equals.upperBound...]
            guard call.hasPrefix("make(") || call.hasPrefix("makeGeneral(") else { continue }
            let head = trimmed[..<equals.lowerBound]
            guard let name = head.split(separator: " ").last else { continue }
            names.insert(String(name))
        }
        return names
    }

    private static func kernelSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenPipeline")
        return try String(contentsOf: root.appendingPathComponent("Kernels.swift"),
                          encoding: .utf8)
    }
}
