// RecipeCodecToleranceTests.swift
// One property, over every Codable type a recipe is made of: A RECIPE MUST NOT BE LOST
// TO AN ABSENT KEY.
//
// The failure this exists to end, reported off a real folder of RAWs:
//
//     Could not register pix with the catalog — DecodingError.keyNotFound: Key 'core'
//     not found in keyed decoding container. Path: develop.mixer.bands[0].
//
// `MixerBand.core` and `.feather` were added after that catalog was written. They are
// non-optional and had no `init(from:)`, so Swift's SYNTHESIZED decoder REQUIRED them,
// and every recipe stored before they existed failed to decode. It is worth being
// precise about why the sparse format did not already cover this: `CanonicalJSON`
// merges a default recipe under the stored one before decoding, which fills in any
// absent OBJECT key — but `merge` replaces arrays wholesale, so the eight band objects
// inside `develop.mixer.bands` arrive exactly as they were written, with no defaults
// underneath them. Every array of objects in the format is the same hole:
// `mixer.bands`, `masks`, `develop.pointColors`, `mask.components`.
//
// So the guard is not "MixerBand decodes". It is every type, every key, and it has to
// keep being every type and every key after somebody adds the next field. Which is why
// NOTHING HERE IS A LIST. The types come from walking a populated recipe with `Mirror`;
// the keys come from that value's own encoded JSON; the default each key must fall back
// to comes from decoding the empty object `{}`. A hand-maintained list of types is
// exactly how this hole stayed open for 36 of the 39 types in the recipe layer, and a
// hand-maintained list is a thing that can be forgotten. A walk cannot be.
//
// The three types that were already tolerant — `ClassicNR`, `BlackAndWhite`, `Mask` —
// each got their decoder reactively, when somebody hit this same wall. Their decoders
// are the pattern the other thirty-eight now follow.

import XCTest
@testable import LumenCore

final class RecipeCodecToleranceTests: XCTestCase {

    // MARK: - The walk

    /// One Codable value found inside a populated recipe: where it was found, the value
    /// itself (kept so its own dynamic type can decode candidate documents), and its
    /// encoded JSON object.
    ///
    /// The value is carried rather than its type NAME because a name would need a table
    /// mapping names back to types, and that table is the hand-written list this file
    /// refuses to have. Passing the value to a generic function opens the existential
    /// and binds the concrete type, so the set of types under test is defined entirely
    /// by what the walk reaches.
    private struct Reached {
        let path: String
        let value: any Codable
        let object: [String: JSONValue]
        var typeName: String { "\(type(of: value))" }
    }

    /// A place the sample recipe left empty, so nothing below it could be walked.
    ///
    /// These are what stop this guard from rotting. A new optional field, or a new
    /// array field, is invisible to the walk until something populates it — so an
    /// unpopulated one is a FAILURE here rather than a silent gap in coverage. Adding a
    /// field to the recipe means either populating it in `populated()` or watching this
    /// test go red.
    private struct Hole {
        let path: String
        let reason: String
    }

    private static func encodedObject(_ value: any Encodable) -> [String: JSONValue]? {
        guard let data = try? JSONEncoder().encode(value),
              let tree = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = tree
        else { return nil }
        return object
    }

