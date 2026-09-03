// UnwiredEngineTests.swift
// An engine with no caller is not a feature, and nothing in this package could tell the
// difference.
//
// `LumenCore.FocusPeaking` sat in `Scopes.swift` finished — a documented local-contrast
// edge detector with three named sensitivities — and was reached by NOTHING. Not a view,
// not a test, not another engine. The audit's viewer sheet lists it among eight declared
// and unreachable scope symbols; its gap table carries it as the viewer's top gap with
// the note "engine exists"; and the keymap reconciliation had already given away the `F`
// the docs reserved for it, on the grounds that "focus peaking is unbuilt".
//
// It was not unbuilt. It was unreachable, which looks identical from every direction
// except this one.
//
// So this file asks two questions that no other test in the package asks, and it asks
// them of the APP layer rather than of the engine:
//
//   1. IS THE ENGINE CALLED. A text scan over `Sources/LumenApp`, comments AND string
//      bodies blanked, for `FocusPeaking.compute(`. Blanking both is the point: this
//      file's own subject is a symbol that was named in prose all over the tree while
//      being called nowhere, so a scan that counted a doc comment — or a `.help(…)`
//      string — would pass the exact state it exists to catch. The cost of blanking
//      strings is that a call written only inside an interpolation is invisible here,
//      which is the safe direction of error for a test whose job is to prove a real
//      caller exists.
//
//   2. DOES CALLING IT DO ANYTHING. Five fixtures through the app layer's own entry
//      point, `FocusPeakingOverlayView.confidence`, because a symbol with a caller and a
//      constant return value is the failure this whole exercise is supposed to be
//      distinguishing from a fix. A flat field marks nothing; a one-pixel step marks the
//      step and only the step; the SAME contrast spread over sixteen pixels — a
//      defocused edge — marks nothing; identical texture at 0.60 and at 0.03 luminance
//      is found equally well in both, which is the local-mean divide's entire claim; and
//      the three sensitivities admit strictly more of the same frame in the documented
//      order.
#if os(macOS)

import CoreGraphics
import XCTest
import LumenCore
@testable import LumenApp

final class UnwiredEngineTests: XCTestCase {

    // MARK: - Reading the app layer as text

