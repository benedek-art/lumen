// The measuring instrument, and the inventory it measures.
//
// WHY THIS FILE EXISTS. Every layout check this project has ever had is a text scan —
// grep for a constant, grep for a modifier, count call sites. A text scan can tell you
// that `labelWidth` is 86. It cannot tell you that "Max strength" is 67 points wide, so
// it cannot tell you the label does not fit, so every claim in `LumenControls.swift`
// about what fits has been believed rather than checked since it was written. The
// panel audit (docs/audit-2026-09/w2/G1.md §0) says so in as many words: "No CoreText
// on this machine, so widths are estimated two ways" — and then every number downstream
// of that estimate inherits its error bars.
//
// The thing that unlocks this: `NSAttributedString.size()` and `NSFont` need no window
// server. They are CoreText, not AppKit drawing. So a macOS CI runner with no display
// can measure real type advances for real strings in the real faces the app sets, and a
// layout claim becomes an arithmetic one. That is the whole of the idea; everything
// below is bookkeeping around it.
//
// WHAT IT CANNOT DO, said up front so a green run is not read as more than it is. There
// is no view here and nothing is hosted. SwiftUI's own layout — how a `Spacer` resolves,
// what `layoutPriority` does under pressure, where a `fixedSize` wins — is not
// simulated. What is modelled is the HORIZONTAL CHAIN: a series of fixed insets and
// fixed frames, each of which is a literal in one place in one file, and every one of
// which is pinned against the source it came from, so the model cannot silently drift
// from the code it describes. Where the chain runs out — into a `Spacer`, into a
// flexible frame — this file stops and says so rather than guessing.
//
// THE PINS ARE THE POINT. A measurement suite whose constants are typed by hand into
// the test is a suite that measures its own copy of the app. The pinning test reads
// the actual source files and asserts each literal is still where and what this file
// says it is; if somebody moves the card gutter from 10 to 12, the pin fails and names
// the number to re-derive, instead of the metric tests quietly measuring a panel that
// no longer exists.

#if os(macOS)
import AppKit
import Foundation
@testable import LumenApp

// MARK: - Type

/// The four faces these measurements are taken in.
///
/// They MIRROR `LumenType.swift` rather than reading it: a SwiftUI `Font` is opaque —
/// there is no way to ask it for its point size — so the bridge from `.lumenBody` to
/// `NSFont` has to be written out. That is exactly the kind of duplicate constant this
/// project keeps finding at the moment it stops agreeing, so the type-scale pinning
/// test asserts every one of these against the token it stands for.
enum LayoutFont {

    /// `.lumenBody` — control labels, button text, list rows. LumenType.swift.
    static let body = NSFont.systemFont(ofSize: 11, weight: .regular)

    /// `.lumenCaption` — captions, chips, segmented labels, badges. Also the app's own
    /// stated legibility floor: "10 is the floor" (LumenType.swift).
    static let caption = NSFont.systemFont(ofSize: 10, weight: .regular)

    /// `.lumenHeading` — section headers, mixed case.
    static let heading = NSFont.systemFont(ofSize: 12, weight: .semibold)

    /// `.lumenNumeric` — every readout at rest. Tabular figures on the body face, which
    /// is what `.monospacedDigit()` produces.
    static let numeric = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// `.lumenNumericStrong` — the readout WHILE IT IS BEING SCRUBBED. The wider of the
    /// two states and therefore the one a column has to be sized against; measuring only
    /// the resting weight is how a readout that clips under the pointer ships green.
    static let numericStrong = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    /// The app's own minimum rendered size, from `LumenType.swift`: "10 is the floor.
    /// There were 46 sites at 9pt in a build whose own design audit had already set 10
    /// as the minimum and never enforced it." A label that fits only by shrinking past
    /// this has not fitted.
    static let legibilityFloor: CGFloat = 10
}

// MARK: - Measurement

enum TextMetric {

    /// One string's rendered advance width, in points.
    ///
    /// `NSAttributedString.size()` is the whole instrument. It is CoreText underneath —
    /// no window, no display, no run loop — which is why this works on a headless
    /// runner and why the estimate-two-ways method the panel audit had to use is
    /// retired by it.
    static func width(_ string: String, _ font: NSFont) -> CGFloat {
        NSAttributedString(string: string, attributes: [.font: font]).size().width
    }

