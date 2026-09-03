// MaskPanelTests.swift
// The mask editor's own claims, put to something other than a reading.
//
// This file covers five findings against `MaskPanel.swift` and `MaskFloatingPanel.swift`,
// and it is deliberately two kinds of test:
//
//   · PURE FUNCTIONS, wherever the panel could be made to hold one. `deletionLosesWork`,
//     `showsOperation`, `unofferedKinds` and `pickerKinds` are rules a view body used to
//     state inline, and a rule inside a `some View` cannot be asked a question. Each was
//     lifted out to exactly the shape a test can call; the scans below then check that
//     the view still CALLS the lifted rule, because a predicate nobody reaches is a
//     green test over a dead branch.
//
//   · SOURCE SCANS, for the claims that are about drawn text and drawn geometry — a
//     label's spelling, a stack's spacing, a target's frame. No view is hosted here (see
//     `LayoutMetricSupport` for why measurement without a window server is possible at
//     all, and for what it cannot do), so these read the file.
//
// EVERY SCAN STRIPS COMMENTS FIRST, and in this file that is not a formality. The
// renames below are all argued for in comments that quote the OLD name — "Max strength",
// "Smoothness", "Brightness tolerance" all appear in `MaskPanel.swift` today, inside the
// paragraphs explaining why they are gone. An unstripped scan for those strings would
// find the explanation and report the defect it explains. `testTheStripperIsWhatMakes
// TheseScansMeanAnything` asserts both halves of that on the real file rather than on a
// sample, so the proof cannot drift from the thing it is proving.

#if os(macOS)

import Foundation
import XCTest
@testable import LumenApp
@testable import LumenCore

final class MaskPanelTests: XCTestCase {

    // MARK: - Fixtures

    private func component(_ kind: MaskKind, op: MaskOp = .add) -> MaskComponent {
        var c = MaskComponent(op: op, kind: kind)
        switch kind {
        case .linear, .similarityLine: c.line = [0.2, 0.2, 0.8, 0.8]
        case .radial: c.center = [0.5, 0.5]; c.radii = [0.3, 0.2]
        case .brush: c.strokesRef = "sha256:probe"
        case .polygon: c.path = [[0, 0], [1, 0], [1, 1]]
        case .colorRange, .similarity: c.samples = [[0.4, 0.5, 0.6]]
        default: break
        }
        return c
    }

    private func mask(_ kinds: [MaskKind]) -> Mask {
        Mask(name: "", components: kinds.map { component($0) })
    }

    // MARK: - (a) The three labels that did not fit

    /// "Max strength" measured 67.4 points against a 56 point budget and truncated on
    /// every brush this application has ever drawn.
    ///
    /// 56 is `Lumen.labelWidth` minus the behaviour glyph and its gap, which is what a
    /// glyph-bearing row leaves for its name — and this row has a glyph
    /// (`.densityCeiling`). The replacement is the word the row was already using twice:
    /// the shape is called `densityCeiling` and the tooltip opens "The ceiling repeated
    /// passes build toward".
    func testTheBrushDensityRowIsNamedForTheCeilingItSets() throws {
        let source = try strippedSource("LumenApp/MaskPanel.swift")
        XCTAssertTrue(flat(source).contains("LumenSlider(title: \"Ceiling\""),
                      "the brush's density row should be titled Ceiling")
        XCTAssertFalse(source.contains("Max strength"),
                       "\"Max strength\" is 67.4 pt against a 56 pt glyph-row budget")
        // The word did not go anywhere the photographer cannot reach it: the tooltip
        // still says what the ceiling is, which is the half a shorter label may not cost.
        XCTAssertTrue(source.contains("The ceiling repeated passes build toward"),
                      "the tooltip is where the long form lives now")
    }

    /// "Smoothness" fitted its 56 point budget only by shrinking to 9.5 pt.
    ///
    /// `minimumScaleFactor(0.86)` on an 11 pt label bottoms out at 9.46, and
    /// `LumenType.swift` says "10 is the floor" — so the row was not fitting, it was
    /// quietly becoming a second type size half a point under the app's own minimum.
    /// The short form is the field's own name, `MaskComponent.smooth`.
    func testTheBandSmoothingRowUsesAWordThatRendersAtFullSize() throws {
        let source = try strippedSource("LumenApp/MaskPanel.swift")
        XCTAssertFalse(source.contains("\"Smoothness\""),
                       "\"Smoothness\" renders at 9.5 pt in a 56 pt column — under the floor")
        XCTAssertEqual(occurrences(of: "\"Smooth\"", in: source), 2,
                       "both the luminance band and the depth band use the one name")
    }

