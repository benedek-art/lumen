// PlanKeyMemo.swift
// The canonical text of a plan key's recipe subtrees, remembered while they do not move.
//
// `RenderPlan.init` spells three `PlanTableCache` keys on every frame — colour+grade,
// finish, tone cube — and each spelling is a `CanonicalJSON.tree`, which is a full
// `JSONEncoder` round trip followed by a `JSONDecoder` into an indirect enum, of every
// subtree the table reads: eleven round trips a frame. Measured in a release build on
// the shared Linux container, those three spellings were 0.67 ms of a 1.40 ms plan on a
// Texture tick (48%) — a tick that changes none of the subtrees being spelled and hits
// all three tables. The tables were cached against exactly this; the text of their keys
// was not.
//
// Why this cannot change a pixel. The memo hands back a previous spelling only when the
// inputs are `==` to the ones it was spelled from, and the spelling is a pure function
// of the inputs: synthesized equality compares every stored property, the encoders are
// the compiler's (the subtrees here have no custom `encode(to:)`), and
// `CanonicalJSON.serialize` sorts keys and prints numbers by one rule — including the
// one case where `==` is looser than the bits, `-0.0 == 0.0`, which `canonicalNumber`
// already prints as "0" for both. So the key string is byte-identical to a fresh
// spelling, the cache returns the same table, and the frame is the same frame.
// `PlanKeyMemoTests` holds that, and holds the round-trip count.
//
// One entry per key, not a dictionary: a drag revisits one set of subtrees for its whole
// length, and two panes alternating merely re-spell, which is today's cost and no worse.

import Foundation

final class PlanKeyMemo<Inputs: Equatable>: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (inputs: Inputs, pieces: [String]?)?

    /// The canonical text of each of `encodables`, in order, or nil when one of them
    /// cannot be encoded — exactly the pieces `PlanTableCache.key` appends after its
    /// literal parts. `encodables` is only called on a miss.
    func pieces(for inputs: Inputs, _ encodables: () -> [any Encodable]) -> [String]? {
        lock.lock()
        if let last, last.inputs == inputs {
            lock.unlock()
            return last.pieces
        }
        lock.unlock()
        var pieces: [String]? = []
        for value in encodables() {
            guard let tree = try? CanonicalJSON.tree(of: value) else { pieces = nil; break }
            pieces?.append(CanonicalJSON.serialize(tree))
        }
        lock.lock()
        last = (inputs, pieces)
        lock.unlock()
        return pieces
    }

    /// `PlanTableCache.key(parts, encodables)`, spelled from remembered pieces: the
    /// literal parts, then each subtree's text, joined by "|". Nil when a subtree
    /// failed to encode, which the call site reads as "do not cache" — as before.
    func key(_ parts: [String], inputs: Inputs,
             _ encodables: () -> [any Encodable]) -> String? {
        pieces(for: inputs, encodables).map { (parts + $0).joined(separator: "|") }
    }
}

/// The three plans' key inputs, as values `==` can compare.
extension RenderPlan {
    /// The grade table's inputs. The colour stage runs exactly on every path now, so
    /// only the grade stays tabled and only its two subtrees spell its key.
    struct GradeKeyInputs: Equatable {
        var wheels: GradingWheels
        var printerLights: PrinterLights
    }

    struct FinishKeyInputs: Equatable {
        var render: RenderParams
        var curve: CurveSet
    }

    struct ToneKeyInputs: Equatable {
        var tone: Tone
        var zones: Zones
    }

    static let gradeKeyMemo = PlanKeyMemo<GradeKeyInputs>()
    static let finishKeyMemo = PlanKeyMemo<FinishKeyInputs>()
    static let filmKeyMemo = PlanKeyMemo<FilmLab>()
    static let toneKeyMemo = PlanKeyMemo<ToneKeyInputs>()
}