    /// An SF Symbol's drawn width at a given point size, for the rows that put a glyph
    /// beside a word inside a fixed budget.
    ///
    /// SF Symbols are not a fixed-width family — `crop` is nearly square and
    /// `point.topleft.down.to.point.bottomright.curvepath` is half again as wide — so a
    /// single constant for "an icon" is wrong by a factor the rows it prices can feel.
    /// Nil rather than a guess when the symbol does not resolve: a caller that cannot
    /// measure a glyph should say so, not average one in.
    static func symbolWidth(_ name: String, pointSize: CGFloat,
                            weight: NSFont.Weight = .regular) -> CGFloat? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil),
              let sized = image.withSymbolConfiguration(
                .init(pointSize: pointSize, weight: weight))
        else { return nil }
        let w = sized.size.width
        return w.isFinite && w > 0 ? w : nil
    }

    /// What a `.frame(width:).lineLimit(1).minimumScaleFactor(f)` pair actually does to a
    /// string that does not fit, expressed as the two questions a reader asks about it.
    ///
    /// SwiftUI shrinks the type until it fits or until it hits the floor, and then
    /// TRUNCATES. So "does it fit" has two answers and they are different defects: type
    /// that has quietly gone smaller than its neighbours, and a name with its tail eaten.
    struct Fit {
        let nominal: CGFloat
        let budget: CGFloat
        let scaleFloor: CGFloat
        /// The size the string ends up rendered at, in points, given the nominal font size.
        let renderedSize: CGFloat
        /// True when even the smallest permitted size is too wide: the tail is cut.
        let truncates: Bool
        /// True when it fits only by rendering smaller than nominal.
        let shrinks: Bool
    }

    static func fit(_ string: String, _ font: NSFont,
                    budget: CGFloat, minimumScaleFactor: CGFloat) -> Fit {
        let nominal = width(string, font)
        let scale = nominal <= budget ? 1 : max(budget / nominal, minimumScaleFactor)
        return Fit(nominal: nominal,
                   budget: budget,
                   scaleFloor: minimumScaleFactor,
                   renderedSize: font.pointSize * scale,
                   truncates: nominal * minimumScaleFactor > budget,
                   shrinks: nominal > budget)
    }
}

// MARK: - The horizontal chain

/// Every inset between the edge of a host and the edge of a slider's track, and the
/// fixed chrome the slider row spends before the groove starts.
///
/// Each number below is one literal in one file, and the pinning test holds it there.
enum PanelChain {

    // The develop column, outside in.

    /// `DevelopPanel.swift` — the scroll view's content inset, each side.
    static let scrollInset: CGFloat = 4
    /// `DevelopColumn.swift` — `WorkspaceSectionView`'s card gutter, each side. This is
    /// the one the accordion added on the owner's third review, and its own comment
    /// prices it: "It costs the track 12 points."
    static let cardInset: CGFloat = 10
    /// `DevelopPanel.swift` — what a `DevelopDisclosure` costs the rows inside it, each
    /// side. **Zero, and that is the point of this entry rather than an omission.**
    ///
    /// It has been all three of its possible values. `.leading` alone was G1-07: the
    /// fold's rows started 8 pt right of their neighbours while the value column stayed
    /// put. `.horizontal` squared the read and doubled the price — 16 pt off every row
    /// in a fold, which at the 380 default put a ±100 control inside one at 0.93 pt per
    /// unit against 1.010 outside, i.e. the section that folds was the section that lost
    /// the floor `defaultPanelWidth` exists to buy. The depth now sits on the fold's
    /// HEADER instead, so the sub-heading is still one level in and every groove in the
    /// column starts at the same x.
    ///
    /// Kept as a named zero rather than deleted, and kept pinned: it is the term that
    /// says a fold's track equals a top-level track, and a term deleted from a chain is
    /// a term nobody notices coming back.
    static let disclosureInset: CGFloat = 0

    /// The floating Masks pop-out — a fixed-width host, so the column's resize does
    /// nothing for it and every number below is the only number it ever has.
    static let maskPanelWidth: CGFloat = 272
    /// `MaskFloatingPanel.swift` — the content's own gutter, each side.
    static let maskPanelContentInset: CGFloat = 10
    /// `MaskPanel.swift` — `maskDetail`'s indent and its trailing partner.
    static let maskDetailLeading: CGFloat = 12
    static let maskDetailTrailing: CGFloat = 2
    /// `MaskPanel.swift` — `componentEditor`'s extra leading indent.
    static let maskComponentLeading: CGFloat = 6

    /// The export sheet is a fixed 800x640 with a 244-point recipe list, one divider,
    /// and 14 points of gutter each side of the editor.
    static let exportSheetWidth: CGFloat = 800
    static let exportRecipeColumn: CGFloat = 244
    static let exportEditorInset: CGFloat = 14
    static let dividerWidth: CGFloat = 1

    /// The lightness bar under a grading wheel, in `LookPanel`'s single large wheel.
    ///
    /// `LumenColorWheel` centres it on the wheel by paying a counterweight equal to the
    /// readout column — `.padding(.leading, valueWidth + 6)` inside a
    /// `diameter + 2 × (valueWidth + 6)` frame — which means the groove comes out
    /// exactly as wide as the wheel is, by construction rather than by eye. 150 is the
    /// diameter `LookPanel.swift:693` asks for.
    static let gradeWheelDiameter: CGFloat = 150
    /// The same bar in the mask panel's compact four-up, which cannot pay the
    /// counterweight (two captioned bars would overrun a 272 pt column), so the row sits
    /// in a bare `diameter + 40` frame at the default 68 pt wheel.
    static let maskWheelBarWidth: CGFloat = 68 + 40

    /// What a `LumenSlider` row spends before the groove: the label frame, the two 6 pt
    /// gaps of its `HStack(spacing: 6)`, and the readout's frame.
    ///
    /// Read from the app's own constants rather than restated, because these two are the
    /// numbers under argument — `valueWidth` went 44 -> 52 for the readout pill and the
    /// eight points came out of every track in the application.
    static let rowGap: CGFloat = 6
    static var sliderChrome: CGFloat { Lumen.labelWidth + rowGap + rowGap + Lumen.valueWidth }