    /// One parameter, one name — including on the row that would have fitted either way.
    ///
    /// The depth band's Smoothness has no behaviour glyph and therefore the whole 86 pt
    /// column, so only one of the two rows was ever in trouble. Renaming just that one
    /// would have left `MaskComponent.smooth` labelled two different ways depending on
    /// which component kind is selected, which is the drift the rename exists to close.
    func testTheSameFieldIsNotLabelledTwoDifferentWays() throws {
        let source = try strippedSource("LumenApp/MaskPanel.swift")
        let smoothRows = source.components(separatedBy: "\\.smooth").count - 1
        XCTAssertEqual(smoothRows, 2, "two rows drive the smooth field")
        XCTAssertEqual(occurrences(of: "\"Smooth\"", in: source), smoothRows,
                       "every row driving it should carry the same label")
    }

    /// "Brightness tolerance" measured 106.3 points against the full 86 pt column.
    ///
    /// Past the 0.86 shrink floor, so it truncated outright — and its partner sat at
    /// about 85, a point inside. Two adjacent rows reading "Colour tolerance" and
    /// "Brightness toler…" is the precise defect `Lumen.labelWidth`'s own comment was
    /// once widened to 94 to avoid: names that differ only in the part that got cut.
    ///
    /// The qualifier moved to the tooltip rather than being deleted, which is the
    /// difference between a shorter label and a poorer one.
    func testTheSimilarityGateIsNamedByItsTwoAxes() throws {
        let source = try strippedSource("LumenApp/MaskPanel.swift")
        let f = flat(source)
        XCTAssertFalse(source.contains("Brightness tolerance"),
                       "106.3 pt against an 86 pt column — TRUNCATES")
        XCTAssertFalse(source.contains("Colour tolerance"),
                       "its partner shrinks, and the pair has to stay a pair")
        XCTAssertTrue(f.contains("optionalSlider(id, i, \"Colour\", \\.chromaSel"))
        XCTAssertTrue(f.contains("optionalSlider(id, i, \"Brightness\", \\.lumaSel"))
        // Nothing was lost: both rows still say "tolerance", once each, where a
        // photographer who stops to ask will be hovering.
        XCTAssertTrue(f.contains("The chroma half of the tolerance"))
        XCTAssertTrue(f.contains("The lightness half of the tolerance"))
    }

    /// The renamed rows still carry their tooltip at all, which is the thing that pays
    /// for the shorter name.
    ///
    /// `optionalSlider` had no `help:` parameter before this — every row it built was
    /// mute — so a rename that moved a word onto the tooltip would have moved it
    /// nowhere. The forwarding is what makes the trade honest.
    func testTheComponentSliderCanCarryATooltipAtAll() throws {
        let source = try flattenedStrippedSource("LumenApp/MaskPanel.swift")
        XCTAssertTrue(source.contains("behaviour: BehaviourShape? = nil, help: String? = nil"),
                      "optionalSlider must accept a tooltip")
        XCTAssertTrue(source.contains("/ Swift.max(r.upperBound - r.lowerBound, 1e-9), help: help)"),
                      "and forward it to the slider, or the parameter is decoration")
    }

    // MARK: - (b) One row pitch, not two

    /// The develop column stacks its rows at a pitch of 32 and this panel stacked at 30.
    ///
    /// `Lumen.rowGap`'s own comment gives the arithmetic — "the pitch is
    /// `rowHeight + 2·rowPadding + rowGap` = 24 + 4 + 4 = 32… it was 2, for a pitch of
    /// 30 — off the grid" — and then this file kept the literal 2 at twenty-nine sites,
    /// so the application shipped both pitches at once: one in the column, one in the
    /// mask editor beside it. Two points a row is invisible on one row and unmistakable
    /// down a stack of fifteen.
    func testEveryStackOfRowsInThisPanelUsesTheAppsOwnRowGap() throws {
        let source = try strippedSource("LumenApp/MaskPanel.swift")
        XCTAssertFalse(source.contains("spacing: 2)"),
                       "a row stack at 2 is a pitch of 30 against the column's 32")
        XCTAssertGreaterThanOrEqual(
            occurrences(of: "spacing: Lumen.rowGap", in: source), 29,
            "the twenty-nine stacks that carried the literal should carry the token")
    }

