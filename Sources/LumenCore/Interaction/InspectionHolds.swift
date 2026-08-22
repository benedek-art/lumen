// InspectionHolds.swift
// What `[` and `]` mean, and when — the whole rule, as a pure function, because two
// features want the same two keys and the app layer cannot be tested.
//
// THE COLLISION. docs/10 §10.5 gives `[` and `]` to Shadow Boost and Highlight Inspect:
// momentary holds that lift the shadows or pull the highlights while the key is down and
// snap back on key-up, so a keep/kill call can be made on what is actually in the frame.
// They are inspection, never an edit — they do not touch the recipe. The keymap already
// spends both keys on grid thumbnail size, unconditionally and with key-repeat, and that
// control works.
//
// THE RESOLUTION IS THE SURFACE, not a re-binding. `gridThumbnailSize` is read by
// exactly two things: the contact-sheet cell size and the slider in the filter bar. In
// the loupe, in Compare and in Survey the grid is not on screen, so `[` there was
// already adjusting a number nothing in front of the user was drawing — while the loupe
// is precisely where docs/10 §10.5 wants the holds, because it is the only place the
// picture is big enough to inspect. So the split is: the grid keeps the working control,
// and the three surfaces that show one photograph large get the holds. Neither feature
// loses anything a user could see, and neither key does two things at once anywhere.
//
// WHY IT LIVES HERE. A rule spread across a dispatcher's switch, a key-up handler and a
// repeat filter is a rule nobody can check. This file is the whole of it — surface
// split, key-repeat policy, hold pairing, the EV amounts and the gain they imply — and
// `InspectionHoldTests` asserts the parts against each other. The dispatcher's job is to
// call `resolve` and do what it says.

import Foundation

/// Where a key press is happening, as far as `[` and `]` are concerned. Four surfaces
/// because the split is between "a contact sheet is on screen" and "one photograph is",
/// and that is not the same distinction the browse cache's `PagingSurface` draws.
public enum InspectionSurface: String, Sendable, CaseIterable {
    /// The contact sheet.
    case grid
    /// One photograph, large.
    case loupe
    /// Two photographs side by side.
    case compare
    /// The survey grid of a selection.
    case survey
}

/// The two momentary inspections of docs/10 §10.5.
public enum InspectionHold: String, Sendable, CaseIterable {
    /// `[` — mnemonic: the left end of the histogram. Is there anything in the shadows?
    case shadowBoost
    /// `]` — the right end. Does highlight structure survive?
    case highlightInspect

    public var key: String {
        switch self {
        case .shadowBoost: return "["
        case .highlightInspect: return "]"
        }
    }

    /// Direction of the exposure move, in EV per configured stop.
    public var sign: Double {
        switch self {
        case .shadowBoost: return 1
        case .highlightInspect: return -1
        }
    }

    public var label: String {
        switch self {
        case .shadowBoost: return "Shadow boost"
        case .highlightInspect: return "Highlight inspect"
        }
    }

    /// What the badge over the picture says while the key is down. A momentary change
    /// to the picture that does not announce itself is indistinguishable from an edit.
    public func badge(stops: Double) -> String {
        let signed: String = sign > 0 ? "+" : "−"
        return label.uppercased() + " " + signed + InspectionHolds.stopsText(stops) + " EV"
    }
}

/// What the dispatcher should do with a `[` or `]` event.
public enum BracketAction: Equatable, Sendable {
    /// Not one of these keys, or nothing to do (an ignored auto-repeat, a key-up with
    /// no matching key-down). The dispatcher returns the event to the system.
    case ignore
    /// Step the contact sheet's cell size by this many points.
    case stepThumbnailSize(delta: Double)
    /// Start showing this inspection. The dispatcher records the key as held.
    case beginHold(InspectionHold)
    /// Stop showing it and put the picture back.
    case endHold(InspectionHold)
}

public enum InspectionHolds {

    /// The keys this rule owns. Named once so a test can assert the dispatcher's switch
    /// and this rule agree about which characters are in play.
    public static let keys: Set<String> = ["[", "]"]

    /// Surfaces where `[` and `]` size the contact sheet — where a contact sheet is what
    /// is on screen.
    public static let thumbnailSurfaces: Set<InspectionSurface> = [.grid]

    /// Surfaces where they are the momentary inspections — where one photograph is.
    public static let holdSurfaces: Set<InspectionSurface> = [.loupe, .compare, .survey]

