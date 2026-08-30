// LumenSurface.swift
// The light. One modifier, and it is the difference between "flat 2026 grey" and an
// interface made of objects.
//
// docs/30 §2.1. The owner's verdict on the Phase 4 build was "it just looks like it was
// made in 2008", and four audits converged on one physical cause: NOTHING IN THIS
// APPLICATION HAS AN EDGE. Not one surface announces where it stops.
//
// The measurements, because the diagnosis is counter-intuitive and the numbers are what
// make it actionable. The elevation ladder in `Lumen` — surroundCanvas 0.165, windowBase
// 0.18, panel 0.20, controlSurface 0.24, hover 0.27, active 0.31 — spans **1.873:1 end to
// end**. Adjacent steps are 1.05–1.17:1. The boundary between the photograph and the
// develop column, the single most important edge in the window, is **1.135:1**. A human
// eye does not resolve an edge at 1.1:1 without help. So the panel does not sit BESIDE
// the picture; it bleeds into it.
//
// AND THE PREVIOUS DESIGN PASS MADE IT WORSE. docs/25 diagnosed "no elevation ladder — two
// surfaces and a pile of hairlines" correctly, and prescribed replacing the hairlines with
// the grey ladder above. The hairlines went; the ladder cannot carry the load; the app
// went FLATTER after its own redesign. That is the whole of the "2008" complaint,
// measured.
//
// WHY THIS FIXES IT WITHOUT CHANGING A SINGLE GREY. Linear and Raycast run surface steps
// no larger than ours — around 1.14:1 — and read as solid objects with weight. The
// difference is not contrast, it is LIGHT: every surface carries a one-pixel top highlight
// (the lit edge) and a real shadow (the cast). Given those two cues the eye reconstructs a
// plane from a contrast ratio far below its own edge-detection threshold, because it stops
// looking for a boundary and starts looking at an object. Four shadows exist in 24,797
// lines of this app's view code, zero materials, zero inner highlights.
//
// So: the palette is not the problem and is not being touched. The lighting is missing.

#if os(macOS)
import SwiftUI

extension View {

    /// Make this view read as a raised object: a lit top edge, a falling-off side and
    /// bottom, and a cast shadow underneath.
    ///
    /// The border is a GRADIENT, not a flat stroke, and that is most of the effect. A
    /// uniform 1px line reads as a drawn outline — the pre-Yosemite idiom this app has
    /// been accused of. A stroke that is bright along the top and near-invisible along
    /// the bottom reads as a highlight, because that is what a real edge does under a
    /// light from above. It is the same argument the slider groove already makes for
    /// carving DOWN; this is the other direction.
    ///
    /// `elevation` is the height of the object above what it sits on, and it drives the
    /// shadow only. The highlight does not change with height: a lit edge is lit.
    func lumenSurface(radius: CGFloat = Lumen.radiusCard,
                      elevation: Lumen.Elevation = .raised,
                      fill: Color? = nil) -> some View {
        modifier(LumenSurfaceModifier(radius: radius, elevation: elevation, fill: fill))
    }

    /// A surface that sits DOWN in its parent rather than up out of it — a well. The
    /// light lands on the far lip, so the highlight moves to the bottom and the shadow
    /// becomes an inner one along the top.
    ///
    /// Grooves, histogram wells, text fields. The slider already draws this by hand with
    /// a gradient fill; this is that idea made available to everything else.
    func lumenWell(radius: CGFloat = Lumen.radiusControl) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.black.opacity(0.45),
                                                Color.white.opacity(0.05)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
    }
}

private struct LumenSurfaceModifier: ViewModifier {
    let radius: CGFloat
    let elevation: Lumen.Elevation
    let fill: Color?

    func body(content: Content) -> some View {
        content
            .background(fill ?? Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(elevation.highlight),
                                     Color.white.opacity(elevation.highlight * 0.28)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
            .shadow(color: .black.opacity(elevation.shadowOpacity),
                    radius: elevation.shadowRadius,
                    y: elevation.shadowOffset)
    }
}

extension Lumen {

    /// How far off its parent a surface sits. Three steps, because a fourth would be a
    /// distinction nobody could name — and an elevation nobody can name is one that gets
    /// applied by coin toss.
    enum Elevation {
        /// Flush: an edge but no cast. Rows, list cells, anything tiled edge to edge.
        case flush
        /// The default. Cards, panels, section containers.
        case raised
        /// Off the page entirely: popovers, the ⌘K palette, anything modal.
        case floating

        var highlight: Double {
            switch self {
            case .flush: return 0.055
            case .raised: return 0.085
            case .floating: return 0.11
            }
        }

        var shadowOpacity: Double {
            switch self {
            case .flush: return 0
            case .raised: return 0.34
            case .floating: return 0.5
            }
        }

        var shadowRadius: CGFloat {
            switch self {
            case .flush: return 0
            case .raised: return 10
            case .floating: return 26
            }
        }

        var shadowOffset: CGFloat {
            switch self {
            case .flush: return 0
            case .raised: return 4
            case .floating: return 10
            }
        }
    }

    // MARK: Radii

    /// FOUR RADII, NOT SEVEN.
    ///
    /// The app shipped 1, 2, 3, 4, 5, 6 and 10 — with 3 and 4 each used 22 times, which
    /// is two values for one decision, invisibly different. And 3–4 pt on a 320 pt panel
    /// is the Aqua proportion; every app this one wants to be compared to runs 8–12 on a
    /// card and 6–8 on a control.
    ///
    /// THE LADDER MOVED UP ONE STEP, on the owner's third review: "I'd love if we can
    /// maybe make the corner radius a little higher, so a little bit more circular,
    /// especially for the Cull, Develop, Crop, Grade, Deliver items, as well as the
    /// independent items like the Curves tab, the White Balance, Tone."
    ///
    /// He is naming both ends of the scale — the tab strip and the section cards — so
    /// the fix is the tokens rather than the call sites, and every surface in the app
    /// rounds together. 10 → 14 on a card is the difference between "a rectangle with
    /// its corners taken off" and a shape; 6 → 9 keeps a control in proportion to the
    /// card holding it; 4 → 6 does the same for a chip.
    static let radiusCard: CGFloat = 14
    static let radiusControl: CGFloat = 9
    static let radiusChip: CGFloat = 6

    /// The workspace rail's own, and the only radius that is nearly a capsule.
    ///
    /// Sized against the horizontal strip's 28-point tab, where 12 left four points of
    /// straight edge per corner — pill at a glance, square enough in a row. The rail's
    /// icon-over-label tabs are taller, which only moves the read FURTHER from a
    /// circle, so the number survives the geometry that renamed it. It is a separate
    /// number from `radiusChip` because a chip is 16 points tall and 12 on one of
    /// those is a circle.
    static let radiusTab: CGFloat = 12
}
#endif