    /// What an UNTITLED row spends, which is not the same thing and is why this exists.
    ///
    /// `LumenSlider`'s body opens `if !title.isEmpty`, so a row with no name reserves no
    /// label column AND loses one of the two gaps — the `HStack(spacing: 6)` has two
    /// children instead of three. The file says why in as many words at that branch: the
    /// wheels' lightness bar is a slider with an empty title inside a 108-point column,
    /// and charging it the full 150 points of chrome "asked for 158 points of a
    /// 108-point row and left the track squeezed to nothing". A model that charged it
    /// anyway would report a negative track and call the row broken for the wrong reason.
    static var untitledSliderChrome: CGFloat { rowGap + Lumen.valueWidth }

    /// The readout's own padding, inside its 52 pt frame, so the digits get less than
    /// the column is wide.
    static let valuePadding: CGFloat = 5
    static var valueTextWidth: CGFloat { Lumen.valueWidth - 2 * valuePadding }

    /// The label column's budget for a NAME once a behaviour glyph is drawn beside it.
    ///
    /// `LumenControls.swift` states the claim this buys in one sentence — "At
    /// `inRowWidth` the name keeps 56 and every label in the app fits" — and that
    /// sentence is what `testEveryGlyphBearingLabelFitsTheFiftySixPointBudget` checks.
    static var glyphLabelBudget: CGFloat {
        Lumen.labelWidth - LumenBehaviourGlyph.inRowWidth - 4
    }

    /// An `indented: true` row pays for its subordination out of its own name, via a
    /// leading pad INSIDE the label frame.
    static let labelIndent: CGFloat = 12

    /// The shrink floor `LumenSlider` and `LumenMenuPicker` both apply to a label.
    static let labelScaleFloor: CGFloat = 0.86

    /// Where a slider lives, since the column is not the only host and the other hosts
    /// do not resize.
    enum Host: String, CaseIterable {
        /// A section card in the develop column, at the top level of it.
        case developTop
        /// Inside a `DevelopDisclosure` in that card — Zones, Noise Reduction.
        case developDisclosure
        /// The floating Masks pop-out, at `maskDetail` depth — Brush, Edge.
        case maskDetail
        /// The same pop-out, one indent deeper — a component's own parameters.
        case maskComponent
        /// The export sheet's editor column.
        case exportSheet
        /// The lightness bar under the grade's single large wheel — a fixed frame built
        /// from the wheel's own diameter, not from any column.
        case gradeWheelBar
        /// The same bar under one of the mask panel's four-up wheels.
        case maskWheelBar

        /// True for the hosts whose width follows the develop column's drag handle.
        var resizes: Bool { self == .developTop || self == .developDisclosure }

        /// True for the hosts whose rows carry a name.
        ///
        /// The wheels' lightness bar is the app's one untitled slider and it pays
        /// `untitledSliderChrome` instead, so `trackWidth` below — which assumes a label
        /// column and both gaps — does not describe it and would report a 108-point host
        /// as having −42 points of track. Ask `SliderSpec.trackWidth`, which knows the
        /// title, for any row's actual groove.
        var rowsAreTitled: Bool { self != .gradeWheelBar && self != .maskWheelBar }

        /// The width available to a row's content, given the develop column's width.
        func contentWidth(columnWidth: CGFloat) -> CGFloat {
            switch self {
            case .developTop:
                return columnWidth - 2 * scrollInset - 2 * cardInset
            case .developDisclosure:
                return columnWidth - 2 * scrollInset - 2 * cardInset - 2 * disclosureInset
            case .maskDetail:
                return maskPanelWidth - 2 * maskPanelContentInset
                    - maskDetailLeading - maskDetailTrailing
            case .maskComponent:
                return maskPanelWidth - 2 * maskPanelContentInset
                    - maskDetailLeading - maskDetailTrailing - maskComponentLeading
            case .exportSheet:
                return exportSheetWidth - exportRecipeColumn - dividerWidth
                    - 2 * exportEditorInset
            case .gradeWheelBar:
                // `diameter + 2 × (valueWidth + rowGap)` of frame, less the leading
                // counterweight of `valueWidth + rowGap` that centres it.
                return gradeWheelDiameter + Lumen.valueWidth + rowGap
            case .maskWheelBar:
                return maskWheelBarWidth
            }
        }

        /// The drag track's own width for a TITLED row — what is left of the row after
        /// the label, the two gaps and the readout. Meaningless where `rowsAreTitled` is
        /// false; `SliderSpec.trackWidth` is the one to ask about a particular row.
        func trackWidth(columnWidth: CGFloat) -> CGFloat {
            contentWidth(columnWidth: columnWidth) - sliderChrome
        }
    }
}

// MARK: - The slider inventory

