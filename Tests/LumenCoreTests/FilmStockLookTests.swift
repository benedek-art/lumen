// FilmStockLookTests.swift
// The measurable lines of docs/quality/lanes/WS-38/SPEC.md that can be stated on
// `FilmChain` directly (display-linear, before the finish table and the 8-bit encode).
// measure.py checks the same claims through the real renderer; these keep them true
// without a corpus or a release build.

import XCTest
@testable import LumenCore

final class FilmStockLookTests: XCTestCase {

    private let negatives: [FilmStock] = FilmStock.all.filter { $0.kind == .negative }
    private let colour: [FilmStock] = FilmStock.all.filter { !$0.monochrome }

    private func chain(_ stock: FilmStock, exposure: Double = 0, push: Double = 0) -> FilmChain {
        var recipe = FilmChain.defaultRecipe(for: stock)
        recipe.amount = 100
        recipe.pushPull = push
        return FilmChain(recipe, filmExposure: exposure, displayWhite: 1.0)
    }

    private func luma(_ c: RGB) -> Double {
        RGBColorSpace.rec2020.luminance(c)
    }

    private func grey(_ ev: Double) -> RGB { RGB(gray: 0.18 * pow(2, ev)) }

    /// Log-log display slope of luminance per scene EV, least squares over [a, b].
    private func slope(_ c: FilmChain, _ a: Double = -0.5, _ b: Double = 0.5) -> Double {
        var xs: [Double] = []
        var ys: [Double] = []
        var ev = a
        while ev <= b + 1e-9 {
            xs.append(ev)
            ys.append(log2(luma(c.apply(grey(ev)))))
            ev += 0.05
        }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var sxy = 0.0
        var sxx = 0.0
        for i in 0..<xs.count {
            sxy += (xs[i] - mx) * (ys[i] - my)
            sxx += (xs[i] - mx) * (xs[i] - mx)
        }
        return sxy / sxx
    }

    /// First EV (0.02 steps from grey) where luminance reaches `level`.
    private func firstEV(_ c: FilmChain, reaching level: Double, from: Double = 0,
                         to: Double = 10) -> Double? {
        var ev = from
        while ev <= to {
            if luma(c.apply(grey(ev))) >= level { return ev }
            ev += 0.02
        }
        return nil
    }

    private static let code250: Double = 0.9560   // sRGB code 250, display-linear

    // MARK: Tone

    /// S1 / S27: mid-grey prints at mid-grey in every channel — and a negative is
    /// printed back to it at every Film Exposure and every push (the lab re-levels).
    func testNegativesArePrintedBackToMidGreyAtEveryExposureAndPush() {
        for stock in negatives {
            for exposure in [-2.0, -1.0, 0.0, 1.5, 3.0] {
                for push in [-1.0, 0.0, 1.0, 2.0] {
                    let out = chain(stock, exposure: exposure, push: push).apply(grey(0))
                    XCTAssertEqual(out.maxAbsDifference(RGB(gray: 0.18)), 0, accuracy: 1e-6,
                                   "\(stock.id) exposure \(exposure) push \(push): \(out)")
                }
            }
        }
    }

    /// S30: a slide is not re-levelled — Film Exposure is scene exposure.
    func testASlidesFilmExposureIsSceneExposure() {
        let base = chain(.velvia50)
        for exposure in [-2.0, -1.0, 1.0, 2.0] {
            let moved = chain(.velvia50, exposure: exposure).apply(grey(0))
            let want = base.apply(grey(exposure))
            XCTAssertEqual(moved.maxAbsDifference(want), 0, accuracy: 1e-9)
        }
    }

    /// S2 / S3: each stock has its own contrast through mid-grey, in the datasheets'
    /// order (exact chain; the 33-point finish table reads ~8 % lower).
    func testContrastAtGreyIsOrderedLikeTheStocks() {
        let g = Dictionary(uniqueKeysWithValues: FilmStock.all.map { ($0.id, slope(chain($0))) })
        let portra = g["lumen/portra400"]!, gold = g["lumen/gold200"]!
        let ektar = g["lumen/ektar100"]!, velvia = g["lumen/velvia50"]!
        let trix = g["lumen/trix400"]!, cine = g["lumen/cine250d"]!
        XCTAssertGreaterThan(velvia, ektar + 0.15, "\(g)")
        XCTAssertGreaterThan(ektar, gold + 0.08, "\(g)")
        XCTAssertGreaterThan(gold, portra + 0.08, "\(g)")
        XCTAssertGreaterThan(trix, portra + 0.08, "\(g)")
        XCTAssertLessThanOrEqual(cine, gold, "\(g)")
        XCTAssertGreaterThan(portra, 1.1, "\(g)")
        XCTAssertGreaterThan(velvia, 1.75, "a slide is steep through the mid-tones: \(g)")
    }

