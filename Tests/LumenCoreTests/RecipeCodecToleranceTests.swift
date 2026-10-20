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
    /// field to the recipe means either populating it in `RecipeSamples.populated()` or
    /// watching this test go red.
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
        reach(RecipeSamples.populated(), at: "recipe", found: &found, holes: &holes)
        // A saved look is the other root of this format — `LookSubset` is stored in its
        // own catalog column and reaches the same `Look` subtree.
        reach(RecipeSamples.lookSubset(), at: "lookSubset", found: &found, holes: &holes)
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
                      + "`RecipeSamples.populated()` so the tolerance guard covers it:\n  "
                      + holes.map { "\($0.path): \($0.reason)" }.joined(separator: "\n  "))
    }

    /// The sample's other premise: no key is sampled ONLY at its decoder default.
    ///
    /// A key that agrees with `{}`'s decode everywhere it appears passes the drop-one-key
    /// check above whether the decoder reads it or not. Aggregated per type and key, not
    /// per instance: `mixer.bands[0].lum` is 0 legitimately because bands 1…7 are not.
    func testNoRecipeFieldIsSampledOnlyAtItsDefault() {
        let (found, _) = Self.walkTheSamples()
        var onlyAtDefault: [String: Bool] = [:]
        for reached in found {
            let empty = Self.json([:])
            guard let base = try? Self.decodedObject(like: reached.value, from: empty),
                  let again = try? Self.decodedObject(like: reached.value, from: empty)
            else { continue }   // reported by the tolerance test
            for key in reached.object.keys where base[key] == again[key] {
                let name = "\(reached.typeName).\(key)"
                let agrees = reached.object[key] == base[key]
                onlyAtDefault[name] = (onlyAtDefault[name] ?? true) && agrees
            }
        }
        XCTAssertGreaterThan(onlyAtDefault.count, 200, "the walk compared almost nothing")
        let stuck = onlyAtDefault.filter(\.value).keys.sorted()
        XCTAssertTrue(stuck.isEmpty,
                      "sampled only at the decoder default, so the tolerance guard "
                      + "cannot tell a decoder that reads the key from one that ignores "
                      + "it — set each off its default in `RecipeSamples.populated()`:\n  "
                      + stuck.joined(separator: "\n  "))
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

    /// Zone pivots are ORDERED, and padding must not hand the tone engine a list that
    /// does not ascend (M-03). `{"pivots":[0.9]}` padded to `[0.9, 0.5, …]` put every
    /// scene value below +3.6 EV in the Darks zone.
    func testAnOrderedArrayIsStillOrderedAfterTheDecoderFillsItIn() throws {
        let short = try JSONDecoder().decode(
            Zones.self, from: Data(#"{"pivots":[0.9]}"#.utf8))
        XCTAssertEqual(short.pivots, Zones.defaultPivots,
                       "the padding rule built a descending pivot array — every zone "
                           + "below the first pivot collapses onto Darks")

        // The engine, not just the value: Mids must still move a mid-tone.
        var zones = short
        zones.mid.ev = 1.0
        XCTAssertEqual(ToneEngine(tone: Tone(), zones: zones).zonePanelStops(0.0), 1.0,
                       accuracy: 1e-9, "the Mids slider moved and mid-grey did not")

        // A full-length list that merely arrived out of order is REPAIRED, not thrown
        // away — it is a list somebody wrote.
        let jumbled = try JSONDecoder().decode(
            Zones.self, from: Data(#"{"pivots":[0.8,0.2,0.5,0.35,0.65]}"#.utf8))
        XCTAssertEqual(jumbled.pivots, [0.2, 0.35, 0.5, 0.65, 0.8])

        // Coincident pivots are a division by zero in the crossfade: pushed apart by the
        // panel's own gap, so the strip and the picture agree.
        let touching = try JSONDecoder().decode(
            Zones.self, from: Data(#"{"pivots":[0.3,0.3,0.5,0.7,0.9]}"#.utf8))
        XCTAssertEqual(touching.pivots[1], 0.32, accuracy: 1e-12)
        XCTAssertTrue(zip(touching.pivots, touching.pivots.dropFirst()).allSatisfy { $0 < $1 })

        // Identity on what this app writes: an ascending list round-trips untouched.
        let own = [0.07, 0.24, 0.49, 0.74, 0.91]
        XCTAssertEqual(Zones.decodedPivots(own), own)
        XCTAssertEqual(Zones.decodedPivots(nil), Zones.defaultPivots)
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
}