/// One shipped slider, as the numbers a drag is resolved against.
///
/// `range` is the SOFT range — where dragging pins — because that is what a track's
/// width is divided by. `hardRange` is where typing is still accepted, and it is what
/// the readout has to be wide enough for: a value only reachable by typing still has to
/// be readable once it is there.
struct SliderSpec {
    let title: String
    /// `File.swift:line` of the call site, so a failure names the row to fix.
    let site: String
    let host: PanelChain.Host
    let range: ClosedRange<Double>
    let hardRange: ClosedRange<Double>?
    let step: Double
    let decimals: Int
    /// `indented: true` — the label pays 12 pt out of its own frame.
    let indented: Bool
    /// Non-nil `behaviour:` — the label pays 30 pt out of its own frame for the glyph.
    let hasGlyph: Bool

    init(_ title: String, _ site: String, _ host: PanelChain.Host,
         _ range: ClosedRange<Double>, hard: ClosedRange<Double>? = nil,
         step: Double, decimals: Int = 0,
         indented: Bool = false, glyph: Bool = false) {
        self.title = title
        self.site = site
        self.host = host
        self.range = range
        self.hardRange = hard
        self.step = step
        self.decimals = decimals
        self.indented = indented
        self.hasGlyph = glyph
    }

    /// How many distinct values a drag can land on, which is what "precision" is
    /// denominated in. `SliderTrack.resolve` clamps then snaps to `step`, so the
    /// reachable set is the steps across the soft range and nothing between them.
    var addressableSteps: Double { ((range.upperBound - range.lowerBound) / step).rounded() }

    /// An untitled row is charged untitled chrome. See `PanelChain.untitledSliderChrome`
    /// — the label column and one of the two gaps are not drawn at all when the title is
    /// empty, and charging them anyway makes the wheels' lightness bar look like a
    /// negative-width control instead of a 150-point one.
    func trackWidth(columnWidth: CGFloat) -> CGFloat {
        host.contentWidth(columnWidth: columnWidth)
            - (title.isEmpty ? PanelChain.untitledSliderChrome : PanelChain.sliderChrome)
    }

    /// The measurement the whole of finding G1-02 is about: how far the pointer travels
    /// for one step of the value.
    func pointsPerStep(columnWidth: CGFloat) -> Double {
        Double(trackWidth(columnWidth: columnWidth)) / addressableSteps
    }

    /// The label column this row's name has to fit inside.
    var labelBudget: CGFloat {
        if hasGlyph { return PanelChain.glyphLabelBudget }
        return indented ? Lumen.labelWidth - PanelChain.labelIndent : Lumen.labelWidth
    }

    /// Every string this row's formatter can produce at the ends of the range it accepts.
    ///
    /// The HARD range, not the soft one, and both ends of it: `LumenSlider.formatted` is
    /// `String(format: "%.<decimals>f", value)`, so the sign is part of the string and a
    /// row whose hard range reaches −10 has to hold `-10.00` even though dragging pins
    /// at −5. Only signed where the range is actually signed — measuring `-50000` for a
    /// Kelvin control that never goes negative inflates the column by a whole glyph.
    var widestReadout: String {
        let bounds = hardRange ?? range
        let candidates = [String(format: "%.\(decimals)f", bounds.lowerBound),
                          String(format: "%.\(decimals)f", bounds.upperBound)]
        return candidates.max { TextMetric.width($0, LayoutFont.numericStrong)
                                < TextMetric.width($1, LayoutFont.numericStrong) } ?? ""
    }
}

// MARK: - The table

enum SliderInventory {

    /// How many `LumenSlider(` call sites exist in `Sources/LumenApp`.
    ///
    /// The table below is written out rather than parsed, because a test that derives
    /// its expectations from the code it is testing proves only that the code agrees
    /// with itself. The cost of writing it out is that it goes stale, so
    /// `testTheInventoryCoversEveryShippedSlider` counts the call sites in the sources
    /// and fails when this number and that count disagree — add a slider without adding
    /// it here and the suite says so.
    ///
    /// It said 96 against a tree holding 97, and the tripwire did its job: the one it
    /// could not find was `LumenColorWheel`'s lightness bar, the app's only untitled
    /// slider and the only one written inside the control kit rather than at a panel's
    /// call site. Both of its geometries are in the table below now.
    static let callSiteCount = 97