    /// S4 / S36: white is reachable — a negative reaches code 250 a few stops over grey
    /// (the print's toe, not a sigmoid asymptote at +8 EV), a slide sooner; every stock
    /// is white at +9 EV.
    func testWhiteIsReachedWhereThePrintPutsIt() {
        for stock in FilmStock.all {
            let c = chain(stock)
            guard let ev = firstEV(c, reaching: FilmStockLookTests.code250) else {
                return XCTFail("\(stock.id) never reaches code 250")
            }
            if stock.kind == .reversal {
                XCTAssert((1.8...3.6).contains(ev), "\(stock.id) white at \(ev)")
            } else {
                XCTAssert((3.2...6.5).contains(ev), "\(stock.id) white at \(ev)")
            }
            XCTAssertGreaterThan(luma(c.apply(grey(9))), 0.98, stock.id)
        }
    }

    /// S7 / S8: blacks are black, not lifted grey — and paper black is neutral.
    func testBlacksAreDenseAndNeutral() {
        for stock in FilmStock.all {
            let c = chain(stock)
            let deep = c.apply(grey(-8))
            XCTAssertLessThan(deep.maxComponent, 0.0015, "\(stock.id) −8 EV: \(deep)")
            // Scene black prints at (or just above) paper black, with no colour: the
            // chroma fades out over the last codes above the floor.
            let floor = c.apply(RGB.zero)
            XCTAssertLessThan(floor.maxComponent, 0.001, "\(stock.id) black: \(floor)")
            XCTAssertLessThan(floor.maxComponent - floor.minComponent, 1e-4,
                              "\(stock.id) black is not neutral: \(floor)")
            XCTAssertGreaterThanOrEqual(floor.minComponent, FilmChain.blackFloor - 1e-15)
        }
    }

    // MARK: Film exposure and push

    /// S28 / S29: overexposure cleans the shadows (denser, not lifted); underexposure
    /// fogs them (lifted, flatter).
    func testOverexposureCleansShadowsAndUnderexposureFogsThem() {
        for stock in negatives {
            let normal = chain(stock).apply(grey(-5)).g
            // Within a third of a code at that level (measure.py allows one code).
            XCTAssertLessThanOrEqual(chain(stock, exposure: 2).apply(grey(-5)).g, normal + 1e-4,
                                     "\(stock.id) +2 lifted the shadows")
            XCTAssertGreaterThan(chain(stock, exposure: -2).apply(grey(-4)).g,
                                 chain(stock).apply(grey(-4)).g,
                                 "\(stock.id) −2 should print muddy, lifted shadows")
        }
    }

    /// S31 / S32: push raises contrast and loses the shadows the underexposure never
    /// recorded; pull does the opposite.
    func testPushSteepensAndLosesTheShadows() {
        for stock in negatives {
            let slopes = [-1.0, 0.0, 1.0, 2.0].map { slope(chain(stock, push: $0)) }
            XCTAssertEqual(slopes, slopes.sorted(), "\(stock.id) contrast vs push: \(slopes)")
            let toe = [-1.0, 0.0, 1.0, 2.0].map { firstEV(chain(stock, push: $0), reaching: 0.0036,
                                                         from: -10, to: 0) ?? 0 }
            XCTAssertEqual(toe, toe.sorted(), "\(stock.id) toe vs push: \(toe)")
            XCTAssertGreaterThan(toe[3] - toe[1], 1.2, "\(stock.id) push +2 toe: \(toe)")
        }
    }

    /// S34: Velvia's push range is its datasheet's, −½…+1.
    func testVelviaPushIsClampedToItsDatasheetRange() {
        XCTAssertEqual(FilmStock.velvia50.push.range, -0.5...1.0)
        for ev in stride(from: -8.0, through: 4.0, by: 0.5) {
            XCTAssertEqual(chain(.velvia50, push: 2).apply(grey(ev)),
                           chain(.velvia50, push: 1).apply(grey(ev)))
            XCTAssertEqual(chain(.velvia50, push: -1).apply(grey(ev)),
                           chain(.velvia50, push: -0.5).apply(grey(ev)))
        }
        XCTAssertEqual(chain(.velvia50, push: 2).pushPull, 1.0)
    }

    // MARK: Tri-X

    /// S22 / S23: panchromatic, not luma — a blue lighter and a red darker than a grey of
    /// the same luminance — and exactly neutral at every setting.
    func testTriXIsPanchromaticAndNeutral() {
        let blue = RGB(0.0399, 0.0507, 0.2664)
        let red = RGB(0.2978, 0.0599, 0.0467)
        for (exposure, push) in [(0.0, 0.0), (-2.0, -1.0), (3.0, 2.0), (0.0, 1.0)] {
            let c = chain(.triX400, exposure: exposure, push: push)
            for colourIn in [blue, red, RGB(1000, 0, 0), RGB(0.3, -0.05, 0.3), RGB(0.7, 0.58, 0.07)] {
                let out = c.apply(colourIn)
                XCTAssertEqual(out.r, out.g, accuracy: 1e-12)
                XCTAssertEqual(out.b, out.g, accuracy: 1e-12)
            }
        }
        let c = chain(.triX400)
        XCTAssertGreaterThan(c.apply(blue).g, c.apply(RGB(gray: luma(blue))).g * 1.15)
        XCTAssertLessThan(c.apply(red).g, c.apply(RGB(gray: luma(red))).g)
    }