    /// And the token is still the number the column stacks at, so "matching" means
    /// something. A test that only checked for the token's NAME would pass just as
    /// happily on the day somebody sets it to 2.
    func testTheRowPitchIsThirtyTwoAndOnTheFourPointGrid() {
        XCTAssertEqual(Lumen.rowGap, 4)
        XCTAssertEqual(Lumen.rowHeight, 24)
        let rowPadding: CGFloat = 4
        let pitch = Lumen.rowHeight + 2 * rowPadding + Lumen.rowGap
        XCTAssertEqual(pitch, 32, "rowHeight + 2·rowPadding + rowGap")
        XCTAssertEqual(pitch.truncatingRemainder(dividingBy: 4), 0, "the 4 pt grid")
    }

    /// The other side of "two pitches in one app": the panels this one now matches.
    ///
    /// Asserted positively rather than by scanning them for the old literal, because
    /// these seven files are not this panel's to keep clean — what matters here is that
    /// the pitch the mask editor adopted is the one they are actually drawn at.
    func testTheDevelopPanelsAreStackedAtTheSameToken() throws {
        for panel in ["BasicPanel", "ColorPanel", "CropPanel", "DetailPanel",
                      "EffectsPanel", "LookPanel", "ZonesPanel"] {
            let source = try strippedSource("LumenApp/\(panel).swift")
            XCTAssertTrue(source.contains("spacing: Lumen.rowGap"),
                          "\(panel) is one of the seven the mask editor is matching")
        }
    }

    // MARK: - (c) Switching a mask off is not deleting it

    /// Two verbs, two controls, and nothing shared but the row they sit on.
    ///
    /// The reversible one is a glyph that changes shape; the destructive one is a WORD,
    /// inside a menu that has to be opened first. Neither can be reached by a slip
    /// aimed at the other.
    func testDisableAndDeleteAreDifferentControlsInDifferentPlaces() throws {
        let source = try flattenedStrippedSource("LumenApp/MaskPanel.swift")
        XCTAssertTrue(source.contains("Image(systemName: mask.enabled ? \"eye\" : \"eye.slash\")"),
                      "disable is a glyph that changes shape")
        XCTAssertTrue(source.contains("editMask(mask.id, key: nil) { $0.enabled.toggle() }"),
                      "and it toggles a flag, nothing more")
        XCTAssertTrue(source.contains("LumenMenuItem(title: \"Delete\", symbol: \"trash\")"),
                      "delete is a named row inside a menu")
        // The reversible one says what it keeps, so the two cannot be read as the same
        // offer in two places.
        XCTAssertTrue(source.contains("Stop rendering this mask, keeping it"))
    }

    /// NEITHER IS A ONE-PIXEL TARGET, which is the other half of telling them apart:
    /// two controls a photographer can distinguish but not reliably hit are still one
    /// mistake waiting.
    ///
    /// The eye is a 16×16 frame with its own `contentShape`, so the whole square is
    /// live rather than the ten-odd points the glyph paints. Delete has no target of
    /// its own on the row at all — it is a full menu row behind a deliberate open,
    /// which is why the row can afford to keep the eye small.
    func testNeitherVerbIsAOnePixelTarget() throws {
        let source = try flattenedStrippedSource("LumenApp/MaskPanel.swift")
        XCTAssertTrue(
            source.contains("Image(systemName: mask.enabled ? \"eye\" : \"eye.slash\") "
                            + ".font(.lumenGlyphCaption) .frame(width: 16, height: 16) "
                            + ".contentShape(Rectangle())"),
            "the eye needs a frame and a content shape, or only the glyph is hittable")
        // Nothing on the row deletes. A trash glyph beside the eye is exactly the
        // arrangement this test exists to keep out.
        XCTAssertFalse(source.contains("Image(systemName: \"trash\")"),
                       "delete must not be a glyph on the row beside the eye")
    }

