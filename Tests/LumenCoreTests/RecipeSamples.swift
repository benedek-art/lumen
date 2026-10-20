// RecipeSamples.swift
// Shared recipe fixtures. `populated()` is the full-fidelity sample: every optional
// present, every collection non-empty, and every key off its default somewhere.
// `RecipeCodecToleranceTests` enforces both halves: `testTheSampleRecipeLeavesNoFieldUnpopulated`
// the first two, `testNoRecipeFieldIsSampledOnlyAtItsDefault` the third, checked per
// type and key rather than per instance. So any test built on it covers a new field as
// soon as somebody populates it.

@testable import LumenCore

enum RecipeSamples {

    /// A recipe with every optional present, every collection non-empty, and every key
    /// set off its default in at least one instance (`mixer.bands[0].lum` is 0, its
    /// default, because the other bands' are not).
    ///
    /// Nothing here is a default on purpose: a sample that agreed with the defaults
    /// would make "the field came back at its default" true whether the decoder read
    /// the key or not, which is a test that cannot fail.
    static func populated() -> Recipe {
        let shift = HSLShift(h: 3, s: 4, l: 5)
        let swatch = PointColor(sample: [0.2, 0.3, 0.4], range: 44,
                                variance: -12, shift: shift)
        let curve = CurveSet(
            parametric: ParametricCurve(highlights: 11, lights: 12, darks: 13,
                                        shadows: 14, splits: [0.2, 0.45, 0.8]),
            point: [[0, 0], [0.5, 0.6], [1, 1]],
            r: [[0, 0], [1, 0.9]],
            g: [[0, 0.05], [1, 1]],
            b: [[0, 0], [1, 0.95]],
            luma: [[0, 0.02], [1, 0.98]],
            preserveLuminance: false)
        let wheels = GradingWheels(
            global: Wheel(hue: 10, sat: 0.2, lum: 0.1),
            shadows: Wheel(hue: 200, sat: 0.3, lum: -0.2),
            mid: Wheel(hue: 90, sat: 0.15, lum: 0.05),
            high: Wheel(hue: 300, sat: 0.25, lum: 0.3),
            blending: 61, balance: -13, pivots: [0.3, 0.72],
            colorBalance: ColorBalanceParams(
                hueShift: 12, vibrance: 21,
                chroma: ColorBalanceAxis(global: 1, shadows: 2, mid: 3, high: 4),
                saturation: ColorBalanceAxis(global: 5, shadows: 6, mid: 7, high: 8),
                brilliance: ColorBalanceAxis(global: 9, shadows: 10, mid: 11, high: 12)))

        func zone(_ ev: Double) -> ZoneAdjust {
            ZoneAdjust(ev: ev, wheel: [ev / 10, -ev / 10], sat: ev * 2, falloff: 0.4)
        }

        // Each sub-expression is bound separately, and that is not a style choice.
        // Written as one nested `Develop(...)` literal — eleven arguments, several of
        // them nested initializers, one of them a closure mapping a range into eight
        // `MixerBand`s — Swift's type checker gives up: "unable to type-check this
        // expression in reasonable time". The syntax is perfectly valid, so
        // `swiftc -parse` passes it and `check-swift-surface.py` passes it, and only a
        // real compiler says no. That is the same gap that cost a macOS round trip
        // earlier today, arriving from the other direction.
        let rawParams = RawParams(decoder: "lumen", decoderVersion: 7,
                                  temp: 5600, tint: 12)
        let tone = Tone(exposure: 0.4, contrast: 15, contrastPivot: -0.5,
                        highlights: -30, shadows: 25, whites: 10, blacks: -12)
        let zones = Zones(pivots: [0.07, 0.24, 0.49, 0.74, 0.91],
                          dark: zone(0.3), shadow: zone(-0.2), mid: zone(0.1),
                          light: zone(-0.4), bright: zone(0.6), global: zone(0.05))
        let colorAdjust = ColorAdjust(vibrance: 15, saturation: 25,
                                      density: 60, protectSkin: 40)
        let mixerBands: [MixerBand] = (0..<8).map { index in
            let i = Double(index)
            return MixerBand(hue: i + 1, sat: i - 4, lum: i * 2,
                             core: [20 + i, 25 + i], feather: [12 + i, 18 + i])
        }
        let develop = Develop(
            raw: rawParams,
            tone: tone,
            zones: zones,
            curve: curve,
            color: colorAdjust,
            mixer: Mixer(bands: mixerBands, uniformity: 30),
            pointColors: [swatch],
            detail: Detail(capture: CaptureSharpen(auto: false, radius: 1.3, amount: 120),
                           texture: 5, clarity: 6, dehaze: 7,
                           sharpen: ManualSharpen(amount: 40, radius: 1.8, detail: 55,
                                                  masking: 30, haloSuppression: 20)),
            denoise: Denoise(mode: .ai, amount: 65, model: "nafnet/2.1",
                             classic: ClassicNR(luma: 10, chroma: 20, hotPixels: 30,
                                                lumaDetail: 40, lumaContrast: 50,
                                                colorDetail: 60, colorSmoothness: 70,
                                                lumaUserSet: true, chromaUserSet: true)),
            geometry: Geometry(
                crop: Crop(x: 0.1, y: 0.2, w: 0.7, h: 0.6),
                angle: 2.5, flipH: true,
                upright: Upright(vertical: 1, horizontal: 2, rotate: 3, aspect: 4,
                                 scale: 110, offsetX: 5, offsetY: 6, strength: 80),
                lens: LensCorrections(
                    profile: false, removeCA: false,
                    defringe: Defringe(purpleAmount: 3, purpleHueLo: 31, purpleHueHi: 71,
                                       greenAmount: 4, greenHueLo: 41, greenHueHi: 61))),
            heal: Heal(strokesRef: "blob:xxh64:0000000000000001", count: 3,
                       // Every field off its decoder's fallback: clone, not heal; a
                       // source that is not the destination; non-default size, feather
                       // and opacity.
                       spots: [HealSpot(id: "spot-1", mode: .clone, x: 0.31, y: 0.42,
                                        sourceX: 0.55, sourceY: 0.61, radius: 0.023,
                                        feather: 35, opacity: 70)]))

        let look = Look(
            wheels: wheels,
            printerLights: PrinterLights(master: 1, r: 2, g: -3, b: 4),
            filmLab: FilmLab(stock: "lumen/portra400", amount: 80, exposure: 0.5,
                             pushPull: 1, halation: 30,
                             halationSize: 1.4, halationRedness: 70,
                             grain: FilmGrain(size: 1.2, amount: 40), printSize: "8x10"),
            primaries: Primaries(rHue: 1, rPurity: 2, gHue: 3, gPurity: 4,
                                 bHue: 5, bPurity: 6, tintHue: 7, tintPurity: 8),
            bw: BlackAndWhite(bands: [1, 2, 3, 4, 5, 6, 7, 8], enabled: false),
            vignette: -0.75,
            vignetteFeather: 80,
            // Every field off its default, including the two that have a non-zero one:
            // a sample agreeing with a default cannot tell a decoder that read the key
            // from one that did not, which is this fixture's whole premise.
            grain: CreativeGrain(amount: 42, size: 66, roughness: 24),
            render: RenderParams(preset: "Punchy", contrast: 1.4, skew: 0.2,
                                 huePreservation: 60, blackTarget: 2, whiteTarget: 105),
            lut: LUTReference(ref: "blob:xxh64:000000000000000a", name: "Kodachrome",
                              tap: .log, amount: 70))

        var component = MaskComponent(op: .subtract, kind: .similarityLine,
                                      amount: 70, invert: true)
        component.strokesRef = "blob:xxh64:0000000000000002"
        component.line = [0.1, 0.2, 0.8, 0.9]
        component.center = [0.5, 0.5]
        component.radii = [0.3, 0.2]
        component.rotation = 15
        component.feather = 40
        component.lo = 0.1
        component.hi = 0.8
        component.smooth = 25
        component.samples = [[0.3, 0.4, 0.5]]
        component.rangeAmount = 55
        component.chromaSel = 60
        component.lumaSel = 65
        component.model = "skyseg/1.3"
        component.prompt = [[0.4, 0.45]]
        component.personParts = ["faceSkin", "hair"]
        component.classes = ["sky", "water"]
        component.depthLo = 0.2
        component.depthHi = 0.7
        component.channel = .min
        component.points = [[0.2, 0.3, 0.1, 1]]
        component.maskRef = "5C0F6B8A-0000-4000-8000-000000000002"
        component.path = [[0.1, 0.1], [0.9, 0.15], [0.5, 0.85]]
        component.series = .midtones
        component.level = 3.5

        let adjust = LocalAdjust(
            exposure: 0.6, contrast: 12, highlights: -20, shadows: 18, whites: 6,
            blacks: -9, temp: 300, tint: -8, hue: 25, sat: 14, vibrance: 22,
            texture: 16, clarity: 17, dehaze: 18, sharpness: -19, noise: 21,
            noiseChroma: 23, moire: 24, defringe: 26, grainAmount: 27,
            colorTint: [0.5, 0.4, 0.3], colorTintStrength: 65,
            pointColors: [swatch], curve: curve, wheels: wheels)
        var populatedAdjust = adjust
        populatedAdjust.kelvin = 4300
        populatedAdjust.kelvinTint = -14

        let mask = Mask(id: "5C0F6B8A-0000-4000-8000-000000000001", name: "Sky & <sea>",
                        enabled: false, invert: true, amount: 150,
                        components: [component],
                        refine: MaskRefine(feather: 12, edge: -5, blur: 7,
                                           levelsLo: 10, levelsHi: 90, levelsGamma: 1.4),
                        adjust: populatedAdjust,
                        blend: .luminosity,
                        group: "8A1B0000-0000-4000-8000-0000000000f0")

        return Recipe(pipelineVersion: 1, develop: develop, look: look, masks: [mask],
                      maskGroups: [MaskGroup(id: "8A1B0000-0000-4000-8000-0000000000f0",
                                             name: "Retouch", enabled: false,
                                             amount: 65, collapsed: true)])
    }

    /// The saved-look root of the format, every field off its default (amount too:
    /// full strength is the default).
    static func lookSubset() -> LookSubset {
        LookSubset(pipelineVersion: 1, look: populated().look, amount: 60)
    }

    /// `populated()` adjusted so every rendered field is live, for fingerprint tests.
    ///
    /// The B&W mix is switched on (`renderIdentity` drops a mix that is off), and a
    /// second mask selects the first through a `.maskRef` component, so the recipe takes
    /// the reference-bearing path where a referenced mask's id is part of the picture.
    static func fingerprintSample() -> Recipe {
        var recipe = populated()
        recipe.look.bw?.enabled = true
        var ref = MaskComponent(op: .add, kind: .maskRef, amount: 90)
        ref.maskRef = recipe.masks[0].id
        recipe.masks.append(Mask(id: "5C0F6B8A-0000-4000-8000-000000000002",
                                 name: "Sky again", amount: 80, components: [ref]))
        return recipe
    }
}
