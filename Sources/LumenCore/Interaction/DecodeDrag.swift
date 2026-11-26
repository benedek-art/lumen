// DecodeDrag.swift
// Three controls are read by the RAW decoder itself — capture sharpening's strength,
// the AI denoise amount (while it stands in through the decoder) and the lens-profile
// flag — so every new value of one is a new demosaic. The settle and the export must
// pay that in full; a draft under a moving hand may pay it on fewer pixels.

import Foundation

/// The recipe fields the RAW decoder reads. Two recipes that agree on these decode to
/// the same pixels at the same scale; `AppleRawSource` builds its cache key from them.
public struct DecodeInputs: Equatable, Sendable {
    public let captureStrength: Double
    public let luminanceNR: Double
    public let colorNR: Double
    public let lensProfile: Bool
    /// The decoder the recipe asks for; the source resolves it against what this OS has.
    public let decoderVersion: Int?
}

extension Recipe {
    public var decodeInputs: DecodeInputs {
        let standIn = develop.denoise.appleStandIn
        return DecodeInputs(captureStrength: develop.detail.capture.strengthFraction,
                            luminanceNR: standIn.luma,
                            colorNR: standIn.chroma,
                            lensProfile: develop.geometry.lens.profile,
                            decoderVersion: develop.raw.decoderVersion)
    }
}

/// How many pixels a draft is rendered at while a gesture is moving a decode input.
///
/// Measured, not assumed: drafts stay at their full size until one that paid a decode
/// costs more than `budgetMilliseconds`, then drop one step — half the long edge, a
/// quarter of the demosaic — and no further. The reduction only ever applies to
/// requests of a gesture that has moved a decode input; everything else, and every
/// settle, is untouched.
public struct DecodeDrag: Sendable, Equatable {

    /// A frame that pays a decode and still lands inside this keeps its full size.
    public static let budgetMilliseconds: Double = DraftLadder.stepDownOver

    /// One step and no more: past a 2× magnification a draft stops reading as the
    /// photograph resolving.
    public static let maxDivisor: Int = 2

    /// A reduced draft never goes below this long edge (or its own ask, if smaller).
    public static let floorLongEdge: Int = 1024

    /// A decode that took no longer than this was a cache hit.
    public static let hitCeilingMilliseconds: Double = 1.0

    public static func paidDecode(decodeMilliseconds: Double) -> Bool {
        decodeMilliseconds.isFinite && decodeMilliseconds > hitCeilingMilliseconds
    }

    public private(set) var divisor: Int = 1
    private var lastInputs: DecodeInputs?
    private var moving = false
    private var restoreEarned = false

    public init() {}

    /// True while the current gesture has moved a decode input and drafts are reduced.
    public var isReducing: Bool { moving && divisor > 1 }

    /// The long edge to render a draft at. `target` is what it would otherwise be.
    public mutating func longEdge(for target: Int, inputs: DecodeInputs,
                                  midGesture: Bool) -> Int {
        defer { lastInputs = inputs }
        guard midGesture else {
            moving = false
            return target
        }
        if let last = lastInputs, last != inputs { moving = true }
        return moving ? Self.reduced(target, by: divisor) : target
    }

    public static func reduced(_ target: Int, by divisor: Int) -> Int {
        guard divisor > 1, target > 0 else { return target }
        return Swift.max(target / divisor, Swift.min(target, floorLongEdge))
    }

    /// A draft landed. `milliseconds` is what rendering it cost; `divisor` is the one
    /// it was sized with.
    public mutating func record(milliseconds: Double, paidDecode: Bool, divisor used: Int) {
        guard moving, paidDecode, milliseconds.isFinite, milliseconds > 0 else { return }
        if used == divisor, milliseconds > Self.budgetMilliseconds {
            if divisor < Self.maxDivisor { divisor *= 2 }
            restoreEarned = false
            return
        }
        // Pixel-proportional, so an overestimate: if four times a reduced frame's cost
        // still fits, the full size does. Spent between gestures, never under the hand.
        if used > 1, used == divisor {
            restoreEarned = milliseconds * Double(used * used) < Self.budgetMilliseconds
        }
    }

    public mutating func gestureEnded() {
        if restoreEarned { divisor = 1 }
        restoreEarned = false
        moving = false
    }

    /// A different photograph: its decode costs something else.
    public mutating func reset() {
        self = DecodeDrag()
    }
}