    /// Every slider the app ships, resolved through its builder where the call site is
    /// a helper rather than a literal — `MaskPanel.adjustSlider`, `LookPanel.bipolarSlider`,
    /// `CurveEditorView.parametricSlider`, `ZonesPanel`'s register — and reduced to the
    /// distinct (title, host, range, step) rows those builders produce.
    ///
    /// Two entries carry a note rather than a literal title: `ColorPanel:696` takes
    /// `ColorEngine.bandNames[i]` and `ZonesPanel:106` takes the zone register's name, so
    /// the WIDEST member of each list stands for the row.
    static let all: [SliderSpec] = [
        // Basic — white balance and tone.
        // 50 K rather than 10: at 10 the row advertised 4,800 values and the best of the
        // four gestures could land on 0.355 pt of one. See the step's own note at the
        // call site. `MaskPanel.swift:2391` is the same control and still carries 10.
        SliderSpec("Temp", "BasicPanel.swift:222", .developTop, 2000...50000,
                   hard: 2000...50000, step: 50),
        SliderSpec("Tint", "BasicPanel.swift:275", .developTop, -150...150,
                   hard: -300...300, step: 1),
        SliderSpec("Exposure", "BasicPanel.swift:467", .developTop, -5...5,
                   hard: -10...10, step: 0.01, decimals: 2),
        SliderSpec("Contrast", "BasicPanel.swift:476", .developTop, -100...100, step: 1),
        SliderSpec("Pivot", "BasicPanel.swift:490", .developTop, -4...4,
                   step: 0.01, decimals: 2),
        SliderSpec("Highlights", "BasicPanel.swift:522", .developTop, -100...100, step: 1),
        SliderSpec("Shadows", "BasicPanel.swift:529", .developTop, -100...100, step: 1),
        SliderSpec("Whites", "BasicPanel.swift:536", .developTop, -100...100, step: 1),
        SliderSpec("Blacks", "BasicPanel.swift:544", .developTop, -100...100, step: 1),
        SliderSpec("Texture", "BasicPanel.swift:566", .developTop, -100...100, step: 1),
        SliderSpec("Clarity", "BasicPanel.swift:582", .developTop, -100...100, step: 1),
        SliderSpec("Dehaze", "BasicPanel.swift:589", .developTop, -100...100, step: 1),
        SliderSpec("Vibrance", "BasicPanel.swift:662", .developTop, -100...100, step: 1),
        SliderSpec("Saturation", "BasicPanel.swift:669", .developTop, -100...100, step: 1),
        SliderSpec("Density", "BasicPanel.swift:682", .developTop, 0...100, step: 1),
        SliderSpec("Protect Skin", "BasicPanel.swift:693", .developTop, 0...100, step: 1),

        // Colour — mixer, point colour, black and white.
        SliderSpec("Hue", "ColorPanel.swift:162", .developTop, -100...100, step: 1),
        SliderSpec("Saturation", "ColorPanel.swift:168", .developTop, -100...100, step: 1),
        SliderSpec("Luminance", "ColorPanel.swift:173", .developTop, -100...100, step: 1),
        SliderSpec("Even out hues", "ColorPanel.swift:206", .developTop, 0...100, step: 1),
        SliderSpec("Hue", "ColorPanel.swift:430", .developTop, -60...60, step: 1),
        SliderSpec("Saturation", "ColorPanel.swift:435", .developTop, -100...100, step: 1),
        SliderSpec("Luminance", "ColorPanel.swift:439", .developTop, -100...100, step: 1),
        SliderSpec("Range", "ColorPanel.swift:443", .developTop, 0...100, step: 1),
        SliderSpec("Variance", "ColorPanel.swift:449", .developTop, -100...100, step: 1),
        // `ColorEngine.bandNames` — Magenta is the widest of the eight.
        SliderSpec("Magenta", "ColorPanel.swift:696", .developTop, -100...100, step: 1),

        // Crop.
        SliderSpec("Angle", "CropPanel.swift:356", .developTop, -45...45,
                   step: 0.1, decimals: 1),

        // Curve — the four parametric regions, all one shape.
        SliderSpec("Highlights", "CurveEditorView.swift:427", .developTop, -100...100, step: 1),
        SliderSpec("Lights", "CurveEditorView.swift:432", .developTop, -100...100, step: 1),
        SliderSpec("Darks", "CurveEditorView.swift:436", .developTop, -100...100, step: 1),
        SliderSpec("Shadows", "CurveEditorView.swift:440", .developTop, -100...100, step: 1),

        // Detail — capture sharpening, manual sharpening.
        SliderSpec("Amount", "DetailPanel.swift:213", .developTop, 0...150, step: 1),
        SliderSpec("Amount", "DetailPanel.swift:296", .developTop, 0...150, step: 1),
        SliderSpec("Radius", "DetailPanel.swift:317", .developTop, 0.5...3.0,
                   step: 0.1, decimals: 1),
        SliderSpec("Detail", "DetailPanel.swift:326", .developTop, 0...100, step: 1),
        SliderSpec("Masking", "DetailPanel.swift:335", .developTop, 0...100, step: 1),
        SliderSpec("Halo Damping", "DetailPanel.swift:375", .developTop, 0...100, step: 1),
        // Noise Reduction — all of it inside a `DevelopDisclosure`.
        SliderSpec("Luminance", "DetailPanel.swift:504", .developDisclosure, 0...100, step: 1),
        SliderSpec("Detail", "DetailPanel.swift:554", .developDisclosure, 0...100,
                   step: 1, indented: true),
        SliderSpec("Contrast", "DetailPanel.swift:563", .developDisclosure, 0...100,
                   step: 1, indented: true),
        SliderSpec("Colour", "DetailPanel.swift:572", .developDisclosure, 0...100, step: 1),
        SliderSpec("Detail", "DetailPanel.swift:593", .developDisclosure, 0...100,
                   step: 1, indented: true),
        SliderSpec("Smoothness", "DetailPanel.swift:603", .developDisclosure, 0...100,
                   step: 1, indented: true),
        SliderSpec("Hot Pixels", "DetailPanel.swift:613", .developDisclosure, 0...100, step: 1),
        SliderSpec("Amount", "DetailPanel.swift:640", .developDisclosure, 0...100, step: 1),

        // Effects — vignette, grain, retouch.
        SliderSpec("Amount", "EffectsPanel.swift:131", .developTop, -4...2,
                   step: 0.01, decimals: 2),
        SliderSpec("Feather", "EffectsPanel.swift:154", .developTop, 0...100, step: 1),
        SliderSpec("Amount", "EffectsPanel.swift:263", .developTop, 0...100, step: 1),
        SliderSpec("Size", "EffectsPanel.swift:287", .developTop, 0.5...2.0,
                   step: 0.05, decimals: 2),
        SliderSpec("Amount", "EffectsPanel.swift:311", .developTop, 0...100, step: 1),
        SliderSpec("Size", "EffectsPanel.swift:322", .developTop, 0...100, step: 1),
        SliderSpec("Roughness", "EffectsPanel.swift:333", .developTop, 0...100, step: 1),

        // Export sheet — a fixed-width host, so no resize can rescue it.
        SliderSpec("Quality", "ExportSheet.swift:430", .exportSheet, 0...100, step: 1),
        SliderSpec("Megapixels", "ExportSheet.swift:575", .exportSheet, 0.5...100,
                   hard: 0.1...500, step: 0.5, decimals: 1),
        SliderSpec("Pixels", "ExportSheet.swift:579", .exportSheet, 320...8000,
                   hard: 16...30000, step: 8),
        SliderSpec("Resolution", "ExportSheet.swift:587", .exportSheet, 72...600,
                   hard: 1...2400, step: 1),
        SliderSpec("Opacity", "ExportSheet.swift:766", .exportSheet, 0...100, step: 1),
        SliderSpec("Size", "ExportSheet.swift:769", .exportSheet, 0.5...20,
                   step: 0.1, decimals: 1),
        SliderSpec("Inset", "ExportSheet.swift:772", .exportSheet, 0...20,
                   step: 0.1, decimals: 1),
        SliderSpec("Headroom", "ExportSheet.swift:814", .exportSheet, 0.5...4,
                   step: 0.1, decimals: 1),

        // Look — grade, primaries, transform, film lab, grain.
        SliderSpec("Blending", "LookPanel.swift:583", .developTop, 0...100, step: 1),
        SliderSpec("Balance", "LookPanel.swift:589", .developTop, -100...100, step: 1),
        SliderSpec("Hue shift", "LookPanel.swift:645", .developTop, -180...180, step: 1),
        SliderSpec("Vibrance", "LookPanel.swift:652", .developTop, -100...100, step: 1),
        SliderSpec("Global", "LookPanel.swift:740", .developTop, -100...100, step: 1),
        SliderSpec("Shadows", "LookPanel.swift:744", .developTop, -100...100, step: 1),
        SliderSpec("Midtones", "LookPanel.swift:748", .developTop, -100...100, step: 1),
        SliderSpec("Highlights", "LookPanel.swift:752", .developTop, -100...100, step: 1),
        SliderSpec("Red Hue", "LookPanel.swift:944", .developTop, -100...100, step: 1),
        SliderSpec("Red Purity", "LookPanel.swift:946", .developTop, -100...100, step: 1),
        SliderSpec("Green Hue", "LookPanel.swift:948", .developTop, -100...100, step: 1),
        SliderSpec("Green Purity", "LookPanel.swift:950", .developTop, -100...100, step: 1),
        SliderSpec("Blue Hue", "LookPanel.swift:952", .developTop, -100...100, step: 1),
        SliderSpec("Blue Purity", "LookPanel.swift:954", .developTop, -100...100, step: 1),
        SliderSpec("Shadow Tint", "LookPanel.swift:956", .developTop, -100...100, step: 1),
        SliderSpec("Tint Purity", "LookPanel.swift:958", .developTop, -100...100, step: 1),
        SliderSpec("Contrast", "LookPanel.swift:1077", .developTop, 0.1...10,
                   step: 0.05, decimals: 2),
        SliderSpec("Skew", "LookPanel.swift:1086", .developTop, -1...1,
                   step: 0.01, decimals: 2),
        SliderSpec("Hue keep", "LookPanel.swift:1095", .developTop, 0...100, step: 1),
        SliderSpec("Black target", "LookPanel.swift:1104", .developTop, 0...9,
                   hard: 0...15, step: 0.001, decimals: 3),
        SliderSpec("Strength", "LookPanel.swift:1209", .developTop, 0...100, step: 1),
        SliderSpec("Film Exposure", "LookPanel.swift:1215", .developTop, -2...3,
                   step: 0.25, decimals: 2),
        SliderSpec("Push / Pull", "LookPanel.swift:1220", .developTop, -1...2,
                   step: 0.25, decimals: 2),
        SliderSpec("Halation", "LookPanel.swift:1225", .developTop, 0...100, step: 1),
        SliderSpec("Halo Size", "LookPanel.swift:1240", .developTop, 0.5...2.0,
                   step: 0.05, decimals: 2, indented: true),
        SliderSpec("Halo Redness", "LookPanel.swift:1256", .developTop, 0...100,
                   step: 1, indented: true),
        SliderSpec("Grain", "LookPanel.swift:1280", .developTop, 0...100, step: 1),
        SliderSpec("Grain size", "LookPanel.swift:1287", .developTop, 0.5...2.0,
                   step: 0.05, decimals: 2),

        // Masks — the develop column half: what the mask DOES.
        SliderSpec("Strength", "MaskPanel.swift:305", .developTop, 0...200, step: 1),
        SliderSpec("Exposure", "MaskPanel.swift:1724", .developTop, -4...4,
                   step: 0.05, decimals: 2),
        SliderSpec("Contrast", "MaskPanel.swift:1725", .developTop, -100...100, step: 1),
        SliderSpec("Highlights", "MaskPanel.swift:1726", .developTop, -100...100, step: 1),
        SliderSpec("Shadows", "MaskPanel.swift:1727", .developTop, -100...100, step: 1),
        SliderSpec("Whites", "MaskPanel.swift:1728", .developTop, -100...100, step: 1),
        SliderSpec("Blacks", "MaskPanel.swift:1729", .developTop, -100...100, step: 1),
        SliderSpec("Hue", "MaskPanel.swift:1762", .developTop, -180...180, step: 1),
        SliderSpec("Saturation", "MaskPanel.swift:1763", .developTop, -100...100, step: 1),
        SliderSpec("Vibrance", "MaskPanel.swift:1764", .developTop, -100...100, step: 1),
        SliderSpec("Colorize amount", "MaskPanel.swift:1782", .developTop, 0...100, step: 1),
        SliderSpec("Hue", "MaskPanel.swift:1890", .developTop, -60...60, step: 1),
        SliderSpec("Saturation", "MaskPanel.swift:1892", .developTop, -100...100, step: 1),
        SliderSpec("Luminance", "MaskPanel.swift:1894", .developTop, -100...100, step: 1),
        SliderSpec("Range", "MaskPanel.swift:1896", .developTop, 0...100, step: 1),
        SliderSpec("Variance", "MaskPanel.swift:1898", .developTop, -100...100, step: 1),
        SliderSpec("Texture", "MaskPanel.swift:1915", .developTop, -100...100, step: 1),
        SliderSpec("Clarity", "MaskPanel.swift:1916", .developTop, -100...100, step: 1),
        SliderSpec("Dehaze", "MaskPanel.swift:1917", .developTop, -100...100, step: 1),
        SliderSpec("Sharpness", "MaskPanel.swift:1920", .developTop, -100...100, step: 1),
        SliderSpec("Temp", "MaskPanel.swift:2832", .developTop, 2000...50000, step: 50),
        SliderSpec("Tint", "MaskPanel.swift:2394", .developTop, -150...150, step: 1),
        SliderSpec("Temp", "MaskPanel.swift:2397", .developTop, -100...100, step: 1),
        SliderSpec("Tint", "MaskPanel.swift:2398", .developTop, -100...100, step: 1),

        // Masks — the floating pop-out: what the mask IS. A 272 pt host that never resizes.
        SliderSpec("Contribution", "MaskPanel.swift:1158", .maskComponent, 0...100, step: 1),
        SliderSpec("Feather", "MaskPanel.swift:1228", .maskComponent, 0...100,
                   step: 1, glyph: true),
        SliderSpec("Rotation", "MaskPanel.swift:1233", .maskComponent, -90...90, step: 1),
        SliderSpec("From", "MaskPanel.swift:1243", .maskComponent, -10...4,
                   step: 0.1, decimals: 1),
        SliderSpec("To", "MaskPanel.swift:1244", .maskComponent, -10...4,
                   step: 0.1, decimals: 1),
        SliderSpec("Smooth", "MaskPanel.swift:1556", .maskComponent, 0...100,
                   step: 1, glyph: true),
        SliderSpec("Feather", "MaskPanel.swift:1250", .maskComponent, 0...100,
                   step: 1, glyph: true),
        SliderSpec("Level", "MaskPanel.swift:1262", .maskComponent, 1...5,
                   step: 0.1, decimals: 1, glyph: true),
        SliderSpec("Near", "MaskPanel.swift:1275", .maskComponent, 0...1,
                   step: 0.01, decimals: 2),
        SliderSpec("Far", "MaskPanel.swift:1276", .maskComponent, 0...1,
                   step: 0.01, decimals: 2),
        SliderSpec("Smooth", "MaskPanel.swift:1600", .maskComponent, 0...100, step: 1),
        SliderSpec("Tolerance", "MaskPanel.swift:1286", .maskComponent, 0...100, step: 1),
        SliderSpec("Reach", "MaskPanel.swift:1482", .maskComponent, 1...100, step: 1),
        SliderSpec("Colour", "MaskPanel.swift:1855", .maskComponent, 0...100, step: 1),
        SliderSpec("Brightness", "MaskPanel.swift:1859", .maskComponent,
                   0...100, step: 1),
        SliderSpec("Size", "MaskPanel.swift:1330", .maskDetail, 0.002...0.5,
                   step: 0.002, decimals: 3, glyph: true),
        SliderSpec("Feather", "MaskPanel.swift:1338", .maskDetail, 0...100,
                   step: 1, glyph: true),
        SliderSpec("Flow", "MaskPanel.swift:1344", .maskDetail, 1...100, step: 1, glyph: true),
        SliderSpec("Ceiling", "MaskPanel.swift:1686", .maskDetail, 0...100,
                   step: 1, glyph: true),
        SliderSpec("Steadiness", "MaskPanel.swift:1359", .maskDetail, 0...100, step: 1),
        SliderSpec("Follow", "MaskPanel.swift:1645", .maskDetail, 0...100, step: 1, glyph: true),
        SliderSpec("Expand", "MaskPanel.swift:1657", .maskDetail, -50...50,
                   step: 1, glyph: true),
        SliderSpec("Soften", "MaskPanel.swift:1676", .maskDetail, 0...100, step: 1, glyph: true),
        SliderSpec("Ramp from", "MaskPanel.swift:1685", .maskDetail, 0...100, step: 1),
        SliderSpec("Ramp to", "MaskPanel.swift:1686", .maskDetail, 0...100, step: 1),
        SliderSpec("Ramp shape", "MaskPanel.swift:1687", .maskDetail, 0.2...5,
                   step: 0.05, decimals: 2),

        // The grading wheels' lightness bar — one call site, two geometries, and the
        // slider this table did not have.
        //
        // It is the app's only UNTITLED `LumenSlider`, which is exactly why it was
        // missing: it is not written at a panel's call site but inside `LumenColorWheel`,
        // it carries no name to search the panels for, and every label check in this
        // suite already filters empty titles out. An unmeasured control is the one that
        // ships broken, and this one is the app's narrowest track by a wide margin —
        // `MaskPanel`'s four-up gets 50 points for 200 steps, a quarter of a point each.
        SliderSpec("", "LumenControls.swift:1943 (LookPanel.swift:693)", .gradeWheelBar,
                   -1...1, step: 0.01, decimals: 2),
        SliderSpec("", "LumenControls.swift:1943 (MaskPanel.swift:2840)", .maskWheelBar,
                   -1...1, step: 0.01, decimals: 2),

        // Zones — five named stops plus the global trim, inside a `DevelopDisclosure`.
        // "Midtones" is the widest of the six names.
        SliderSpec("Midtones", "ZonesPanel.swift:106", .developDisclosure, -3...3,
                   hard: -5...5, step: 0.01, decimals: 2),
        SliderSpec("Global", "ZonesPanel.swift:135", .developDisclosure, -3...3,
                   hard: -5...5, step: 0.01, decimals: 2),
    ]
}

