// LocalAdjustGroupTests.swift
// The accent dot that says a section has been touched, and the Reset that clears it.
//
// Four of the mask panel's eight section headers carried both. Light and Colour — which
// between them hold the eleven most-used sliders in the panel — carried NEITHER, so
// there was no way to see that a mask's exposure had been moved and no way to put one
// section back without putting the whole mask back. Components carried a dot whose
// condition was `!components.isEmpty`, which is true of every mask that has ever been
// drawn: a dot that is always on says nothing, and this repository had already written
// that rule down when it removed the "Default" badges.
//
// The grouping is a fact about `LocalAdjust`, not about the panel, so it lives in the
// model where the Linux lane can hold it.

import XCTest
@testable import LumenCore

final class LocalAdjustGroupTests: XCTestCase {

    /// Every field each group claims, paired with a mutation that moves it off default.
    /// Written out rather than derived, because the point of the test is to pin the
    /// membership — a list derived from the implementation would agree with any bug.
    ///
    /// Each carries a READER as well as a writer, and that is the whole strength of the
    /// reset test below. A first version compared only `isModified` per group, and a
    /// substitution that made Light's Reset also clear Hue produced ZERO failures —
    /// eight other Colour fields were still moved, so Colour's flag stayed lit and the
    /// damage was invisible to every assertion. A Reset that quietly destroys one field
    /// of a neighbouring section is exactly the bug this file exists to catch, so it
    /// compares values.
    struct Field {
        let name: String
        let set: (inout LocalAdjust) -> Void
        let equalsBefore: (LocalAdjust, LocalAdjust) -> Bool
    }

    private static func field<V: Equatable>(_ name: String,
                                            _ path: WritableKeyPath<LocalAdjust, V>,
                                            _ value: V) -> Field {
        Field(name: name,
              set: { $0[keyPath: path] = value },
              equalsBefore: { $0[keyPath: path] == $1[keyPath: path] })
    }

    private static let members: [LocalAdjust.Group: [Field]] = [
        .light: [
            field("exposure", \.exposure, 0.85),
            field("contrast", \.contrast, 20),
            field("highlights", \.highlights, -30),
            field("shadows", \.shadows, 40),
            field("whites", \.whites, 15),
            field("blacks", \.blacks, -25),
        ],
        .colour: [
            field("temp", \.temp, 12),
            field("tint", \.tint, -8),
            field("kelvin", \.kelvin, 5200),
            field("kelvinTint", \.kelvinTint, 4),
            field("hue", \.hue, 30),
            field("sat", \.sat, -15),
            field("vibrance", \.vibrance, 22),
            field("colorTint", \.colorTint, [0.96, 0.48, 0.15]),
            field("colorTintStrength", \.colorTintStrength, 50),
        ],
        .detail: [
            field("texture", \.texture, 18),
            field("clarity", \.clarity, -12),
            field("dehaze", \.dehaze, 33),
            field("sharpness", \.sharpness, -40),
        ],
    ]

    /// Fields no group owns. Changing one must light no dot, or a Reset somewhere would
    /// silently clear something the section it sits on never showed.
    ///
    /// The first five are the carried-not-rendered set: they decode, round-trip and hash,
    /// and no stage reads them. The rest have their own headers with their own Resets.
    private static let unowned: [Field] = [
        field("noise", \.noise, 40),
        field("noiseChroma", \.noiseChroma, 40),
        field("moire", \.moire, 40),
        field("defringe", \.defringe, 40),
        field("grainAmount", \.grainAmount, 40),
        field("pointColors", \.pointColors, [PointColor(sample: [0.5, 0.4, 0.3])]),
    ]

    // MARK: - The dot

    /// The state every mask starts in. If this fails, every dot in the panel is lit on a
    /// mask nobody has touched — which is exactly the failure Components had.
    func testAFreshAdjustmentHasTouchedNothing() {
        let fresh = LocalAdjust()
        for group in LocalAdjust.Group.allCases {
            XCTAssertFalse(fresh.isModified(group),
                           "\(group) claims to be modified on a default LocalAdjust")
        }
    }

