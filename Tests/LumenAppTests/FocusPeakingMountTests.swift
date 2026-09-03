// FocusPeakingMountTests.swift — the focus peaking overlay is actually mounted, and the
// three ways it can be mounted and still be dead are each closed by a named assertion.
//
// `FocusPeaking` in LumenCore is real and measured: on a 1-pixel 0.2→0.8 step across a
// 64×64 field it marks exactly 128 of 4,096 pixels, on a flat field none, and the same
// total contrast spread over sixteen pixels none either — an edge detector that answers
// to edges and not to brightness. `ViewerOverlays.swift` draws it and gives it a HUD.
// None of that was reachable: nothing constructed either view, so the whole feature was
// engine, pixels, controls and prose with no way in from the keyboard or the screen.
//
// WHY THIS IS A SOURCE SCAN AND NOT A VIEW TEST. Every property below is the ABSENCE or
// PRESENCE of a mounting — a `some View` built in the right stack, a boolean naming the
// right property — and SwiftUI offers no way to ask a `View` value what it contains
// without a window server, which the test machine does not have. The instrument is the
// one `CullScaleTests` and `KeyGrammarTests` already use here for the same reason;
// `withoutComments` is ported from them unchanged.
//
// The stripper is not optional. This file's own prose names `FocusPeakingOverlayView`,
// `focusPeaking` and `samplerNeeded` many times, and so does the prose in the files it
// scans — every argument FOR this wiring is written in the comments right beside it. A
// scan over unstripped text would find those words and pass with the feature ripped out.
//
// WHAT IS NOT PROVED HERE, said plainly so a green run is not read as more than it is:
// that the marks land on the right pixels (`FocusPeakingTests` in LumenCoreTests measures
// that), that the overlay's tint is legible, or that ⇧F reaches the dispatcher from a
// real key event. What is proved is that the four seams between a correct engine and a
// photographer's eye are all connected, because each one of them fails silently — the
// key answers, the HUD appears, the engine is right, and there are no marks.
#if os(macOS)
import XCTest
import LumenCore

final class FocusPeakingMountTests: XCTestCase {

    // MARK: Reading the sources

