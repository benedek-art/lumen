// SliderEvidenceTests.swift
// The join nobody was making: every control the develop panels BIND, against the
// evidence that it does what it says.
//
// The owner: "verify accuracy of every slider … I don't feel like we've really gone end
// to end through every single one." This repository had more of that work done than the
// question implies — a six-part proof standard (docs/20), 135 committed records, a
// contract suite — and one structural hole that made "every" unknowable:
//
//   · `ControlIndex` is 34 NAVIGATION topics, and says so in its own header.
//   · `ProofRegistry` is 135 VERIFICATION specs.
//   · `SliderInventory` (LumenAppTests) is 97 call sites, for LAYOUT.
//   · `docs/27-slider-verification.md` is hand-maintained prose.
//
// Four enumerations of the same surface, none of which reconciles with another, so a
// slider could ship bound to a field with no proof and every lane stayed green. This is
// that reconciliation, asserted.
//
// IT FOUND THINGS ON ITS FIRST RUN, which is the argument for it existing. `docs/27` §3
// dispositions "Effects grain Amount/Size" with "Same recipe fields as `film.grain.*`
// (both panels bind `look.filmLab.grain`) — already recorded there". They do not.
// `EffectsPanel.swift:252` says so itself, in a comment written to fix an earlier version
// of the same confusion: the stock branch binds `film.grain.*` and "the creative row
// twenty lines down used the identical string for a different field". `look.grain` is
// `CreativeGrain` — amount, size AND roughness, a control `FilmGrain` does not have. So
// three image-affecting sliders were dispositioned out of the audit on a premise the
// source contradicts.
//
// WHY THIS TARGET. `ProofRegistry.all` is real code here, so a record id is checked
// against the thing that actually drives a sweep rather than against a string in a
// document. The UI side is read as text, which is this repository's idiom for a fact that
// lives in a target the reader cannot import — `DesignSystemTests`, `FrontDoorTests` and
// `EditRevisionRuleTests` all do it. And LumenCoreTests runs in `engine-linux` on every
// push, where `SliderInventory`'s macOS lane does not.
import XCTest
@testable import LumenCore

final class SliderEvidenceTests: XCTestCase {

    /// What is known about a control, in descending order of strength.
    enum Evidence {
        /// One or more `ProofRegistry` ids. The control is swept and its authority floored.
        case record([String])
        /// No sweep record, but a named assertion pins its behaviour. Weaker: a contract
        /// says the number means what the label says, not that the control has authority.
        case contract(String)
        /// Neither, with the reason. Every one of these is a debt, not an exemption.
        case disposition(String)
    }

    /// Model domains — the first segment of a control key. Everything else a panel spells
    /// with dots is an SF Symbol name (`chevron.down`, `arrow.uturn.backward`), and this
    /// list is what separates the two without a brittle symbol denylist.
    static let domains: Set<String> = [
        "bw", "cb", "color", "denoise", "detail", "film", "geometry", "look", "mask",
        "mixer", "parametric", "point", "prim", "printer", "render", "tone", "wb",
        "wheel", "wheels", "zones",
    ]

    /// Keys that are not sliders: actions, toggles, pickers, and the on-image drags.
    /// Each says what it is, because a key parked here to silence the scan is how this
    /// test becomes decoration.
    static let notASlider: [String: String] = [
        "color.reset": "section reset button",
        "detail.capture.auto": "toggle — automatic capture sharpening on/off",
        "detail.capture.auto.restore": "action — restore the automatic value",
        "detail.capture.reset": "section reset button",
        "detail.presence.reset": "section reset button",
        "detail.sharpen.classic": "toggle — classic sharpening on/off",
        "detail.sharpen.reset": "section reset button",
        "denoise.mode": "segmented picker — off/classic/AI",
        "geometry.crop.aspect": "aspect-ratio picker",
        "geometry.crop.orientation": "orientation button",
        "geometry.crop.original": "action — restore the original crop",
        "geometry.flipH": "toggle — horizontal flip",
        "geometry.lens.profile": "toggle — lens profile on/off",
        "geometry.lens.reset": "section reset button",
        "geometry.reset": "section reset button",
        "geometry.revert": "action — revert geometry",
        "look.grain.reset": "section reset button",
        "look.vignette.reset": "section reset button",
        "mask.name.*": "text field — the mask's name",
        "mask.wb.unit.*": "picker — relative or absolute white balance",
        "mixer.arc.*.*": "on-image drag — the mixer hue ring's band handles, not a slider",
        "parametric.reset": "section reset button",
        "parametric.splits": "on-image drag — the curve's region splits, not a slider",
        "tone.reset": "section reset button",
        "wb.preset": "white-balance preset picker",
        "zones.reset": "section reset button",
        "zones.pivot.*": "on-strip drag — the zone pivots; recorded as zones.pivot.0…4",
        "wheels.pivot.*": "on-strip drag — the grading pivots; recorded as grade.pivot.*",
    ]