    /// Points per press, matching what the keymap already did so the grid's control is
    /// unchanged in the place it was ever visible.
    public static let thumbnailStep: Double = 24

    /// docs/10 §10.5: ±3 EV by default, configurable to 2 or 4.
    public static let defaultStops: Double = 3
    public static let configurableStops: [Double] = [2, 3, 4]

    /// The linear-light gain a hold applies, at a given number of stops.
    ///
    /// Gain, not a slider value: the hold is a display transform over the frame already
    /// on screen (docs/10 §10.5 — "held, not applied"), so it multiplies light and
    /// never reaches the recipe. Nothing in this module returns anything a recipe could
    /// be built from, which is the strongest form the "never an edit" rule can take in
    /// code that a test can read.
    public static func gain(_ hold: InspectionHold, stops: Double = defaultStops) -> Double {
        pow(2.0, ev(hold, stops: stops))
    }

    /// The same move in EV, for the display filter that takes stops rather than a
    /// multiplier. Two spellings of one number, derived from each other so a caller
    /// cannot pick up the magnitude and lose the sign.
    public static func ev(_ hold: InspectionHold, stops: Double = defaultStops) -> Double {
        hold.sign * clampStops(stops)
    }

    /// Stops outside the configured range are a caller bug, not a licence to apply an
    /// arbitrary exposure: a hold that could be handed 40 would white out the frame and
    /// look like a render failure.
    public static func clampStops(_ stops: Double) -> Double {
        guard stops.isFinite else { return defaultStops }
        let low: Double = configurableStops.min() ?? defaultStops
        let high: Double = configurableStops.max() ?? defaultStops
        return Swift.min(Swift.max(stops, low), high)
    }

    /// The hold a key names, or nil if it names neither.
    public static func hold(forKey key: String) -> InspectionHold? {
        InspectionHold.allCases.first { $0.key == key }
    }

    /// The whole rule, in one place.
    ///
    /// - `key`: the character, already lowercased by the dispatcher.
    /// - `surface`: what is on screen.
    /// - `isKeyDown`: false for key-up.
    /// - `isRepeat`: the OS's auto-repeat flag.
    /// - `holdActive`: the key the dispatcher currently has held, if any. Passing it in
    ///   rather than keeping it here is what makes this a function: one dispatcher owns
    ///   the state, and the rule stays testable in every combination of it.
    ///
    /// Three behaviours worth naming, because each is a bug if it goes the other way:
    ///
    ///   · auto-repeat keeps sizing thumbnails (holding `]` should walk the cells up,
    ///     which is what it already did) and is DROPPED for a hold, because a repeat
    ///     would re-enter a gesture that is already running;
    ///   · a key-up only ends the hold that key started. A `]` release while `[` is held
    ///     must not cancel `[`, or rolling off one key onto the other leaves the picture
    ///     boosted with nothing holding it;
    ///   · a hold cannot begin while another is held. Two exposure gains at once is not
    ///     a state either key's release could unwind.
    public static func resolve(key: String,
                               surface: InspectionSurface,
                               isKeyDown: Bool,
                               isRepeat: Bool = false,
                               holdActive: String? = nil) -> BracketAction {
        guard keys.contains(key), let hold = hold(forKey: key) else { return .ignore }

        if !isKeyDown {
            // A key-up is answered by the state, never by the surface: releasing `[`
            // after switching from the loupe to the grid mid-hold has to end the hold,
            // or the boost sticks with no key holding it.
            guard holdActive == key else { return .ignore }
            return .endHold(hold)
        }

        if thumbnailSurfaces.contains(surface) {
            // A hold that survived a switch to the grid still owns its key: its release
            // must reach `endHold`, so its repeats are not thumbnail steps.
            if holdActive == key { return .ignore }
            return .stepThumbnailSize(delta: hold == .shadowBoost ? -thumbnailStep
                                                                 : thumbnailStep)
        }

        guard holdSurfaces.contains(surface) else { return .ignore }
        if isRepeat { return .ignore }
        guard holdActive == nil else { return .ignore }
        return .beginHold(hold)
    }

    /// `3` rather than `3.0`, and `2.5` when somebody configures a half stop.
    static func stopsText(_ stops: Double) -> String {
        let value: Double = clampStops(stops)
        if value == value.rounded() { return String(Int(value)) }
        return String(format: "%.1f", value)
    }
}