    /// The repository, from this file's own path — the route every scanning test in
    /// this package takes. `Bundle.module` carries resources, not sources.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
    }

    private static func appSource(_ name: String) -> URL {
        repositoryRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("LumenApp", isDirectory: true)
            .appendingPathComponent(name)
    }

    /// A source file with its comments blanked out.
    private func code(_ name: String) throws -> String {
        let url = Self.appSource(name)
        let text = try String(contentsOf: url, encoding: .utf8)
        return Self.withoutComments(text)
    }

    /// Comments blanked, string bodies kept, length and newlines preserved — so every
    /// offset stays valid and a line number can still be counted off the result.
    /// Ported verbatim from `CullScaleTests`, which ported it from `KeyGrammarTests`;
    /// see the latter's header for why the two constructs have to be handled in one pass
    /// rather than by two regexes.
    private static func withoutComments(_ text: String) -> String {
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
                i = j
            } else {
                i += 1
            }
        }
        return String(out)
    }

    /// Every brace-delimited body that follows an occurrence of `marker`.
    ///
    /// The `{` is found by walking forward with a PAREN depth count, so a parameter list
    /// or a trailing-closure signature between the marker and the body cannot be mistaken
    /// for the body's opening brace. Ported from `CullScaleTests` for the same reason it
    /// exists there: "inside `badges`" and "inside `samplerNeeded`" are the claims being
    /// made, and a whole-file `contains` cannot tell the inside of a declaration from
    /// three hundred lines away.
    private func bodies(after marker: String, in code: String) -> [String] {
        let characters = Array(code)
        let needle = Array(marker)
        var found: [String] = []
        guard !needle.isEmpty, characters.count >= needle.count else { return [] }
        for start in 0...(characters.count - needle.count) {
            guard Array(characters[start..<(start + needle.count)]) == needle else {
                continue
            }
            var i = start + needle.count
            var parens = 0
            var open: Int?
            while i < characters.count {
                let c = characters[i]
                if c == "(" { parens += 1 }
                if c == ")" { parens -= 1 }
                if c == "{" && parens <= 0 { open = i; break }
                i += 1
            }
            guard let opening = open else { continue }
            var depth = 0
            var j = opening
            while j < characters.count {
                if characters[j] == "{" { depth += 1 }
                if characters[j] == "}" {
                    depth -= 1
                    if depth == 0 {
                        found.append(String(characters[opening...j]))
                        break
                    }
                }
                j += 1
            }
        }
        return found
    }

    /// The one body of a declaration that must have exactly one, failing rather than
    /// silently scanning nothing when the declaration has been renamed out from under
    /// the scan. Every assertion below is of the form "this body does / does not contain
    /// X", and both halves of that are satisfied by an empty string.
    private func body(of marker: String, in source: String) -> String {
        let all = bodies(after: marker, in: source)
        guard all.count == 1 else {
            XCTFail("expected exactly one `\(marker)` in the scanned source, found "
                        + "\(all.count) — the declaration was renamed and this scan is "
                        + "now reading nothing, which passes every containment test")
            return ""
        }
        return all[0]
    }

    // MARK: The overlay is built, and built over the mask wash

    func testTheLoupeConstructsTheFocusPeakingOverlay() throws {
        let source = try code("LoupeView.swift")
        let canvas = body(of: "private func canvas(", in: source)

        XCTAssertTrue(canvas.contains("FocusPeakingOverlayView(sampler:"),
                      "nothing in the loupe's canvas constructs FocusPeakingOverlayView "
                          + "— the engine, the overlay and the HUD all exist and no "
                          + "photograph can reach them")
        XCTAssertTrue(canvas.contains("settings: state.focusPeaking"),
                      "the overlay is built with something other than the viewer's own "
                          + "peaking settings, so the HUD's sensitivity and tint controls "
                          + "change nothing on screen")

        // ORDER, not just presence. The mask overlay's opaque modes repaint the unmasked
        // pixels flat and its tinted ones lay a wash over the frame; drawn after the
        // peaking layer, either one buries the marks under the very picture they were
        // measured from — a failure that looks exactly like peaking finding no edges.
        guard let mask = canvas.range(of: "MaskOverlayView("),
              let peaking = canvas.range(of: "FocusPeakingOverlayView(") else {
            XCTFail("expected both overlays in the canvas")
            return
        }
        XCTAssertLessThan(mask.lowerBound, peaking.lowerBound,
                          "the mask overlay is drawn after the peaking marks, which "
                              + "buries them under the wash")
    }

    // MARK: The HUD is outside the stack that refuses hits

    func testTheHUDIsMountedOutsideTheNonInteractiveBadges() throws {
        let source = try code("LoupeView.swift")

        XCTAssertTrue(source.contains("FocusPeakingHUD(settings:"),
                      "the peaking HUD is never constructed — ⇧F would turn the marks on "
                          + "with nothing on screen naming the mode or offering the way "
                          + "back out of it")

        let badges = body(of: "private var badges: some View", in: source)
        // The precondition for the claim: `badges` is the stack that refuses hits. If
        // that ever stops being true this assertion is what says so, rather than the
        // next one quietly becoming meaningless.
        XCTAssertTrue(badges.contains(".allowsHitTesting(false)"),
                      "the badges stack no longer refuses hits, so the rule this test "
                          + "enforces has lost its reason — re-read it before relaxing it")
        XCTAssertFalse(badges.contains("FocusPeakingHUD"),
                       "the peaking HUD is inside `badges`, which ends "
                           + ".allowsHitTesting(false) — its colour, sensitivity and "
                           + "close buttons would be drawn and answer nothing, and the "
                           + "close button is the only way out for a photographer who "
                           + "does not know the chord")
    }

    // MARK: The sampler is built for it — the seam one layer down

    func testSamplerNeededNamesFocusPeaking() throws {
        let source = try code("LoupeView.swift")
        let needed = body(of: "private var samplerNeeded: Bool", in: source)

        // THE QUIETEST OF THE FOUR FAILURES. `canvas` binds `let sampler` before it
        // builds the overlay, and `samplerNeeded` is what decides whether that optional
        // is ever filled. Leave peaking out of it and the sampler stays nil for a
        // photograph with no readout, no clipping overlay and no solo mask — which is
        // every photograph being culled. The binding fails, the overlay is never built,
        // and ⇧F puts a HUD over a clean frame: the key answered, the mode is on, the
        // engine is correct, and there is nothing to see.
        XCTAssertTrue(needed.contains("focusPeaking"),
                      "`samplerNeeded` does not name focusPeaking — the sampler is never "
                          + "built for peaking alone, so the overlay's `let sampler` "
                          + "binding fails and the feature is wired and dead")
        XCTAssertTrue(needed.contains("state.focusPeaking.isOn"),
                      "`samplerNeeded` mentions peaking but not its switch; the sampler "
                          + "is a full-resolution draw and up to ~45 MB per rendered "
                          + "frame, and it must be built when peaking is ON and not "
                          + "whenever the settings value merely exists")
    }

    // MARK: One value, one broadcast — and a viewing mode, not an edit

    func testTheSettingsLiveOnAppStateAsASingleValue() throws {
        let source = try code("AppState.swift")

        XCTAssertTrue(source.contains("@Published var focusPeaking: FocusPeakingSettings"),
                      "AppState no longer publishes the peaking settings as one value — "
                          + "split into a switch, a sensitivity and a tint they are three "
                          + "broadcasts, and three window re-bodies, for the one keystroke "
                          + "that writes them")
        for split in ["@Published var peakingSensitivity", "@Published var peakingTint",
                      "@Published var peakingOn"] {
            XCTAssertFalse(source.contains(split),
                           "\(split) is published separately — that is the per-property "
                               + "broadcast DragBroadcastTests exists to keep off this "
                               + "app's main actor")
        }
    }

    // MARK: The chord the app already promised

    func testShiftFTogglesPeaking() throws {
        let source = try code("Keymap.swift")

        XCTAssertTrue(source.contains("state.focusPeaking.toggle()"),
                      "no key toggles peaking — the HUD's close button says \"(⇧F)\" in "
                          + "its help, so the app is printing a chord nothing answers")

        // BEFORE the bare `f`, or Swift never reaches it: a switch takes the first
        // matching case, and the unshifted `f` case matches a shifted F just as happily
        // as an unshifted one. Ordered the other way this compiles, satisfies every
        // other assertion here, and makes ⇧F open the filmstrip.
        guard let shifted = source.range(of: "case \"f\" where flags.contains(.shift):"),
              let bare = source.range(of: "case \"f\":") else {
            XCTFail("expected both an unshifted and a shifted F in the dispatcher")
            return
        }
        XCTAssertLessThan(shifted.lowerBound, bare.lowerBound,
                          "the bare `f` case precedes the shifted one, so ⇧F is swallowed "
                              + "by the filmstrip and peaking is unreachable")
    }
}
#endif