    /// Walk a value, collecting every Codable subtree that encodes as a JSON object.
    ///
    /// Primitives, raw-value enums and arrays all encode as something other than an
    /// object, so they are stepped over rather than listed: a `String` or a `MaskKind`
    /// has no keys to lose. Arrays are still descended into, because the elements are
    /// where the format's objects hide — `develop.mixer.bands[0]` is the whole reason
    /// this file exists.
    private static func reach(_ value: Any, at path: String,
                              found: inout [Reached], holes: inout [Hole]) {
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            guard let wrapped = mirror.children.first?.value else {
                holes.append(Hole(path: path, reason: "optional left nil"))
                return
            }
            reach(wrapped, at: path, found: &found, holes: &holes)
        case .collection:
            if mirror.children.isEmpty {
                holes.append(Hole(path: path, reason: "collection left empty"))
                return
            }
            for (index, child) in mirror.children.enumerated() {
                reach(child.value, at: "\(path)[\(index)]", found: &found, holes: &holes)
            }
        default:
            guard let codable = value as? any Codable,
                  let object = encodedObject(codable)
            else { return }
            found.append(Reached(path: path, value: codable, object: object))
            for child in mirror.children {
                reach(child.value, at: path + "." + (child.label ?? "?"),
                      found: &found, holes: &holes)
            }
        }
    }

    private struct ReEncodeFailed: Error {}

    /// Decode `data` as the same type as `like`, and hand back what it re-encodes to.
    ///
    /// The concrete type comes from opening the existential at the call site, which is
    /// what keeps the type list out of this file. `T` deliberately does not appear in
    /// the RESULT: every caller wants the keys back rather than the value, and a
    /// generic result would only be erased to `any Codable` again on the way out.
    private static func decodedObject<T: Codable>(
        like: T, from data: Data) throws -> [String: JSONValue] {
        let value = try JSONDecoder().decode(T.self, from: data)
        guard let object = encodedObject(value) else { throw ReEncodeFailed() }
        return object
    }

    private static func json(_ object: [String: JSONValue]) -> Data {
        Data(CanonicalJSON.serialize(.object(object)).utf8)
    }

    private static func walkTheSamples() -> (found: [Reached], holes: [Hole]) {
        var found: [Reached] = []
        var holes: [Hole] = []
        reach(populated(), at: "recipe", found: &found, holes: &holes)
        // A saved look is the other root of this format — `LookSubset` is stored in its
        // own catalog column and reaches the same `Look` subtree.
        reach(LookSubset(pipelineVersion: 1, look: populated().look),
              at: "lookSubset", found: &found, holes: &holes)
        return (found, holes)
    }

    // MARK: - The guard

    /// Every type, every key: remove one key from a fully-populated encoding and the
    /// value must still decode, with that one field at its default and every OTHER
    /// field exactly as it was written.
    ///
    /// "Its default" is read from decoding `{}` rather than transcribed here, so this
    /// test cannot disagree with the memberwise initializers about what a default is —
    /// and so a decoder that quietly invents a new fallback fails instead of being
    /// documented by the test that was supposed to police it.
    ///
    /// The second half — every other field unchanged — is the one that catches the
    /// mistake this many hand-written decoders invite: a copy-pasted `decodeIfPresent`
    /// left reading the wrong key, which a "does it throw" test would call a pass.
    func testEveryRecipeTypeSurvivesTheLossOfAnyOneKey() {
        let (found, _) = Self.walkTheSamples()
        XCTAssertFalse(found.isEmpty, "the walk reached nothing — Mirror change?")

        var failures: [String] = []
        var typesSeen: Set<String> = []

        for reached in found {
            typesSeen.insert(reached.typeName)

            // The all-defaults instance, and a second one so that a default which is
            // not a constant (`Mask.id` is a fresh UUID) is detected rather than
            // asserted against.
            let empty = Self.json([:])
            guard let baseObject = try? Self.decodedObject(like: reached.value,
                                                           from: empty),
                  let againObject = try? Self.decodedObject(like: reached.value,
                                                            from: empty)
            else {
                failures.append("\(reached.typeName) at \(reached.path): "
                                + "cannot decode from {} — no key is optional")
                continue
            }
            let volatileKeys = Set(baseObject.keys.filter {
                baseObject[$0] != againObject[$0]
            })

            for key in reached.object.keys.sorted() {
                var reduced = reached.object
                reduced[key] = nil
                let after: [String: JSONValue]
                do {
                    after = try Self.decodedObject(like: reached.value,
                                                   from: Self.json(reduced))
                } catch {
                    failures.append("\(reached.typeName).\(key) at \(reached.path): "
                                    + "\(error)")
                    continue
                }
                if !volatileKeys.contains(key), after[key] != baseObject[key] {
                    failures.append(
                        "\(reached.typeName).\(key) fell back to "
                        + "\(after[key].map { CanonicalJSON.serialize($0) } ?? "absent") "
                        + "and the memberwise default is "
                        + "\(baseObject[key].map { CanonicalJSON.serialize($0) } ?? "absent")")
                }
                for other in reached.object.keys where other != key {
                    if after[other] != reached.object[other] {
                        failures.append(
                            "\(reached.typeName): dropping '\(key)' also changed "
                            + "'\(other)'")
                    }
                }
            }
        }

        XCTAssertTrue(failures.isEmpty,
                      "\(failures.count) tolerance failures across "
                      + "\(typesSeen.count) types:\n  " + failures.joined(separator: "\n  "))
    }

    /// The sample recipe must leave nothing unpopulated, or the walk above silently
    /// stops covering whatever sits below the gap.
    ///
    /// This is the half that makes the guard un-rottable, and it is separate from the
    /// tolerance test on purpose: "somebody added a field and did not populate it" and
    /// "a type is not tolerant" are different jobs for whoever reads the failure.
    func testTheSampleRecipeLeavesNoFieldUnpopulated() {
        let (_, holes) = Self.walkTheSamples()
        XCTAssertTrue(holes.isEmpty,
                      "\(holes.count) unwalked field(s) — populate each in "
                      + "`populated()` so the tolerance guard covers it:\n  "
                      + holes.map { "\($0.path): \($0.reason)" }.joined(separator: "\n  "))
    }

    /// And the walk must actually be reaching the whole format, not a corner of it.
    ///
    /// A floor rather than an equality: a new recipe type should not have to edit a
    /// number here, but the walk quietly reaching four types instead of forty-one —
    /// a `Mirror` behaviour change, a sample recipe gutted by a bad merge — must not
    /// present as a green suite.
    func testTheWalkReachesTheWholeRecipeFormat() {
        let (found, _) = Self.walkTheSamples()
        let types = Set(found.map(\.typeName))
        XCTAssertGreaterThanOrEqual(
            types.count, 41,
            "the walk reached only \(types.count) types: \(types.sorted())")
        for expected in ["MixerBand", "Mask", "MaskComponent", "PointColor",
                         "ColorBalanceAxis", "LookSubset"] {
            XCTAssertTrue(types.contains(expected),
                          "the walk never reached \(expected)")
        }
    }

    // MARK: - The failure as it was reported

    /// The owner's catalog row, in the shape the build that wrote it produced: mixer
    /// bands with hue/sat/lum and no `core` or `feather`.
    ///
    /// Through `CanonicalJSON.decodeRecipe`, which is the exact call
    /// `CatalogStore.currentRecipe` makes — so this is the reported failure and not a
    /// reconstruction of it.
    func testTheCatalogRowThatCouldNotBeRegistered() throws {
        let stored = """
        {"pipelineVersion":1,\
        "develop":{"mixer":{"bands":[\
        {"hue":10,"lum":0,"sat":-20},{"hue":0,"lum":0,"sat":0},\
        {"hue":0,"lum":0,"sat":0},{"hue":0,"lum":0,"sat":0},\
        {"hue":0,"lum":0,"sat":0},{"hue":0,"lum":0,"sat":0},\
        {"hue":0,"lum":0,"sat":0},{"hue":0,"lum":0,"sat":0}],"uniformity":0},\
        "tone":{"exposure":0.35}}}
        """
        let recipe = try CanonicalJSON.decodeRecipe(from: Data(stored.utf8))

        XCTAssertEqual(recipe.develop.mixer.bands.count, 8)
        XCTAssertEqual(recipe.develop.mixer.bands[0].hue, 10)
        XCTAssertEqual(recipe.develop.mixer.bands[0].sat, -20)
        XCTAssertEqual(recipe.develop.mixer.bands[0].core, MixerBand.defaultCore,
                       "an absent core must arrive at the engine's own arc")
        XCTAssertEqual(recipe.develop.mixer.bands[0].feather, MixerBand.defaultFeather)
        XCTAssertEqual(recipe.develop.tone.exposure, 0.35,
                       "the edit either survives whole or it was not worth decoding")
    }

    /// The version a recipe was WRITTEN at survives a decode that had to fall back for
    /// other keys.
    ///
    /// A tolerant decoder is one absent-mindedly-placed `??` away from stamping the
    /// current version onto every old recipe it reads, at which point the catalog is
    /// full of documents claiming a vocabulary they are not written in — and
    /// `LookSubset.applied(to:)`, which takes `max` of two versions precisely so a v1
    /// slice cannot mislabel a v2 recipe, would be deciding on a lie.
    func testARecipeWrittenAtAnOlderVersionStillReportsThatVersion() throws {
        let v1 = """
        {"pipelineVersion":1,"develop":{"mixer":{"bands":[{"hue":10}]}},\
        "look":{"bw":{"bands":[0,0,0,0,-40,-65,0,0]}}}
        """
        let recipe = try CanonicalJSON.decodeRecipe(from: Data(v1.utf8))
        XCTAssertEqual(recipe.pipelineVersion, 1,
                       "a v1 recipe must not come back claiming v\(currentPipelineVersion)")
        XCTAssertEqual(recipe.look.bw?.enabled, true,
                       "v1 spelled 'on' by the slot being present")

        // And a document that carries no version at all is the current one, which is
        // what `Recipe()`'s own default says.
        let none = try CanonicalJSON.decodeRecipe(from: Data("{}".utf8))
        XCTAssertEqual(none.pipelineVersion, currentPipelineVersion)

        // The same through the plain decoder, with no default merged underneath.
        let bare = try JSONDecoder().decode(
            Recipe.self, from: Data(#"{"pipelineVersion":1}"#.utf8))
        XCTAssertEqual(bare.pipelineVersion, 1)
    }

    // MARK: - Arrays that arrive the wrong length

    /// A fixed-length array that arrives short keeps what it has and is filled out from
    /// the default; one that arrives long is truncated.
    ///
    /// Throwing away the whole array and using the default would be the easy rule and
    /// it is the wrong one: six real mixer bands would be lost because two were
    /// missing, which is the same class of loss as failing to decode at all.
    func testAFixedLengthArrayIsFilledOutRatherThanDiscarded() throws {
        let short = try JSONDecoder().decode(
            MixerBand.self, from: Data(#"{"hue":5,"sat":6,"lum":7,"core":[30]}"#.utf8))
        XCTAssertEqual(short.core, [30, MixerBand.defaultCore[1]],
                       "the handle that WAS written must survive")
        XCTAssertEqual(short.feather, MixerBand.defaultFeather)

        let long = try JSONDecoder().decode(
            MixerBand.self,
            from: Data(#"{"hue":0,"sat":0,"lum":0,"core":[1,2,3,4]}"#.utf8))
        XCTAssertEqual(long.core, [1, 2], "a long array must be cut to the pair a band has")

        let bands = try JSONDecoder().decode(
            Mixer.self, from: Data(#"{"bands":[{"hue":9}],"uniformity":3}"#.utf8))
        XCTAssertEqual(bands.bands.count, 8, "the mixer is always eight bands")
        XCTAssertEqual(bands.bands[0].hue, 9)
        XCTAssertEqual(bands.bands[7], MixerBand())

        let zones = try JSONDecoder().decode(
            Zones.self, from: Data(#"{"pivots":[0.1,0.2]}"#.utf8))
        XCTAssertEqual(zones.pivots.count, Zones.defaultPivots.count)
        XCTAssertEqual(zones.pivots[0], 0.1)
        XCTAssertEqual(zones.pivots[4], Zones.defaultPivots[4])

        let grade = try JSONDecoder().decode(
            GradingWheels.self, from: Data(#"{"pivots":[]}"#.utf8))
        XCTAssertEqual(grade.pivots, GradingWheels.defaultPivots)

        let splits = try JSONDecoder().decode(
            ParametricCurve.self, from: Data(#"{"splits":[0.3,0.6,0.9,1.2,1.5]}"#.utf8))
        XCTAssertEqual(splits.splits, [0.3, 0.6, 0.9])

        let mix = try JSONDecoder().decode(
            BlackAndWhite.self, from: Data(#"{"bands":[10,20]}"#.utf8))
        XCTAssertEqual(mix.bands.count, 8, "the B&W mix is eight bands or it index-crashes")
        XCTAssertEqual(mix.bands[0], 10)
        XCTAssertEqual(mix.bands[7], 0)

        let zone = try JSONDecoder().decode(ZoneAdjust.self, from: Data(#"{"wheel":[1]}"#.utf8))
        XCTAssertEqual(zone.wheel, [1, 0])

        let swatch = try JSONDecoder().decode(
            PointColor.self, from: Data(#"{"sample":[0.5]}"#.utf8))
        XCTAssertEqual(swatch.sample, [0.5, 0, 0], "a swatch is a working-space triple")
    }

    /// A wrong-length array must not survive the decode only to be indexed later.
    ///
    /// `ColorEngine` reads `bw.bands[i]` for eight bands and `pc.sample[0…2]`, and the
    /// panel reads the same triple with no guard at all. The rule above is what makes
    /// those reads safe, so it is asserted at the point of use and not only at the
    /// point of decode.
    func testAShortArrayFromAnOlderBuildCannotIndexCrashDownstream() throws {
        let recipe = try CanonicalJSON.decodeRecipe(from: Data("""
        {"develop":{"pointColors":[{"range":50,"sample":[0.4]}],\
        "mixer":{"bands":[{"hue":1},{"hue":2}]},"zones":{"pivots":[0.5]}},\
        "look":{"bw":{"bands":[30]}}}
        """.utf8))
        XCTAssertEqual(recipe.develop.pointColors[0].sample.count, 3)
        XCTAssertEqual(recipe.develop.mixer.bands.count, 8)
        XCTAssertEqual(recipe.develop.zones.pivots.count, Zones.defaultPivots.count)
        XCTAssertEqual(recipe.look.bw?.bands.count, 8)
        for band in recipe.develop.mixer.bands {
            XCTAssertEqual(band.core.count, 2)
            XCTAssertEqual(band.feather.count, 2)
        }
    }

    // MARK: - The sample

    /// A recipe with every field set to something that is NOT its default, every
    /// optional present and every collection non-empty.
    ///
    /// Nothing here is a default on purpose: a sample that agreed with the defaults
    /// would make "the field came back at its default" true whether the decoder read
    /// the key or not, which is a test that cannot fail.
    private static func populated() -> Recipe {
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
            heal: Heal(strokesRef: "blob:xxh64:0000000000000001", count: 3))

        let look = Look(
            wheels: wheels,
            printerLights: PrinterLights(master: 1, r: 2, g: -3, b: 4),
            filmLab: FilmLab(stock: "lumen/portra400", amount: 80, exposure: 0.5,
                             pushPull: 1, halation: 30,
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

        let mask = Mask(id: "5C0F6B8A-0000-4000-8000-000000000001", name: "Sky",
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
}