// MARK: - Two gestures, not one

/// What the app offers a photographer who wants to land on a particular value.
///
/// The slider contract at the top of `LumenControls.swift` is explicit that there are
/// two instruments, not one: "drag the NUMBER to scrub it — three track-widths of travel
/// per full range, so the readout is the precision instrument and the track is the
/// coarse one." A precision claim about the track alone is therefore only half the
/// question, and the honest one is whether ANY gesture can reach every value the readout
/// advertises.
enum SliderGesture: CaseIterable {
    case coarseTrack, fineTrack, coarseScrub, fineScrub

    /// The scrub's fixed travel, from `LumenSlider.scrubTrack`. It does not vary with
    /// the panel's width — the readout is the same size at 320 as at 520 — which is why
    /// it is the floor under a narrow column rather than another casualty of one.
    static let scrubTravel: CGFloat = 426

    /// ⇧ divides the travel by four (`FineDrag.scale`), which multiplies the precision
    /// by four.
    static let fineScale: Double = 0.25

    func travel(trackWidth: CGFloat) -> Double {
        switch self {
        case .coarseTrack: return Double(trackWidth)
        case .fineTrack: return Double(trackWidth) / SliderGesture.fineScale
        case .coarseScrub: return Double(SliderGesture.scrubTravel)
        case .fineScrub: return Double(SliderGesture.scrubTravel) / SliderGesture.fineScale
        }
    }

