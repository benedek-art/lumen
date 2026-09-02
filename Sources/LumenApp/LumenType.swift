// LumenType.swift
// A type scale, because there was not one.
//
// docs/30 §2.1. The measurement: 220 `.font(.system(size:))` calls in `Sources/LumenApp`,
// of which **199 — ninety percent — are 9, 10 or 11 point**. The ratio between 10 and 11
// is 1.1. A scale needs about 1.2 between steps to register as a step at all, so 9/10/11
// is not a scale, it is jitter: three sizes that look identical at arm's length, chosen
// ad hoc, which is exactly why nothing in the panel anchors the eye.
//
// Weight did no work either. **Twenty-seven of 220 calls carried a non-regular weight**,
// so 88% of the app's text was SF Pro Regular — the macOS system default, at the system
// default weight. That is the loudest "stock Apple" tell in the codebase, louder than any
// control.
//
// And there were TWO TYPEFACES. Twenty-three sites used `design: .monospaced`, which is
// SF Mono — a different family with a different x-height and stroke weight, sitting inches
// from SF Pro in the same row. Only three sites used `.monospacedDigit()`, which is the
// actual tool: tabular figures on the SAME face. Nobody ships a second family for numbers
// any more; Linear, Figma and Photomator all use tabular figures on their body face.
//
// Five hand-rolled ALL-CAPS styles existed at three sizes and three tracking values.
//
// So this file is four roles and one numeric style. Not "a font for every occasion" — a
// scale small enough that choosing from it is obvious and the next person cannot invent a
// sixth 10pt semibold.

#if os(macOS)
import SwiftUI

extension Font {

    /// Section headers and the workspace switcher. The top of the ramp inside a panel.
    ///
    /// A heading drawn in the same colour and one weight-step from the rows it governs
    /// is not a heading, it is texture. That was the measured cause of "there's so much
    /// clutter, it's not neat" — six of these stacked, all the same weight as their
    /// contents, reading as a table of contents rather than as structure.
    ///
    /// 12, DOWN FROM 13, because the ramp below it moved. The step that makes a heading
    /// read is its ratio to the body text under it, not its absolute size: against a
    /// 12 pt body, 13 was a ratio of 1.08 and invisible; against 11 it is 1.09 — so the
    /// weight and the case are what were actually doing the work, and the size was
    /// costing vertical rhythm for nothing. Semibold mixed-case at 12 against regular
    /// 11 is a real step, and it is the size Lightroom, Capture One and Linear all set
    /// a panel heading at.
    ///
    /// It shipped with ZERO call sites — `LumenSectionHeader` drew tracked capitals
    /// instead, so the file written to end five caps styles was itself unused while 53
    /// headers shouted. That is fixed at the call site, in `LumenControls`.
    static let lumenHeading: Font = .system(size: 12, weight: .semibold)

    /// Control labels, button text, list rows. The body of the app.
    ///
    /// 11, DOWN FROM 12. The audit found 198 raw `.system(size:)` calls against 61
    /// token uses, and 170 of those raw calls are 9, 10 or 11 — so 12 was a token
    /// nobody reached for, and every migrated call site would have made the panel
    /// TALLER than the one it replaced. Meeting the app where its text actually lives
    /// is what lets the migration happen at all, and 11 against a 10 pt caption and a
    /// 12 pt semibold heading is the first real three-step ramp this app has had.
    static let lumenBody: Font = .system(size: 11, weight: .regular)

    /// The same, when it must carry emphasis — a selected tab, an active row.
    static let lumenBodyStrong: Font = .system(size: 11, weight: .medium)

    /// Captions, units, secondary annotation. The bottom of the ramp.
    ///
    /// 10 is the floor. There were 46 sites at 9pt in a build whose own design audit had
    /// already set 10 as the minimum and never enforced it.
    static let lumenCaption: Font = .system(size: 10, weight: .regular)

    /// EVERY NUMBER IN THE APP.
    ///
    /// Tabular figures on SF Pro, not SF Mono. `.monospacedDigit()` fixes the digit
    /// advance so a readout does not jitter as it counts, which is the only property a
    /// second typeface was ever bought for — and it keeps the number in the same voice as
    /// the label beside it. 13 sizes and 2 families collapse to one of each.
    ///
    /// 11, to sit level with the label it annotates. A readout a point larger than its
    /// own label is the number claiming to be the subject, and in a panel of fifteen
    /// rows the numbers are the last thing that should be shouting.
    static let lumenNumeric: Font = .system(size: 11, weight: .regular).monospacedDigit()

    /// A COUNT, beside the thing it counts — a filter chip's tally, a clipping
    /// percentage, the raw panel's readouts.
    ///
    /// The caption size, with tabular figures, because these are annotations that
    /// happen to be numbers: they must not jitter as they count, and they must not
    /// claim the weight of a value somebody is reading. It exists because the
    /// alternative was six sites at `.system(size: 9)` — under this file's own stated
    /// floor — three of them reaching for `.monospacedDigit()` by hand and one for a
    /// second typeface.
    static let lumenCaptionNumeric: Font =
        .system(size: 10, weight: .regular).monospacedDigit()

    /// A number that is the subject rather than an annotation — the slider readout while
    /// it is being scrubbed, the histogram's clipping percentages.
    static let lumenNumericStrong: Font = .system(size: 11, weight: .medium).monospacedDigit()

    // MARK: - The two steps above the panel scale