    // MARK: Colour

    /// S20 / S21 / S36: whatever comes in, what goes out is finite, inside the display
    /// gamut (Rec.2020, the chain's space) and inside [black floor, paper white]; and
    /// over-range light bleaches toward white the way film does instead of printing a
    /// ×1000 red as a mid red.
    func testOutputIsFiniteInGamutAndOverRangeLightBleaches() {
        let inputs: [RGB] = [RGB(1000, 0, 0), RGB(0, 30, 0), RGB(0, 0, 30), RGB(30, 0, 30),
                             RGB(-0.05, 0.3, 0.3), RGB(0.3, -0.05, 0.3), RGB(5, 4, -1),
                             RGB(1e6, 1e6, 1e6), RGB(1e-6, 1e-6, 1e-6), RGB(0.02, 0.4, 0.9)]
        for stock in FilmStock.all {
            let c = chain(stock)
            for input in inputs {
                let out = c.apply(input)
                XCTAssert(out.isFinite, "\(stock.id) \(input) → \(out)")
                XCTAssertGreaterThanOrEqual(out.minComponent, -1e-9, "\(stock.id) \(input) → \(out)")
                XCTAssertLessThanOrEqual(out.maxComponent, 1 + 1e-9, "\(stock.id) \(input) → \(out)")
            }
            XCTAssertGreaterThan(luma(c.apply(RGB(1000, 0, 0))), 0.75, "\(stock.id) ×1000 red")
        }
    }

    private func lch(_ c: RGB) -> OKLCh { OKLabTransform.working.toLCh(c) }

    private func hueDelta(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// S16 / S18: hue follows the neutral rendering (Portra keeps skin and sky where
    /// they are), and chroma is a stock's saturation, not a vibrance curve: dark and
    /// light skin get about the same chroma scale.
    func testPortraSkinAndSkyKeepTheirHue() {
        let neutral = DisplayTransform(DisplayTransformParams.neutral, space: .rec2020)
        let skins: [RGB] = [RGB(0.138, 0.088, 0.061), RGB(0.462, 0.311, 0.231),
                            RGB(0.30, 0.19, 0.13), RGB(0.05, 0.032, 0.022)]
        let c = chain(.portra400)
        var ratios: [Double] = []
        for s in skins {
            let f = lch(c.apply(s))
            let n = lch(neutral.apply(s, gamut: Gamut.sharedBoundary))
            XCTAssertLessThan(abs(hueDelta(f.h, n.h)), 4, "skin \(s): \(f) vs \(n)")
            ratios.append(f.C / n.C)
        }
        XCTAssertLessThan(ratios.max()! / ratios.min()!, 1.25, "vibrance-like chroma: \(ratios)")
        let sky = RGB(0.1439, 0.191, 0.3157)
        let f = lch(c.apply(sky))
        let n = lch(neutral.apply(sky, gamut: Gamut.sharedBoundary))
        XCTAssertLessThan(abs(hueDelta(f.h, n.h)), 5, "sky \(f) vs \(n)")
    }

    /// S13: saturation is ordered like the stocks on a muted colour.
    func testSaturationIsOrderedLikeTheStocks() {
        let foliage = RGB(0.115, 0.1445, 0.0612)
        func c(_ s: FilmStock) -> Double { lch(chain(s).apply(foliage)).C }
        XCTAssertGreaterThan(c(.velvia50), c(.ektar100))
        XCTAssertGreaterThan(c(.ektar100), c(.gold200))
        XCTAssertGreaterThan(c(.gold200), c(.portra400))
        XCTAssertLessThanOrEqual(c(.cine250D), c(.portra400) * 1.03)
    }

    /// S35, on colour: every channel of a coloured ramp (a scaled skin and a scaled sky)
    /// stays monotone through every stock — the colour stages cannot fold a ramp back.
    func testColouredRampsStayMonotone() {
        for stock in colour {
            let c = chain(stock)
            for base in [RGB(0.462, 0.311, 0.231), RGB(0.1439, 0.191, 0.3157)] {
                var previous = RGB(gray: -1)
                for step in 0...160 {
                    let ev = -10.0 + Double(step) * 0.1
                    let out = c.apply(base * pow(2, ev))
                    XCTAssertGreaterThanOrEqual(luma(out), luma(previous) - 1e-9,
                                                "\(stock.id) \(base) at \(ev) EV")
                    previous = out
                }
            }
        }
    }
}