    /// EVERY SLIDER THE DEVELOP PANELS BIND, and what is known about it.
    ///
    /// Interpolated keys are normalised to `*` — `zones.\(zone.name)` is `zones.*` — and
    /// the record list names every id that expansion produces, so a band or a zone going
    /// missing from the registry fails here rather than silently shrinking the sweep.
    static let manifest: [String: Evidence] = [
        // ── Basic: white balance, tone, presence, saturation ──────────────────────────
        "wb.temp": .record(["raw.temp"]),
        "wb.tint": .record(["raw.tint"]),
        "tone.exposure": .record(["tone.exposure"]),
        "tone.contrast": .record(["tone.contrast"]),
        "tone.contrastPivot": .record(["tone.contrastPivot"]),
        "tone.highlights": .record(["tone.highlights"]),
        "tone.shadows": .record(["tone.shadows"]),
        "tone.whites": .record(["tone.whites"]),
        "tone.blacks": .record(["tone.blacks"]),
        "detail.texture": .record(["detail.texture"]),
        "detail.clarity": .record(["detail.clarity"]),
        "detail.dehaze": .record(["detail.dehaze"]),
        "color.vibrance": .record(["color.vibrance"]),
        "color.saturation": .record(["color.saturation"]),
        "color.density": .record(["color.density"]),
        "color.protectSkin": .record(["color.protectSkin"]),

        // ── Zones ────────────────────────────────────────────────────────────────────
        "zones.*": .record(["zones.dark.ev", "zones.shadow.ev", "zones.mid.ev",
                            "zones.light.ev", "zones.bright.ev"]),
        "zones.Global": .record(["zones.global.ev"]),

        // ── Curve ────────────────────────────────────────────────────────────────────
        "parametric.highlights": .record(["curve.highlights"]),
        "parametric.lights": .record(["curve.lights"]),
        "parametric.darks": .record(["curve.darks"]),
        "parametric.shadows": .record(["curve.shadows"]),

        // ── Colour: mixer, point colour, black & white ────────────────────────────────
        "mixer.uniformity": .record(["mixer.uniformity"]),
        "mixer.*.*": .record(["mixer.red.hue", "mixer.red.sat", "mixer.red.lum",
                              "mixer.orange.hue", "mixer.orange.sat", "mixer.orange.lum",
                              "mixer.yellow.hue", "mixer.yellow.sat", "mixer.yellow.lum",
                              "mixer.green.hue", "mixer.green.sat", "mixer.green.lum",
                              "mixer.aqua.hue", "mixer.aqua.sat", "mixer.aqua.lum",
                              "mixer.blue.hue", "mixer.blue.sat", "mixer.blue.lum",
                              "mixer.purple.hue", "mixer.purple.sat", "mixer.purple.lum",
                              "mixer.magenta.hue", "mixer.magenta.sat",
                              "mixer.magenta.lum"]),
        // ColorPanel's `point.\(index).\(component)` and MaskPanel's
        // `point.\(title).\(index)` collapse to the same shape. The record covers the
        // global rows; the per-mask copies ride `mask.*`.
        "point.*.*": .record(["pointColor.hue", "pointColor.saturation",
                              "pointColor.luminance", "pointColor.range",
                              "pointColor.variance"]),
        "bw.*": .record(["bw.red", "bw.orange", "bw.yellow", "bw.green",
                         "bw.aqua", "bw.blue", "bw.purple", "bw.magenta"]),

        // ── Detail: sharpening and denoise ────────────────────────────────────────────
        "detail.sharpen.amount": .record(["sharpen.amount"]),
        "detail.sharpen.radius": .record(["sharpen.radius"]),
        "detail.sharpen.detail": .record(["sharpen.detail"]),
        "detail.sharpen.masking": .record(["sharpen.masking"]),
        "detail.sharpen.haloSuppression": .record(["sharpen.haloSuppression"]),
        "denoise.classic.luma": .record(["denoise.luma"]),
        "denoise.classic.lumaDetail": .record(["denoise.lumaDetail"]),
        "denoise.classic.lumaContrast": .record(["denoise.lumaContrast"]),
        "denoise.classic.chroma": .record(["denoise.chroma"]),
        "denoise.classic.colorDetail": .record(["denoise.colorDetail"]),
        "denoise.classic.colorSmoothness": .record(["denoise.colorSmoothness"]),
        "denoise.classic.hotPixels": .record(["denoise.hotPixels"]),
        "detail.capture.amount": .disposition(
            "docs/27 §3: LIVE but macOS-only measurable — it scales Apple's at-demosaic "
                + "sharpener inside AppleRawSource, upstream of the Linux reference path. "
                + "Owed to the gpu-parity lane."),
        "denoise.amount": .disposition(
            "docs/27 §3: AI mode drives the decoder's denoise blend, macOS-only. Mode and "
                + "amount plumbing is contract-tested in LumenCore (appleStandIn)."),

        // ── Grading, colour balance, printer lights, primaries ────────────────────────
        "wheels.blending": .record(["grade.blending"]),
        "wheels.balance": .record(["grade.balance"]),
        "wheel.*.hue": .record(["grade.global.hue", "grade.shadows.hue",
                                "grade.mid.hue", "grade.high.hue"]),
        "wheel.*.sat": .record(["grade.global.sat", "grade.shadows.sat",
                                "grade.mid.sat", "grade.high.sat"]),
        "wheel.*.lum": .record(["grade.global.lum", "grade.shadows.lum",
                                "grade.mid.lum", "grade.high.lum"]),
        "cb.hueShift": .record(["cb.hueShift"]),
        "cb.vibrance": .record(["cb.vibrance"]),
        "cb.chroma": .record(["cb.chroma.global", "cb.chroma.shadows",
                              "cb.chroma.mid", "cb.chroma.high"]),
        "cb.saturation": .record(["cb.saturation.global", "cb.saturation.shadows",
                                  "cb.saturation.mid", "cb.saturation.high"]),
        "cb.brilliance": .record(["cb.brilliance.global", "cb.brilliance.shadows",
                                  "cb.brilliance.mid", "cb.brilliance.high"]),
        "printer.*": .record(["printer.master", "printer.r", "printer.g", "printer.b"]),
        "prim.rHue": .record(["primaries.rHue"]),
        "prim.rPurity": .record(["primaries.rPurity"]),
        "prim.gHue": .record(["primaries.gHue"]),
        "prim.gPurity": .record(["primaries.gPurity"]),
        "prim.bHue": .record(["primaries.bHue"]),
        "prim.bPurity": .record(["primaries.bPurity"]),
        "prim.tintHue": .record(["primaries.tintHue"]),
        "prim.tintPurity": .record(["primaries.tintPurity"]),

        // ── Film Lab ─────────────────────────────────────────────────────────────────
        "film.amount": .record(["film.portra400.strength", "film.trix400.strength",
                                "film.velvia50.strength", "film.ektar100.strength",
                                "film.gold200.strength", "film.cine250d.strength"]),
        "film.exposure": .record(["film.exposure"]),
        "film.push": .record(["film.pushPull"]),
        "film.halation": .record(["film.halation"]),
        "film.grain.amount": .record(["film.grain.amount"]),
        "film.grain.size": .record(["film.grain.size"]),

        // ── Effects: vignette and creative grain ──────────────────────────────────────
        "look.vignette": .record(["look.vignette"]),

        // ── Crop ─────────────────────────────────────────────────────────────────────
        "geometry.angle": .disposition(
            "docs/27 §3: a geometric transform — authority in code values is the wrong "
                + "metric, since a 1° rotation moves every pixel and changes no tone. "
                + "Verified by CropGeometry tests instead."),

        // ── Masks ────────────────────────────────────────────────────────────────────
        "mask.*.*": .disposition(
            "docs/27 §3, and the owner's standing decision (global sliders only): sweeping "
                + "a masked control needs a mask-raster harness that does not exist. The "
                + "GLOBAL engines they scale are all recorded; RobustnessTests:286 drives "
                + "18 of these fields through the reference path at a 1e-4 threshold."),
        "mask.c.*.*.*": .disposition("component geometry — see mask.*.*"),
        "mask.c.amount.*.*": .disposition("component contribution — see mask.*.*"),
        "mask.reach.*.*": .disposition("similarity-line reach — see mask.*.*"),
        "mask.tint.*": .disposition("mask colorize amount — see mask.*"),


        // ── DEBTS. Sliders a photographer can drag, with no record. ───────────────────
        //
        // Each of these is a control the develop UI offers and the proof sweep has never
        // measured. They are listed as dispositions because that is what they are today,
        // and the reason field says "owed", not "exempt".
        // THE NINE THAT WERE OWED ARE PAID. Each carried an `OWED: no record`
        // disposition; each has a `ControlSpec` and a committed record now, with an
        // authority floor at about 70% of its measurement (docs/27's convention).
        //
        // These rows were stale for a while and the suite could not say so, because
        // `testEveryClaimedRecordExists` only checks that a claimed record EXISTS — it
        // never asked whether a disposition was still true. A manifest that can go out of
        // date in one direction only is the same shape as a check that cannot fail, which
        // is the thing this file was written to remove.
        // `testEveryRecordedControlIsClaimedByARecordRow` below walks the other way and
        // closes it.
        "film.halationSize": .record(["film.halationSize"]),
        "film.halationRedness": .record(["film.halationRedness"]),
        "look.vignetteFeather": .contract(
            "VignetteResponseTests.testFeatherMovesTheDeliveredStrengthTwelvefold — a "
                + "contract, not a sweep: no authority floor and no monotonicity check."),
        "look.grain.amount": .record(["look.grain.amount"]),
        "look.grain.size": .record(["look.grain.size"]),
        "look.grain.roughness": .record(["look.grain.roughness"]),
        "render.contrast": .record(["render.contrast"]),
        "render.skew": .record(["render.skew"]),
        "render.hue": .record(["render.hue"]),
        "render.black": .record(["render.black"]),
    ]