    /// 10, SEMIBOLD — the one weight the scale was missing, and the reason six panels
    /// were still writing their own.
    ///
    /// `lumenCaption` is 10 regular and `LumenCapsLabel` is 10 semibold with capitals
    /// and tracking. Between them sat a real role with no token: a short mixed-case
    /// label that has to hold its own against the row beside it — a mask component's
    /// name, a swatch's count, the viewer's mode badge. Every one of those was
    /// `.system(size: 10, weight: .semibold)` written out, which is how a scale
    /// re-fragments one call site at a time.
    static let lumenCaptionStrong: Font = .system(size: 10, weight: .semibold)

    /// 13 — the LEAD LINE of a surface that is not a panel.
    ///
    /// An empty state's headline and the control palette's rows are the same role: the
    /// one line a photographer reads first on a surface that has taken over the window.
    /// 13 rather than the panel scale's 11 because these are not panel chrome competing
    /// with a photograph — they are the only thing on screen — and `ControlPalette`'s
    /// own comment already argued for the number ("the row's type is 13 point rather
    /// than 12"). Naming it is what stops the next such surface picking 12 or 14.
    static let lumenLead: Font = .system(size: 13, weight: .regular)

    /// 15, SEMIBOLD — a sheet's title, and nothing else.
    ///
    /// The scale tops out at `lumenHeading`'s 12 because a panel section heading sits
    /// beside a photograph and must not shout. A modal sheet has no photograph beside
    /// it and one job, which is to say what it is; 12 there reads as a form label.
    static let lumenTitle: Font = .system(size: 15, weight: .semibold)

    // MARK: - Glyphs, which are not type

    /// AN SF SYMBOL'S POINT SIZE IS NOT A TYPE SIZE, and putting the two on one scale is
    /// most of why the app still measured 89 raw `.system(size:)` calls after the type
    /// migration had done its job.
    ///
    /// `.font(.system(size: 40))` on an `Image` sets a glyph's drawn extent. It is a
    /// graphic decision — how big is this mark against the space it sits in — and it
    /// answers to the icon's container, not to the reading distance of the text around
    /// it. Held on one scale with body copy, the two argue: a 12 pt row icon and 12 pt
    /// body text are the same number for unrelated reasons, and moving either drags the
    /// other. Held apart, each can move.
    ///
    /// THE SAME LADDER, MIRRORED — every glyph token is the exact face of the text
    /// token it is named after, so separating the scales moved not one pixel. That is
    /// deliberate and it is the point: the two are identical TODAY and now have
    /// somewhere to diverge, where before a glyph could only get bigger by dragging
    /// body copy with it.
    ///
    /// The mirror also made the migration provable. 37 glyphs were already wearing text
    /// tokens — U1's type pass swept them up along with the prose, which is how the two
    /// scales became one in the first place — and every one of them could be moved
    /// across on the guarantee that `lumenGlyphCaption` IS `lumenCaption`'s face.
    /// `DesignSystemTests.testAnImageDoesNotTakeATextToken` is what found them and what
    /// stops the next one.
    static let lumenGlyphCaption: Font = .system(size: 10, weight: .regular)
    static let lumenGlyphCaptionStrong: Font = .system(size: 10, weight: .semibold)
    static let lumenGlyphBody: Font = .system(size: 11, weight: .regular)
    static let lumenGlyphBodyStrong: Font = .system(size: 11, weight: .medium)
    /// A row's leading icon, one step above the text beside it — the only step with no
    /// text counterpart, because 12 pt of prose is a heading and this is not one.
    static let lumenGlyphRow: Font = .system(size: 12, weight: .regular)
    /// A tile's icon above its label.
    static let lumenGlyphLarge: Font = .system(size: 15, weight: .regular)
    /// An empty state's mark.
    static let lumenGlyphDisplay: Font = .system(size: 40, weight: .regular)

    /// A CHECKMARK AT 10 POINTS, bold — the one glyph whose weight is a contrast
    /// argument rather than a stylistic one.
    ///
    /// `LumenSwitch`'s own comment measured it: "a white tick on 0.72 grey is 1.3:1 and
    /// disappears at this size", which is why that tick is dark and bold. Semibold at 10
    /// loses it again. Two call sites — the switch and the menu's selected row — and a
    /// third would be a third place where a tick has to survive being small.
    static let lumenGlyphTick: Font = .system(size: 10, weight: .bold)
}

/// The one ALL-CAPS label, replacing five — and now at ONE SIZE, which is what it was
/// built for and had already lost.
///
/// They existed at 11/0.8, 10/0.6, 10/0.6, 9/0.6 and 9/0.5 — five styles for one idea,
/// two of them below the app's own stated 10pt floor. Then this type re-fragmented into
/// three sizes of its own (12 for section headers, 11 for panel titles, 10 for group
/// labels), which is the same failure wearing the fix's name.
///
/// The scope is now what caps are actually good for: a SMALL TERTIARY GROUP MARKER — a
/// word that labels a cluster and is not meant to be read as prose. Headings and panel
/// titles took mixed case at `.lumenHeading`, because capitals strip the word-shape a
/// reader recognises and no instrument in this category sets a heading that way.
///
/// The size default is the only size in the tree. It stays a parameter so the workspace
/// rail can set its own if it ever needs to, but nothing passes it today, and a grep for
/// `size:` on this type is the check that it has not fragmented again.
struct LumenCapsLabel: View {
    let text: String
    var size: CGFloat = 10
    var color: Color = Lumen.secondaryText

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold))
            .tracking(size >= 12 ? 0.6 : 0.8)
            .foregroundStyle(color)
    }
}
#endif
