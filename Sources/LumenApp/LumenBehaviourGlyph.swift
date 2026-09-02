// LumenBehaviourGlyph.swift
// The answer to "I want to know what Feather does, what Flow does, what Density does
// before I even click it" — and the reason it is not a sentence.
//
// docs/30 §2.2 measured what happened the last time this application explained itself:
// nineteen always-visible paragraphs in the mask panel became nineteen rows reading
// "ⓘ How this works", which was worse, because a tooltip that ships its own visible
// label is a permanent three-word advertisement for one. Half the words in the app were
// explanation. The rule that came out of it is that a control needing a sentence has not
// been designed yet.
//
// So this draws the parameter instead. Every slider whose meaning IS a shape gets a
// small picture of that shape in its own label row, live, as the value changes. Four
// properties make it worth building rather than decorative (docs/35 §4.5):
//
//   1. It is not text, so it costs no words and obeys the silence rule.
//   2. It is LIVE, so it stays a readout after it has finished being an explanation —
//      it keeps earning its space, which a tooltip does not.
//   3. It is ONE component driven by an enum, not eight drawings.
//   4. It generalises. Highlights and Shadows, the parametric curve's regions, Clarity's
//      radius, the vignette's midpoint — every one of those is a shape currently being
//      described in words somewhere in this application.
//
// WHERE IT IS ALLOWED. Only on parameters whose meaning is a shape. A magnitude —
// Exposure, Contrast, Saturation — has no shape to draw, and a glyph beside one would be
// decoration, which is how a good idea becomes visual noise. `Shape` is the whole list,
// and it is deliberately short.

#if os(macOS)

import LumenCore
import SwiftUI

/// What a behaviour glyph draws. One case per parameter whose meaning is a shape.
/// `Equatable` is written down now that one case carries a payload. An enum with no
/// associated values gets `==` implicitly; adding `luminositySeries(LuminositySeries)`
/// withdrew it, and three comparisons in `draw` stopped compiling — on macOS only,
/// because this file is behind `#if os(macOS)` and the Linux build never sees it.
enum BehaviourShape: Equatable {
    /// A brush stamp's cross-section: square at Feather 0, a bell at 100.
    case stampFalloff
    /// Three passes of one stroke, each accumulating `1 − (1 − flow)ⁿ`.
    case flow
    /// The same three passes against a ceiling they cannot cross.
    case densityCeiling
    /// The stamp at true relative scale.
    case size
    /// A soft alpha ramp leaning onto a hard edge in the picture.
    case followEdges
    /// A step becoming a ramp — a Gaussian over the finished alpha.
    case softenEdge
    /// The boundary moving out of, or into, the selection.
    case expandContract
    /// A range band's shoulders opening.
    case smoothness
    /// The luminosity series' own curve — the strongest case the whole component makes
    /// for itself. Lights, Darks and Midtones are three different SHAPES over the tone
    /// scale, the level bends each one, and the glyph is literally the mask's transfer
    /// function rather than an illustration of it: `draw` calls the same
    /// `MaskRaster.luminosityValue` the rasterizer calls. The picture and the pixels
    /// cannot drift apart, because they are one function.
    case luminositySeries(LuminositySeries)
}

/// A live drawing of what one parameter does, 26×14 inside a slider row.
///
/// `value` is normalized 0…1 for every shape but `expandContract`, which is signed
/// −1…1 because its two directions are different behaviours rather than more and less
/// of one.
///
/// **It was 44 wide, and 44 was more than half the label column it was drawn inside.**
/// `LumenSlider` paid for the picture out of `Lumen.labelWidth` — 86 − 44 − 4 left 38
/// points for the name, about six characters — so the four controls that carry a glyph
/// were the four whose names ellipsized: "Follo…", "Expa…", "Softe…", "Max s…". The
/// column had been MEASURED at 86 to fit every name in the app; the glyph broke that
/// measurement in the same round that added it, and it did so at every panel width,
/// because the text columns are fixed and only the track grows.
///
/// A picture explaining a control must not eat the control's name. 26 still reads as a
/// ramp, a falloff or a pair of squares at arm's length, and it leaves 56 points — over
/// eleven characters at the shrink floor — which fits every label that exists.
struct LumenBehaviourGlyph: View {