    var name: String {
        switch self {
        case .coarseTrack: return "track"
        case .fineTrack: return "⇧track"
        case .coarseScrub: return "scrub"
        case .fineScrub: return "⇧scrub"
        }
    }
}

// MARK: - Reading the sources

/// The pins that keep this file's arithmetic attached to the app's.
///
/// Every constant in `PanelChain` is a literal written at one place in one source file.
/// This reads those files and finds the literal. It is a text scan and it is deliberately
/// the ONLY text scan in the suite: its job is not to check layout — it cannot — but to
/// make the measurements above fail loudly the day the chain moves under them, rather
/// than keep reporting the width of a panel that no longer exists.
enum LayoutSource {

    /// The package root, walked up from this file. `#filePath` is the compile-time path,
    /// which under `swift test` is the checkout.
    static var root: URL {
        // …/Tests/LumenAppTests/LayoutMetricSupport.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // …/Tests/LumenAppTests
            .deletingLastPathComponent()          // …/Tests
            .deletingLastPathComponent()          // …
    }

    static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The file with every run of whitespace flattened to one space, so a pin can name a
    /// multi-line chain of modifiers without also pinning its indentation.
    static func flattened(_ relativePath: String) throws -> String {
        let raw = try read(relativePath)
        return raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Every `LumenSlider(` call site in the app target.
    static func sliderCallSites() throws -> Int {
        let dir = root.appendingPathComponent("Sources/LumenApp")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        var total = 0
        for name in names.sorted() where name.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            total += text.components(separatedBy: "LumenSlider(").count - 1
        }
        return total
    }
}
#endif