    /// The confirmation is armed only where undo is not enough, and that line is drawn
    /// at ONE GESTURE.
    ///
    /// Undo already reaches a deleted mask, so confirming every deletion would be a
    /// dialog in front of something already protected — which is how an application
    /// teaches people to dismiss its confirmations without reading them. What undo does
    /// not protect is the deletion nobody notices, twenty edits later.
    func testAMaskThatIsOneGestureToRemakeIsDeletedWithoutAsking() {
        XCTAssertFalse(MaskPanel.deletionLosesWork(mask([.radial])),
                       "a radial you dragged is one gesture")
        XCTAssertFalse(MaskPanel.deletionLosesWork(mask([.linear])),
                       "so is a gradient")
        XCTAssertFalse(MaskPanel.deletionLosesWork(mask([.colorRange])),
                       "so is one click of the eyedropper")
        XCTAssertFalse(MaskPanel.deletionLosesWork(Mask()),
                       "an empty mask has nothing in it to lose")
    }

    func testAMaskCarryingHandWorkArmsTheRowInstead() {
        XCTAssertTrue(MaskPanel.deletionLosesWork(mask([.brush])),
                      "painted strokes are the only thing here measured in minutes")
        XCTAssertTrue(MaskPanel.deletionLosesWork(mask([.polygon])),
                      "a closed outline is a corner at a time")
        XCTAssertTrue(MaskPanel.deletionLosesWork(mask([.radial, .linear])),
                      "a stack is a decision about how selections fold together")

        var manySamples = mask([.colorRange])
        manySamples.components[0].samples = [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]]
        XCTAssertTrue(MaskPanel.deletionLosesWork(manySamples),
                      "several samples is a colour range built up by hand")
    }

    /// A GRADE IS WORK TOO, and it is the case a components-only rule would miss: one
    /// radial with twenty minutes of local colour on it looks exactly like the radial
    /// that is one gesture to redraw.
    ///
    /// All six places a grade can hide, because `LocalAdjust.isModified` answers per
    /// GROUP by design and Curve, Grading and Point Colour sit outside those groups.
    func testAGradedMaskIsNeverDeletedWithoutAsking() {
        var exposed = mask([.radial])
        exposed.adjust.exposure = 0.5
        XCTAssertTrue(MaskPanel.deletionLosesWork(exposed), "Light")

        var coloured = mask([.radial])
        coloured.adjust.sat = 20
        XCTAssertTrue(MaskPanel.deletionLosesWork(coloured), "Colour")

        var textured = mask([.radial])
        textured.adjust.clarity = 15
        XCTAssertTrue(MaskPanel.deletionLosesWork(textured), "Presence & Detail")

        var curved = mask([.radial])
        curved.adjust.curve = CurveSet()
        XCTAssertTrue(MaskPanel.deletionLosesWork(curved), "the local point curve")

        var graded = mask([.radial])
        graded.adjust.wheels = GradingWheels()
        XCTAssertTrue(MaskPanel.deletionLosesWork(graded), "the local grading wheels")

        var swatched = mask([.radial])
        swatched.adjust.pointColors = [PointColor(sample: [0.4, 0.5, 0.6])]
        XCTAssertTrue(MaskPanel.deletionLosesWork(swatched), "a Point Colour swatch")
    }

    /// The armed row offers both ways out, and the cheap one is first.
    func testTheArmedRowOffersKeepBesideDelete() throws {
        let source = try flattenedStrippedSource("LumenApp/MaskPanel.swift")
        let prompt = try XCTUnwrap(source.range(of: "Text(\"Delete \\u{201C}"))
        let tail = String(source[prompt.lowerBound...].prefix(900))
        let keep = try XCTUnwrap(tail.range(of: "Text(\"Keep\")"))
        let delete = try XCTUnwrap(tail.range(of: "Text(\"Delete\")"))
        XCTAssertLessThan(keep.lowerBound, delete.lowerBound,
                          "Keep is where the pointer already is when the menu closes")
        XCTAssertTrue(tail.contains("pendingDeleteMaskID = nil deleteMask(mask.id)"),
                      "and the destructive branch disarms the row before it acts")
    }

    // MARK: - (d) Four kinds are absent, not greyed out

    /// The kinds whose matte would need a Core ML model this application does not
    /// bundle. Each rasterizes to an empty plane, so each is off the board entirely.
    ///
    /// A tile a photographer can see, read and never enable is a promise the app cannot
    /// keep. Absence teaches nothing false; a greyed tile teaches that the app is
    /// unfinished.
    func testTheFourKindsWithNoModelAreNotOnThePickerBoard() {
        XCTAssertEqual(Set(MaskPanel.unofferedKinds),
                       Set<MaskKind>([.aiSky, .aiObject, .aiLandscape, .depthRange]))
        let offered = Set(MaskPanel.pickerKinds(maskCount: 4))
        for kind in MaskPanel.unofferedKinds {
            XCTAssertFalse(offered.contains(kind),
                           "\(kind) has no matte source and must not be offerable")
        }
    }

    /// Derived from the provider rather than listed, in BOTH directions.
    ///
    /// The list is `(aiKinds + [.depthRange]).filter { $0.matteProvider == .model }`, so
    /// the day a sky model lands and that kind's provider becomes `.vision` the tile
    /// appears with no second edit anywhere — and nothing that needs a model can be
    /// added to the board by hand without this failing.
    func testThePickerRosterCannotGoStaleAgainstTheProvider() {
        for kind in MaskPanel.unofferedKinds {
            XCTAssertEqual(kind.matteProvider, .model, "\(kind)")
        }
        for kind in MaskPanel.pickerKinds(maskCount: 4) {
            XCTAssertNotEqual(kind.matteProvider, .model,
                              "\(kind) is offered but could never produce a matte")
        }
    }

    /// The roster is the board, which is what makes the two tests above about the
    /// picker rather than about a list.
    ///
    /// `kindBoard` draws three groups plus a conditional Reuse, and `pickerKinds` is the
    /// same four in the same order. If somebody adds a fourth group to the board this
    /// fails, rather than the roster quietly describing a picker that has moved on.
    func testTheRosterIsTheBoardTheUserActuallySees() throws {
        XCTAssertEqual(MaskPanel.pickerKinds(maskCount: 4),
                       MaskPanel.drawnKinds + MaskPanel.rangeKinds
                           + MaskPanel.visionKinds + [.maskRef])
        XCTAssertEqual(MaskPanel.pickerKinds(maskCount: 1),
                       MaskPanel.drawnKinds + MaskPanel.rangeKinds + MaskPanel.visionKinds,
                       "a reference on a photograph with one mask can only make an "
                       + "empty component")

        let source = try flattenedStrippedSource("LumenApp/MaskPanel.swift")
        XCTAssertTrue(source.contains(
            "boardGroup(\"Draw it by hand\", MaskPanel.drawnKinds, action) "
            + "boardGroup(\"Find it by tone or colour\", MaskPanel.rangeKinds, action) "
            + "boardGroup(\"Find it for me\", MaskPanel.visionKinds, action)"),
            "the board draws the rosters, so the rosters are what the picker offers")
    }

    /// NOT GREYED — the tile has no disabled state to be drawn in.
    ///
    /// This is the failure mode absence was chosen over: a tile that is present,
    /// readable, and dead. `kindTile` carries no `.disabled(` and no second foreground
    /// style, so there is no way to render one except by not drawing it.
    func testNoTileOnTheBoardIsDrawnDisabled() throws {
        let source = try strippedSource("LumenApp/MaskPanel.swift")
        let tile = try XCTUnwrap(bodyOf("private func kindTile", in: source))
        XCTAssertFalse(tile.contains(".disabled("),
                       "a kind is absent from the board or it works")
        XCTAssertFalse(tile.contains("Lumen.tertiaryText"),
                       "and there is no dimmed variant of a tile to fall into")
        XCTAssertTrue(tile.contains(".lumenClickCursor()"),
                      "every tile on the board is pressable")
    }

    // MARK: - (e) The composition operator is on the row

    /// How a component meets the ones above it is the only thing about a stack that
    /// cannot be read off the kind names, so every row after the first prints it.
    func testEveryComponentAfterTheFirstSaysHowItMeetsTheStack() {
        for op in [MaskOp.add, .subtract, .intersect] {
            XCTAssertTrue(MaskPanel.showsOperation(at: 1, op: op), "\(op) at index 1")
            XCTAssertTrue(MaskPanel.showsOperation(at: 7, op: op), "\(op) at index 7")
        }
    }

    /// The one silence is a LEADING ADD, because every stack seeds empty and the first
    /// component is what fills it. A leading Subtract is a real state the format can
    /// hold — it selects nothing — and the row saying so is how anybody would find out.
    func testOnlyALeadingAddIsSilent() {
        XCTAssertFalse(MaskPanel.showsOperation(at: 0, op: .add))
        XCTAssertTrue(MaskPanel.showsOperation(at: 0, op: .subtract))
        XCTAssertTrue(MaskPanel.showsOperation(at: 0, op: .intersect))
    }

    /// And the rule is the one the ROW draws by, not a second copy of it.
    ///
    /// The predicate above was lifted out of `componentRow`'s body. Without this scan
    /// the two tests before it would pass over a function the view had stopped calling,
    /// which is the specific way an extracted rule goes quietly dead.
    func testTheRowDrawsByThatRuleAndPrintsAWordForIt() throws {
        let source = try flattenedStrippedSource("LumenApp/MaskPanel.swift")
        XCTAssertTrue(source.contains(
            "if MaskPanel.showsOperation(at: index, op: component.op) { "
            + "LumenBadge(text: MaskPanel.opName(component.op)) }"),
            "the row asks the rule, and prints the operation's word through a badge")
        for op in [MaskOp.add, .subtract, .intersect] {
            XCTAssertFalse(MaskPanel.opName(op).isEmpty)
            XCTAssertNil(MaskPanel.opName(op).rangeOfCharacter(
                from: CharacterSet(charactersIn: "\u{222A}\u{2229}\u{2212}")),
                "the badge carries a word, not set theory")
        }
    }

    // MARK: - (f) Where a dragged mask lands

    /// The rule a photographer can predict without being told: the dragged mask ends up
    /// at the index the mask it was dropped on used to occupy, and everything else keeps
    /// its relative order.
    ///
    /// Both directions, because the insertion index is the same expression for both and
    /// that is only obvious once it has been checked: dragging DOWN, the removal has
    /// already shifted the target to `to - 1`, so inserting at `to` puts the dragged mask
    /// just after it; dragging UP, the target has not moved and inserting at `to` puts it
    /// just before. One expression, two arguments.
    func testADroppedMaskTakesTheIndexOfTheMaskItLandedOn() {
        let list = ["a", "b", "c", "d"].map { Mask(id: $0) }
        XCTAssertEqual(MaskPanel.reordered(list, moving: "a", onto: "c").map(\.id),
                       ["b", "c", "a", "d"], "dragging down")
        XCTAssertEqual(MaskPanel.reordered(list, moving: "d", onto: "b").map(\.id),
                       ["a", "d", "b", "c"], "dragging up")
        XCTAssertEqual(MaskPanel.reordered(list, moving: "a", onto: "b").map(\.id),
                       ["b", "a", "c", "d"], "one place down")
    }

    /// Order is a render fact, so a reorder that quietly does nothing is worse than one
    /// that is refused: both renderers walk `plan.masks` front to back, and where two
    /// masks overlap the later one works on the earlier one's output.
    func testAnImpossibleDropChangesNothingRatherThanGuessing() {
        let list = ["a", "b"].map { Mask(id: $0) }
        XCTAssertEqual(MaskPanel.reordered(list, moving: "a", onto: "a").map(\.id),
                       ["a", "b"], "onto itself")
        XCTAssertEqual(MaskPanel.reordered(list, moving: "ghost", onto: "b").map(\.id),
                       ["a", "b"], "a mask that is not in the list")
        XCTAssertEqual(MaskPanel.reordered(list, moving: "a", onto: "ghost").map(\.id),
                       ["a", "b"], "a target that is not in the list")
        XCTAssertEqual(MaskPanel.reordered([], moving: "a", onto: "b").count, 0)
    }

    /// IT ADOPTS THE TARGET'S FOLDER, and that is not a convenience.
    ///
    /// The list draws each group's members together and the loose masks after them, so a
    /// mask dropped between two members of a folder that did NOT join the folder would be
    /// drawn somewhere else entirely — the drop would read as refused, or worse, as
    /// having moved it somewhere at random.
    func testADroppedMaskJoinsTheFolderItLandedIn() {
        var list = ["a", "b", "c"].map { Mask(id: $0) }
        list[1].group = "sky"
        list[2].group = "sky"
        let after = MaskPanel.reordered(list, moving: "a", onto: "c")
        XCTAssertEqual(after.map(\.id), ["b", "c", "a"])
        XCTAssertEqual(after.first { $0.id == "a" }?.group, "sky",
                       "a mask drawn among a folder's members is in that folder")

        // The rule holds dragging the other way too, which is what makes it a rule
        // rather than a special case for downward drops.
        let back = MaskPanel.reordered(after, moving: "a", onto: "b")
        XCTAssertEqual(back.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(back.first { $0.id == "a" }?.group, "sky")
    }

    // MARK: - The scan's own foundation

    /// THE STRIPPER IS WHAT MAKES EVERY SCAN ABOVE MEAN ANYTHING, so it is asserted
    /// against the real file rather than against a sample.
    ///
    /// All three retired labels are still written down in `MaskPanel.swift` — inside the
    /// comments that argue for their replacements. That is the substitution proof and
    /// the trap in one: a scan that did not strip would find "Max strength" in the
    /// paragraph explaining that "Max strength" is gone, and report a defect that had
    /// been fixed. Both halves are checked, so the day somebody swaps the stripped
    /// source for the raw one these fail instead of quietly passing.
    func testTheStripperIsWhatMakesTheseScansMeanAnything() throws {
        let raw = try source("LumenApp/MaskPanel.swift")
        let stripped = stripComments(raw)
        for retired in ["Max strength", "Smoothness", "Brightness tolerance",
                        "Colour tolerance"] {
            XCTAssertTrue(raw.contains(retired),
                          "\(retired) should still be argued about in a comment")
            XCTAssertFalse(stripped.contains(retired),
                           "\(retired) must survive only as prose")
        }
        // Both comment shapes, and the code either side of them kept.
        let sample = """
        let a = 1 // "Max strength"
        /* "Smoothness" */ let b = 2
        let c = "Ceiling"
        """
        let out = stripComments(sample)
        XCTAssertFalse(out.contains("Max strength"))
        XCTAssertFalse(out.contains("Smoothness"))
        XCTAssertTrue(out.contains("let a = 1"))
        XCTAssertTrue(out.contains("let b = 2"))
        XCTAssertTrue(out.contains("let c = \"Ceiling\""))
        // WHAT IT CANNOT DO, said here rather than discovered later: it is not string
        // aware, so a `//` inside a literal would take the rest of that line with it.
        // No such literal exists in the files scanned above — and this is the assertion
        // that says the limitation was checked rather than missed.
        for file in ["LumenApp/MaskPanel.swift", "LumenApp/MaskFloatingPanel.swift"] {
            for line in try source(file).split(separator: "\n") {
                guard let slashes = line.range(of: "//") else { continue }
                let before = line[line.startIndex..<slashes.lowerBound]
                XCTAssertEqual(before.filter { $0 == "\"" }.count % 2, 0,
                               "a `//` inside a string literal in \(file) would take "
                               + "the rest of its line with it: \(line)")
            }
        }
    }

    // MARK: - Reading the sources

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        return try String(contentsOf: root.appendingPathComponent(relative),
                          encoding: .utf8)
    }

    private func strippedSource(_ relative: String) throws -> String {
        stripComments(try source(relative))
    }

    private func flattenedStrippedSource(_ relative: String) throws -> String {
        flat(try strippedSource(relative))
    }

    /// Whitespace flattened, so a scan can name a chain of modifiers without also
    /// pinning how it happens to be wrapped today.
    private func flat(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// A function's body, from its declaration to the first line that closes at its own
    /// indentation. Enough to ask "does THIS function do X" rather than "does the file".
    private func bodyOf(_ declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        let rest = source[start.lowerBound...]
        var depth = 0
        var seenBrace = false
        var out = ""
        for character in rest {
            out.append(character)
            if character == "{" { depth += 1; seenBrace = true }
            if character == "}" {
                depth -= 1
                if seenBrace, depth == 0 { return out }
            }
        }
        return nil
    }
}

// MARK: - the scan's foundation

/// `PreviewRungTests.stripComments`, copied — which is itself a copy of
/// `DeliveryNameTests.strippingComments`. It travels rather than being shared because
/// each suite's proof should not depend on another suite's helper staying put.
///
/// A scan that reads doc comments proves only that somebody wrote the symbol's name
/// down, and in this file that would be actively wrong: every label this suite checks
/// for the ABSENCE of is present in a comment eight lines from where it used to be.
private func stripComments(_ source: String) -> String {
    var out = ""
    var index = source.startIndex
    var inBlock = false
    while index < source.endIndex {
        let rest = source[index...]
        if inBlock {
            if rest.hasPrefix("*/") { inBlock = false; index = source.index(index, offsetBy: 2) }
            else { index = source.index(after: index) }
            continue
        }
        if rest.hasPrefix("/*") { inBlock = true; index = source.index(index, offsetBy: 2); continue }
        if rest.hasPrefix("//") {
            while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
            continue
        }
        out.append(source[index])
        index = source.index(after: index)
    }
    return out
}

#endif