    /// The repository, from this file's own path — the route `KeyGrammarAttachmentTests`
    /// takes, for the same reason: `Bundle.module` carries resources, and the sources are
    /// the subject.
    private static var appSourceDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("LumenApp", isDirectory: true)
    }

    /// Every Swift file in the app target as (name, code), where "code" is the file with
    /// `//`, `/* */` AND string bodies blanked. Length and newlines are preserved so a
    /// line number can still be counted off the result.
    ///
    /// The string blanking is what separates this scan from the ones in
    /// `DesignSystemTests` and `KeyGrammarAttachmentTests`, which keep string bodies
    /// because a `.keyboardShortcut("k", …)` IS its literal. Here a literal is the enemy:
    /// the symbol under test is one this tree has been describing in prose for months.
    private static let appSources: [(name: String, code: String)] = {
        let directory = appSourceDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".swift") }.sorted().compactMap { name in
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name),
                                         encoding: .utf8) else { return nil }
            return (name, code(of: text))
        }
    }()

    /// The same single-pass walk the other two scanners use — comments and strings nest
    /// into each other, so a regex for either alone is wrong in the presence of the
    /// other — with the one difference that a string's body is blanked rather than
    /// stepped over.
    private static func code(of text: String) -> String {
        var out = Array(text)
        var i = 0
        let n = out.count
        func blank(_ from: Int, _ to: Int) {
            for k in from..<to where out[k] != "\n" { out[k] = " " }
        }
        while i < n {
            let c = out[i]
            let next: Character? = i + 1 < n ? out[i + 1] : nil
            if c == "/" && next == "/" {
                var j = i
                while j < n && out[j] != "\n" { j += 1 }
                blank(i, j)
                i = j
            } else if c == "/" && next == "*" {
                var j = i + 2
                while j + 1 < n && !(out[j] == "*" && out[j + 1] == "/") { j += 1 }
                let end = Swift.min(j + 2, n)
                blank(i, end)
                i = end
            } else if c == "\"" {
                var j = i + 1
                while j < n {
                    if out[j] == "\\" { j += 2; continue }
                    if out[j] == "\"" { j += 1; break }
                    if out[j] == "\n" { break }
                    j += 1
                }
                let end = Swift.min(j, n)
                blank(i, end)
                i = end
            } else {
                i += 1
            }
        }
        return String(out)
    }

    private func sitesOf(_ needle: String) -> [String] {
        Self.appSources.compactMap { source in
            source.code.contains(needle) ? source.name : nil
        }
    }

    // MARK: - 1. The engine has a caller

    /// The whole finding, as one assertion. Before this landing the count was zero and
    /// had been since `FocusPeaking` was written.
    func testTheFocusPeakingEngineIsCalledFromTheAppLayer() {
        XCTAssertGreaterThan(Self.appSources.count, 20,
                             "only \(Self.appSources.count) app sources read — the scan "
                                 + "has stopped finding Sources/LumenApp")
        let callers = sitesOf("FocusPeaking.compute(")
        XCTAssertFalse(callers.isEmpty,
                       "LumenCore.FocusPeaking has no caller in Sources/LumenApp again — "
                           + "the engine is finished, tested here, and reachable from no "
                           + "part of the interface, which is the state the audit filed "
                           + "it in and the reason the keymap gave its key away")
    }

    /// Named separately from the call, because the two fail for different reasons: the
    /// engine can be called by a helper that nothing draws. This is the view that draws
    /// it, and it must live where the viewer's other overlays live.
    func testThePeakingOverlayLivesWithTheViewersOtherOverlays() {
        XCTAssertTrue(sitesOf("struct FocusPeakingOverlayView").contains("ViewerOverlays.swift"),
                      "the peaking overlay is not in ViewerOverlays.swift — if it moved, "
                          + "move this scan with it rather than deleting it")
        XCTAssertTrue(sitesOf("struct FocusPeakingHUD").contains("ViewerOverlays.swift"),
                      "the overlay's own toggle is gone; a chord with no visible state "
                          + "is a trap, because green marks with nothing on screen to "
                          + "name them read as a rendering fault")
    }

    // MARK: - 2. Calling it does something

    private static let side = 64

    /// A synthetic frame, given as display-LINEAR luminance and encoded to sRGB bytes on
    /// the way in — which is the domain the sampler actually hands the overlay, so the
    /// fixture exercises the decode as well as the engine.
    private func sampler(_ value: (Int, Int) -> Double) -> PixelSampler {
        let n = Self.side
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let encoded = TransferFunction.srgb.encode(value(x, y))
                let byte = UInt8((Swift.min(Swift.max(encoded, 0), 1) * 255).rounded())
                let i = (y * n + x) * 4
                bytes[i] = byte
                bytes[i + 1] = byte
                bytes[i + 2] = byte
                bytes[i + 3] = 255
            }
        }
        return PixelSampler(width: n, height: n, bytes: bytes)
    }

    private func confidence(_ sampler: PixelSampler,
                            _ sensitivity: FocusPeaking.Sensitivity) -> Plane {
        guard let plane = FocusPeakingOverlayView.confidence(sampler: sampler,
                                                             sensitivity: sensitivity)
        else {
            XCTFail("the overlay returned no plane for a \(Self.side)×\(Self.side) frame")
            return Plane(width: 1, height: 1)
        }
        return plane
    }

    private func markedCount(_ plane: Plane) -> Int {
        plane.values.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
    }

    /// Nothing to focus on, nothing marked — at every sensitivity, including the one
    /// tuned for landscape texture. A detector that paints a flat field is a detector
    /// that will paint a defocused frame, which is the mistake that deletes a keeper.
    func testAFlatFieldIsMarkedNowhere() {
        let flat = sampler { _, _ in 0.35 }
        for sensitivity in FocusPeaking.Sensitivity.allCases {
            XCTAssertEqual(markedCount(confidence(flat, sensitivity)), 0,
                           "a flat 0.35 field is marked at \(sensitivity.label)")
        }
    }

    /// A one-pixel step from 0.2 to 0.8: the two columns that touch it light up and
    /// nothing else in the frame does. Two columns of 64, out of 4096 pixels — marks,
    /// not a fill.
    func testASharpEdgeIsMarkedAndOnlyAtTheEdge() {
        let n = Self.side
        let plane = confidence(sampler { x, _ in x < n / 2 ? 0.2 : 0.8 }, .normal)
        XCTAssertGreaterThan(plane[n / 2 - 1, n / 2], 0.5,
                             "the column on the dark side of the step is not marked")
        XCTAssertGreaterThan(plane[n / 2, n / 2], 0.5,
                             "the column on the bright side of the step is not marked")
        for x in [4, 16, 44, 58] {
            XCTAssertEqual(plane[x, n / 2], 0,
                           "column \(x) is nowhere near the step and is marked anyway")
        }
        XCTAssertEqual(markedCount(plane), 2 * n,
                       "a one-pixel step should mark exactly the two columns that touch "
                           + "it; anything wider is the overlay spreading a mark it did "
                           + "not measure")
    }

    /// THE ONE THAT MAKES IT AN INSTRUMENT. The same 0.2 → 0.8 contrast, spread over
    /// sixteen pixels instead of one — a defocused edge, which is exactly the frame a
    /// culler is trying to reject — is marked nowhere at any sensitivity. Without this,
    /// peaking would light up every soft frame in the roll and tell you nothing.
    func testADefocusedEdgeOfTheSameContrastIsMarkedNowhere() {
        let ramp = sampler { x, _ in
            let t = Swift.min(Swift.max((Double(x) - 24.0) / 16.0, 0), 1)
            return 0.2 + 0.6 * t
        }
        for sensitivity in FocusPeaking.Sensitivity.allCases {
            XCTAssertEqual(markedCount(confidence(ramp, sensitivity)), 0,
                           "a sixteen-pixel ramp reads as an in-focus edge at "
                               + "\(sensitivity.label)")
        }
    }

    /// THE ENGINE'S WHOLE CLAIM, which is that the response is normalized by the local
    /// mean rather than thresholded absolutely. Identical relative texture — a 1.5×
    /// alternation — at 0.60 luminance and at 0.03 must be found equally well, because a
    /// sharpness read that only works in the bright half of the frame is useless in the
    /// case a picker needs it for.
    ///
    /// Delete the `/ denom` and the shadow half goes to nothing while the highlight half
    /// is unchanged, which is what this comparison is shaped to catch.
    func testTheShadowHalfIsFoundAsWellAsTheHighlightHalf() {
        let n = Self.side
        let plane = confidence(sampler { x, y in
            let base = y < n / 2 ? 0.60 : 0.03
            return x % 2 == 0 ? base : base * 1.5
        }, .normal)

        var bright = 0
        var dark = 0
        for y in 0..<n {
            for x in 0..<n where plane[x, y] > 0 {
                if y < n / 2 { bright += 1 } else { dark += 1 }
            }
        }
        let half = n * n / 2
        XCTAssertGreaterThan(bright, half * 9 / 10,
                             "\(bright) of \(half) marked in the 0.60 half")
        XCTAssertGreaterThan(dark, half * 9 / 10,
                             "\(dark) of \(half) marked in the 0.03 half — the shadow "
                                 + "half has stopped being findable, which is the "
                                 + "local-mean divide going missing")
        XCTAssertLessThan(abs(bright - dark), half / 20,
                          "the same texture reads \(bright) in the highlights and "
                              + "\(dark) in the shadows; the threshold has become "
                              + "level-dependent")
    }

    /// Low admits least, fine detail admits most, on one frame — so the control is a
    /// falloff and not a switch, and it walks the direction its own labels promise.
    func testTheThreeSensitivitiesSeparate() {
        let n = Self.side
        let texture = sampler { x, y in
            let base = y < n / 2 ? 0.60 : 0.03
            return x % 2 == 0 ? base : base * 1.5
        }
        let low = markedCount(confidence(texture, .low))
        let normal = markedCount(confidence(texture, .normal))
        let fine = markedCount(confidence(texture, .fineDetail))
        XCTAssertLessThan(low, normal,
                          "low (\(low)) admits as much as normal (\(normal))")
        XCTAssertLessThan(normal, fine,
                          "normal (\(normal)) admits as much as fine detail (\(fine))")
    }

    // MARK: - What the overlay draws

    /// The bytes the overlay hands `CGImage`, or nil.
    private func drawn(_ sampler: PixelSampler,
                       _ sensitivity: FocusPeaking.Sensitivity) -> [UInt8]? {
        guard let image = FocusPeakingOverlayView.build(sampler: sampler,
                                                        sensitivity: sensitivity,
                                                        tint: .green),
              let provider = image.dataProvider,
              let pixels = provider.data
        else { return nil }
        return [UInt8](pixels as Data)
    }

    /// MARKS, NEVER A FILL — the engine's own comment asks for outlines, and a wash over
    /// the whole frame would hide the photograph the overlay exists to judge. Every pixel
    /// of a flat field is fully transparent; a step frame is opaque only where the step
    /// is.
    func testTheOverlayPaintsMarksAndNeverAFill() {
        let n = Self.side
        guard let flat = drawn(sampler { _, _ in 0.35 }, .fineDetail) else {
            return XCTFail("no overlay image for a flat field")
        }
        let flatPainted = stride(from: 3, to: flat.count, by: 4).reduce(0) {
            $0 + (flat[$1] > 0 ? 1 : 0)
        }
        XCTAssertEqual(flatPainted, 0, "a flat field is painted on")

        guard let step = drawn(sampler { x, _ in x < n / 2 ? 0.2 : 0.8 }, .normal) else {
            return XCTFail("no overlay image for a step")
        }
        let stepPainted = stride(from: 3, to: step.count, by: 4).reduce(0) {
            $0 + (step[$1] > 0 ? 1 : 0)
        }
        XCTAssertEqual(stepPainted, 2 * n,
                       "\(stepPainted) pixels painted for a one-pixel step in a "
                           + "\(n * n)-pixel frame")
    }

    /// The bitmap declares `premultipliedLast`, so a painted pixel's colour must not
    /// exceed its own alpha. Writing straight colour under that flag is the halo bug
    /// every overlay ships once, and it is invisible in a screenshot of a bright frame.
    func testTheMarksArePremultiplied() {
        let n = Self.side
        guard let step = drawn(sampler { x, _ in x < n / 2 ? 0.2 : 0.8 }, .fineDetail) else {
            return XCTFail("no overlay image for a step")
        }
        var offending = 0
        var p = 0
        while p + 3 < step.count {
            let a = step[p + 3]
            if step[p] > a || step[p + 1] > a || step[p + 2] > a { offending += 1 }
            p += 4
        }
        XCTAssertEqual(offending, 0,
                       "\(offending) marks carry more colour than alpha — unpremultiplied "
                           + "bytes under a premultiplied bitmap")
    }

    // MARK: - The settings the chord and the badge share

    /// Turning peaking off and on again must not throw away the sensitivity and the
    /// colour: docs/10's table says the state persists per session, and a landscape roll
    /// set to fine detail should stay there.
    func testTogglingKeepsTheSettingsItWasNotAskedToChange() {
        var settings = FocusPeakingSettings(isOn: true, sensitivity: .fineDetail, tint: .red)
        settings.toggle()
        XCTAssertFalse(settings.isOn)
        settings.toggle()
        XCTAssertTrue(settings.isOn)
        XCTAssertEqual(settings.sensitivity, .fineDetail)
        XCTAssertEqual(settings.tint, .red)
    }

    /// Both cycles wrap, and neither reaches the other's axis.
    func testTheCyclesWrapAndStayOnTheirOwnAxis() {
        var settings = FocusPeakingSettings.off
        XCTAssertEqual(settings.sensitivity, .normal, "docs/10's default")
        XCTAssertEqual(settings.tint, .green, "docs/10's default")

        var seen: [FocusPeaking.Sensitivity] = []
        for _ in 0..<FocusPeaking.Sensitivity.allCases.count {
            seen.append(settings.sensitivity)
            settings.cycleSensitivity()
        }
        XCTAssertEqual(Set(seen).count, FocusPeaking.Sensitivity.allCases.count,
                       "the sensitivity cycle does not reach every setting")
        XCTAssertEqual(settings.sensitivity, .normal, "the sensitivity cycle does not wrap")
        XCTAssertEqual(settings.tint, .green, "cycling sensitivity moved the colour")

        var colours: [PeakingColour] = []
        for _ in 0..<PeakingColour.allCases.count {
            colours.append(settings.tint)
            settings.cycleTint()
        }
        XCTAssertEqual(Set(colours).count, PeakingColour.allCases.count)
        XCTAssertEqual(settings.tint, .green, "the colour cycle does not wrap")
        XCTAssertEqual(settings.sensitivity, .normal, "cycling colour moved the sensitivity")
    }

    /// The three peaking colours are the overlay palette's, not a second set — one green
    /// in the app, not two a shade apart.
    func testThePeakingColoursAreTheSharedOverlayColours() {
        XCTAssertEqual(PeakingColour.green.colour, MaskOverlay.Tint.green.colour)
        XCTAssertEqual(PeakingColour.red.colour, MaskOverlay.Tint.red.colour)
        XCTAssertEqual(PeakingColour.white.colour, MaskOverlay.Tint.white.colour)
        XCTAssertFalse(PeakingColour.allCases.contains { $0.colour == RGB.zero },
                       "a black peaking mark is invisible on the defocused shadow it "
                           + "would have to be found in")
    }
}

#endif