    let shape: BehaviourShape
    let value: Double
    /// Overridable so a future standalone use is not forced to the in-row size; every
    /// call site today takes the default.
    var width: CGFloat = LumenBehaviourGlyph.inRowWidth

    /// What a glyph costs inside a slider's label column.
    static let inRowWidth: CGFloat = 26
    static let height: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            draw(&context, size)
        }
        .frame(width: width, height: Self.height)
        // A well, not a card: it is a readout of a value, and every other readout of a
        // value in this application is carved down rather than raised up.
        .lumenWell(radius: 3)
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    private var ink: Color { Lumen.primaryText.opacity(0.85) }
    private var wash: Color { Lumen.primaryText.opacity(0.22) }
    private var mark: Color { Lumen.accent }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let floor = h - 2.5
        let ceiling: CGFloat = 2.5
        let travel = floor - ceiling
        let v = value.isFinite ? value : 0

        switch shape {
        case .stampFalloff:
            // `MaskRaster.stampProfile`: flat core to `hardness`, smoothstep shoulder
            // to the rim. Drawn as the profile across the stamp's diameter, which is
            // literally what the rasterizer walks.
            let hardness = 1 - Num.saturate(v)
            filled(&context, w: w, floor: floor, travel: travel) { t in
                let r = abs(t * 2 - 1)
                if r <= hardness { return 1 }
                if r >= 1 { return 0 }
                let u = (r - hardness) / Swift.max(1 - hardness, 1e-6)
                return 1 - (u * u * (3 - 2 * u))
            }

        case .flow, .densityCeiling:
            // Three bars, whose HEIGHT and opacity both carry the accumulated value —
            // one channel alone reads as three similar rectangles rather than as three
            // passes.
            let f = shape == .flow ? Num.saturate(v) : 0.55
            let cap = shape == .flow ? 1 : Num.saturate(v)
            // Proportional, not fixed. At the old 44 pt width a flat 4 pt gutter left
            // 9 pt bars; at the in-row 26 it would have left 3.3, which reads as three
            // hairlines rather than three passes. The gutter now scales with the box so
            // the bars stay the subject at any width the glyph is asked to draw at.
            let pad = Swift.max(2, w * 0.09)
            let bw = (w - pad * 4) / 3
            for n in 1...3 {
                let accumulated = Swift.min(cap, 1 - pow(1 - f, Double(n)))
                let bh = 2 + CGFloat(accumulated) * (travel - 2)
                let x = pad + CGFloat(n - 1) * (bw + pad)
                context.fill(Path(CGRect(x: x, y: floor - bh, width: bw, height: bh)),
                             with: .color(ink.opacity(0.25 + accumulated * 0.75)))
            }
            if shape == .densityCeiling {
                let y = floor - (2 + CGFloat(cap) * (travel - 2))
                var line = Path()
                line.move(to: CGPoint(x: 2, y: y))
                line.addLine(to: CGPoint(x: w - 2, y: y))
                context.stroke(line, with: .color(mark),
                               style: StrokeStyle(lineWidth: 1.25, dash: [2.5, 2.5]))
            }

        case .size:
            let r = 2 + CGFloat(Num.saturate(v)) * (h / 2 - 3)
            let rect = CGRect(x: w / 2 - r, y: h / 2 - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(wash))
            context.stroke(Path(ellipseIn: rect), with: .color(ink), lineWidth: 1)

        case .followEdges:
            // The picture's edge, and the alpha leaning onto it. At 0 the ramp is
            // broad and ignores the edge; at 100 it collapses onto it — which is what
            // the guided filter does, and why "Snap" was the wrong word for it.
            let edge = w * 0.55
            context.fill(Path(CGRect(x: edge, y: 0, width: w - edge, height: h)),
                         with: .color(Lumen.primaryText.opacity(0.12)))
            var post = Path()
            post.move(to: CGPoint(x: edge, y: 0))
            post.addLine(to: CGPoint(x: edge, y: h))
            context.stroke(post, with: .color(Lumen.primaryText.opacity(0.35)),
                           lineWidth: 1)
            let soft = CGFloat(0.34 * (1 - Num.saturate(v))) + 0.02
            var ramp = Path()
            for step in 0...Int(w) {
                let x = CGFloat(step)
                let t = smoothstep(edge - soft * w, edge + soft * w, x)
                let y = floor - CGFloat(t) * travel
                if step == 0 { ramp.move(to: CGPoint(x: x, y: y)) }
                else { ramp.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(ramp, with: .color(mark), lineWidth: 1.4)

        case .softenEdge:
            let soft = CGFloat(Num.saturate(v)) * 0.42 + 0.01
            filled(&context, w: w, floor: floor, travel: travel) { t in
                Double(smoothstep(0.5 - soft, 0.5 + soft, CGFloat(t)))
            }

        case .expandContract:
            // The original as a dashed ghost, and where the boundary went as a solid.
            let d = CGFloat(Num.clamp(v, -1, 1)) * (h * 0.22)
            box(&context, w: w, h: h, inset: 0, stroke: Lumen.primaryText.opacity(0.3),
                dashed: true)
            box(&context, w: w, h: h, inset: -d, stroke: mark, dashed: false)

        case .smoothness:
            let s = CGFloat(Num.saturate(v)) * 0.26 + 0.015
            filled(&context, w: w, floor: floor, travel: travel) { t in
                let x = CGFloat(t)
                return Double(Swift.min(smoothstep(0.30 - s, 0.30 + s, x),
                                        1 - smoothstep(0.70 - s, 0.70 + s, x)))
            }

        case .luminositySeries(let series):
            // `value` is the level normalized over 1…5, which is what the slider hands
            // every glyph; the curve wants the level itself.
            let level = MaskRaster.luminosityMinLevel
                + Num.saturate(v)
                    * (MaskRaster.luminosityMaxLevel - MaskRaster.luminosityMinLevel)
            filled(&context, w: w, floor: floor, travel: travel) { t in
                MaskRaster.luminosityValue(t, series: series, level: level)
            }
        }
    }

    /// A filled profile under a function of `t` in 0…1. Every shape that is a curve
    /// draws through here, so they all sit on the same baseline and read as a family.
    private func filled(_ context: inout GraphicsContext, w: CGFloat,
                        floor: CGFloat, travel: CGFloat,
                        _ f: (Double) -> Double) {
        var path = Path()
        let steps = Int(w)
        for step in 0...steps {
            let x = CGFloat(step)
            let y = floor - CGFloat(Num.saturate(f(Double(step) / Double(steps)))) * travel
            if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        var area = path
        area.addLine(to: CGPoint(x: w, y: floor))
        area.addLine(to: CGPoint(x: 0, y: floor))
        area.closeSubpath()
        context.fill(area, with: .color(wash))
        context.stroke(path, with: .color(ink), lineWidth: 1.1)
    }

    private func box(_ context: inout GraphicsContext, w: CGFloat, h: CGFloat,
                     inset: CGFloat, stroke: Color, dashed: Bool) {
        let rect = CGRect(x: w * 0.3 + inset, y: 3 + inset,
                          width: w * 0.4 - inset * 2, height: h - 6 - inset * 2)
        guard rect.width > 1, rect.height > 1 else { return }
        // 2.5 IS CORRECT HERE AND IS NOT A TOKEN VIOLATION, which is worth writing down
        // because an audit read it as one and the mechanical fix is visibly wrong.
        //
        // The radius ladder (6 chip / 9 control / 14 card) describes SURFACES a hand can
        // point at. This is a drawn miniature — the whole canvas is 14 points tall, so
        // this box is about 8 — and `radiusChip` on an 8-point box is a capsule, not a
        // rounded rectangle. The number that keeps a diagram reading as the shape it
        // depicts is proportional to the diagram, and 2.5 on 8 is the same proportion as
        // 6 on a 16-point chip.
        let path = Path(roundedRect: rect, cornerRadius: 2.5)
        context.stroke(path, with: .color(stroke),
                       style: StrokeStyle(lineWidth: 1.1, dash: dashed ? [2.5, 2.5] : []))
    }

    private func smoothstep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        guard e1 > e0 else { return x < e0 ? 0 : 1 }
        let t = Swift.min(Swift.max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

#endif