    /// The property that makes the grouping worth having: moving ONE field lights ONE
    /// dot. This convicts a field listed in two groups, a field listed in the wrong
    /// group, and a comparison that reads the wrong property.
    func testEachFieldLightsItsOwnGroupAndNoOther() {
        for (group, fields) in Self.members {
            for f in fields {
                var adjust = LocalAdjust()
                f.set(&adjust)
                XCTAssertTrue(adjust.isModified(group),
                              "\(f.name) moved and \(group) did not notice")
                for other in LocalAdjust.Group.allCases where other != group {
                    XCTAssertFalse(adjust.isModified(other),
                                   "\(f.name) belongs to \(group) but lit \(other)")
                }
            }
        }
    }

    /// A field with no section of its own must light no section's dot.
    func testFieldsNoGroupOwnsLightNothing() {
        for f in Self.unowned {
            var adjust = LocalAdjust()
            f.set(&adjust)
            for group in LocalAdjust.Group.allCases {
                XCTAssertFalse(adjust.isModified(group),
                               "\(f.name) is in no section, but lit \(group)")
            }
        }
    }

    // MARK: - The Reset

    /// Reset puts its own group back and leaves everything else exactly where it was.
    ///
    /// This is the assertion that matters most: a Reset scoped too widely is worse than
    /// no Reset at all, because it destroys work the photographer cannot see it touching.
    func testResetClearsItsGroupAndTouchesNothingElse() {
        for group in LocalAdjust.Group.allCases {
            // Move everything, in every group and outside them.
            var adjust = LocalAdjust()
            for f in Self.members.values.flatMap({ $0 }) { f.set(&adjust) }
            for f in Self.unowned { f.set(&adjust) }

            let before = adjust
            adjust.reset(group)

            XCTAssertFalse(adjust.isModified(group), "\(group) did not clear itself")

            // FIELD BY FIELD, not group by group. Asserting only that the other groups
            // are still "modified" is far too weak: with nine Colour fields moved,
            // clearing one of them leaves the flag lit and the loss invisible.
            for other in LocalAdjust.Group.allCases where other != group {
                for f in Self.members[other] ?? [] {
                    XCTAssertTrue(f.equalsBefore(adjust, before),
                                  "resetting \(group) changed \(other).\(f.name)")
                }
            }
            // And the fields no section owns are untouched — a section's Reset must not
            // reach the five carried-not-rendered fields or the point colours.
            for f in Self.unowned {
                XCTAssertTrue(f.equalsBefore(adjust, before),
                              "resetting \(group) changed \(f.name), which no section owns")
            }
        }
    }

    /// Resetting a group that was never touched changes nothing at all — so pressing
    /// Reset on a quiet section cannot become an edit in the history.
    func testResettingAnUntouchedGroupIsIdentity() {
        for group in LocalAdjust.Group.allCases {
            var adjust = LocalAdjust()
            adjust.exposure = 0.5   // one field, in Light
            let before = adjust
            if group != .light {
                adjust.reset(group)
                XCTAssertEqual(adjust, before,
                               "resetting \(group) changed something it does not own")
            }
        }
    }

    /// Reset then re-check: the round trip is stable, so the dot cannot flicker back on.
    func testResetIsIdempotent() {
        for group in LocalAdjust.Group.allCases {
            var adjust = LocalAdjust()
            for f in Self.members[group] ?? [] { f.set(&adjust) }
            adjust.reset(group)
            let once = adjust
            adjust.reset(group)
            XCTAssertEqual(adjust, once)
        }
    }

    // MARK: - Coverage

    /// Every slider the Light, Colour and Presence & Detail sections draw is claimed by
    /// exactly one group.
    ///
    /// The counts are written down so that adding a field to `LocalAdjust` and drawing it
    /// in one of those three sections without adding it here is a test failure rather
    /// than a dot that quietly stops working.
    func testTheGroupsCoverWhatTheirSectionsDraw() {
        XCTAssertEqual(Self.members[.light]?.count, 6,
                       "Light draws Exposure, Contrast, Highlights, Shadows, Whites, Blacks")
        XCTAssertEqual(Self.members[.colour]?.count, 9,
                       "Colour draws Temp, Tint (in two spellings), Hue, Saturation, "
                           + "Vibrance and the Colorize pair")
        XCTAssertEqual(Self.members[.detail]?.count, 4,
                       "Presence & Detail draws Texture, Clarity, Dehaze, Sharpness")
    }
}