    // MARK: - The scan

    private static var panelSources: [(name: String, text: String)] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")
        let panels = ["BasicPanel", "ColorPanel", "DetailPanel", "EffectsPanel",
                      "ZonesPanel", "LookPanel", "CropPanel", "CurveEditorView",
                      "MaskPanel"]
        return panels.compactMap { name in
            let url = root.appendingPathComponent("\(name).swift")
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            // Comments blanked. The rule the sibling scans learned the hard way: prose
            // explaining a key is not the key.
            let text = raw.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    guard let s = line.range(of: "//") else { return line }
                    return line[..<s.lowerBound]
                }
                .joined(separator: "\n")
            return (name, text)
        }
    }()

    /// Every dotted string literal in a develop panel whose first segment is a model
    /// domain, with `\(…)` collapsed to `*`.
    private static var boundKeys: Set<String> = {
        var found: Set<String> = []
        for (_, text) in panelSources {
            var i = text.startIndex
            while let open = text[i...].firstIndex(of: "\"") {
                guard let close = text[text.index(after: open)...].firstIndex(of: "\"")
                else { break }
                let body = String(text[text.index(after: open)..<close])
                i = text.index(after: close)
                guard body.contains(".") else { continue }
                // Collapse interpolations: `zones.\(zone.name)` -> `zones.*`
                var collapsed = ""
                var depth = 0
                var k = body.startIndex
                while k < body.endIndex {
                    if body[k] == "\\", body.index(after: k) < body.endIndex,
                       body[body.index(after: k)] == "(" {
                        depth += 1
                        collapsed += "*"
                        k = body.index(k, offsetBy: 2)
                        continue
                    }
                    if depth > 0 {
                        if body[k] == "(" { depth += 1 }
                        if body[k] == ")" { depth -= 1 }
                        k = body.index(after: k)
                        continue
                    }
                    collapsed.append(body[k])
                    k = body.index(after: k)
                }
                // A literal ending in "." is a FRAGMENT the call site concatenates —
                // `LookPanel:1541` builds help prose with `+ "wheel."`, `MaskPanel:2995`
                // builds a key with `"wheel." + key`. Neither is a control key.
                //
                // The second of those is this scan's one honest blind spot: a key
                // assembled by concatenation is invisible to a literal scan, so the mask
                // grading wheels are covered by the `mask.*` disposition rather than by
                // being seen. Stated here rather than left for someone to discover.
                guard !collapsed.hasSuffix(".") else { continue }
                guard let domain = collapsed.split(separator: ".").first,
                      domains.contains(String(domain)) else { continue }
                found.insert(collapsed)
            }
        }
        return found
    }()

    // MARK: - The assertions

    /// A record id in the manifest must name a spec that actually exists. This is the
    /// half that could not be checked from prose: `docs/27` can claim coverage forever,
    /// `ProofRegistry.all` cannot.
    func testEveryClaimedRecordExists() {
        let real = Set(ProofRegistry.all.map(\.id))
        var missing: [String] = []
        for (key, evidence) in Self.manifest {
            guard case .record(let ids) = evidence else { continue }
            XCTAssertFalse(ids.isEmpty, "\(key) claims a record and names none")
            for id in ids where !real.contains(id) {
                missing.append("\(key) -> \(id)")
            }
        }
        XCTAssertTrue(missing.isEmpty,
                      "the manifest claims proof records that ProofRegistry does not "
                          + "have, so a control is documented as covered and is not:\n  "
                          + missing.sorted().joined(separator: "\n  "))
    }

    /// THE OTHER DIRECTION, and the reason nine rows sat stale with every lane green.
    ///
    /// `testEveryClaimedRecordExists` walks manifest → registry: a row that claims a
    /// record names a spec that exists. Nothing walked registry → manifest, so when
    /// `film.halationSize`, `film.halationRedness`, the three `look.grain.*` and the four
    /// `render.*` controls got specs and committed records, their rows went on saying
    /// `OWED: no record` and nothing anywhere could notice. A table that can only go
    /// stale in the safe direction understates what is known, which reads as modesty and
    /// behaves as a lie: `testReportsTheCoverage` printed nine debts that were paid.
    ///
    /// So: every spec in `ProofRegistry.all` is claimed by some `.record` row. A control
    /// that is swept cannot also be sitting under a disposition saying it is owed a
    /// sweep, because a disposition claims no ids and the spec would land here unclaimed.
    ///
    /// This is a stronger check than matching a manifest key against a spec id would be,
    /// and it is stronger in the direction that matters: the two enumerations do not
    /// share a naming convention — `wb.temp` is recorded as `raw.temp`, `parametric.darks`
    /// as `curve.darks`, `wheel.*.hue` as four `grade.*.hue` ids — so key-to-id matching
    /// would have missed a renamed spec entirely. Claiming is explicit, so nothing is
    /// missed and nothing is guessed.
    func testEveryRecordedControlIsClaimedByARecordRow() {
        // The on-strip drags. Each is on the not-a-slider list, because a pivot handle
        // is not a slider — and each is nonetheless SWEPT, so its spec has to be
        // accounted for here or this assertion would demand a slider row for a drag.
        // Named one by one rather than pattern-matched: `zones.pivot.*` as a glob would
        // absorb a future `zones.pivot.5` that nobody had looked at.
        let recordedDrags: Set<String> = [
            "zones.pivot.0", "zones.pivot.1", "zones.pivot.2", "zones.pivot.3",
            "zones.pivot.4", "grade.pivot.shadow", "grade.pivot.highlight",
        ]

        var claimed: Set<String> = []
        for evidence in Self.manifest.values {
            guard case .record(let ids) = evidence else { continue }
            claimed.formUnion(ids)
        }
        let recorded = Set(ProofRegistry.all.map(\.id))

        // The exception list keeps itself honest in both directions: a drag whose spec
        // has gone, or one a slider row has since claimed, fails here rather than
        // sitting on as a permanent hole in the check.
        for id in recordedDrags.sorted() {
            XCTAssertTrue(recorded.contains(id),
                          "\(id) is listed here as a recorded on-strip drag and "
                              + "ProofRegistry has no such spec any more")
            XCTAssertFalse(claimed.contains(id),
                           "\(id) is claimed by a manifest row now — take it off the "
                               + "drag list, the exception is not needed")
        }

        let unclaimed = recorded.subtracting(claimed).subtracting(recordedDrags).sorted()
        XCTAssertTrue(unclaimed.isEmpty,
                      "these controls are SWEPT — ProofRegistry drives them and a record "
                          + "is committed — and no row in the evidence manifest claims "
                          + "them, so this table is understating what is known about "
                          + "each. Add the id to the row that binds it, or to the drag "
                          + "list above if no slider does:\n  "
                          + unclaimed.joined(separator: "\n  "))
    }

    /// Every control the panels bind is accounted for — with a record, a contract, or a
    /// disposition that says why. Add a slider and this fails until you say what is
    /// known about it, which is the whole point of the file.
    func testEveryBoundControlIsAccountedFor() {
        var unaccounted: [String] = []
        for key in Self.boundKeys
        where Self.manifest[key] == nil && Self.notASlider[key] == nil {
            unaccounted.append(key)
        }
        XCTAssertTrue(unaccounted.isEmpty,
                      "these control keys are bound by a develop panel and appear in "
                          + "neither the evidence manifest nor the not-a-slider list. A "
                          + "control nobody has said anything about is the defect this "
                          + "file exists to make impossible:\n  "
                          + unaccounted.sorted().joined(separator: "\n  "))
    }

    /// And the manifest does not describe controls that no longer exist. A stale row is
    /// how a table starts lying in the safe direction.
    func testTheManifestHasNoRowsForControlsThatAreGone() {
        var orphans: [String] = []
        for key in Self.manifest.keys where !Self.boundKeys.contains(key) {
            orphans.append(key)
        }
        XCTAssertTrue(orphans.isEmpty,
                      "the manifest describes control keys no develop panel binds any "
                          + "more — delete the row or fix the key:\n  "
                          + orphans.sorted().joined(separator: "\n  "))
    }

    /// The scan must actually be finding things. A regex that quietly stops matching
    /// turns all three assertions above green, which is worse than any violation.
    func testTheScanStillSeesTheControlsItIsChecking() {
        XCTAssertGreaterThan(Self.panelSources.count, 7,
                             "only \(Self.panelSources.count) develop panels read")
        XCTAssertGreaterThan(Self.boundKeys.count, 60,
                             "only \(Self.boundKeys.count) control keys found — the scan "
                                 + "has stopped seeing the keys it checks")
        for anchor in ["tone.exposure", "mixer.uniformity", "look.vignette", "cb.hueShift"] {
            XCTAssertTrue(Self.boundKeys.contains(anchor),
                          "the scan no longer finds \(anchor), which is bound in a panel")
        }
    }

    /// Every debt is stated as a debt. A disposition whose reason is empty is an
    /// exemption wearing a reason's clothes.
    func testEveryDispositionGivesAReason() {
        for (key, evidence) in Self.manifest {
            switch evidence {
            case .record: continue
            case .contract(let note), .disposition(let note):
                XCTAssertGreaterThan(note.count, 30,
                                     "\(key)'s evidence note is too short to be a reason")
            }
        }
        for (key, note) in Self.notASlider {
            XCTAssertFalse(note.isEmpty, "\(key) is on the not-a-slider list with no reason")
        }
    }

    /// THE HEADLINE NUMBER, and it is deliberately printed rather than pinned: how much
    /// of the develop surface has a sweep behind it. A ceiling would fail on progress.
    func testReportsTheCoverage() {
        var recorded = 0, contracted = 0, owed = 0
        var debts: [String] = []
        for (key, evidence) in Self.manifest {
            switch evidence {
            case .record: recorded += 1
            case .contract: contracted += 1
            case .disposition(let note):
                if note.hasPrefix("OWED") { owed += 1; debts.append(key) }
            }
        }
        print("""
              SLIDER EVIDENCE — \(Self.manifest.count) control keys bound by the develop \
              panels
                \(recorded) with a proof record
                \(contracted) with a contract only
                \(owed) OWED a record: \(debts.sorted().joined(separator: ", "))
              """)
        XCTAssertGreaterThan(recorded, 50, "record coverage has collapsed")
    }
}
