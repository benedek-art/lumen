// BurstPick.swift
// "Pick Sharpest in Each Burst": the culling pass's burst ranking turned into flag
// decisions, on request.
//
// The evidence already existed — every frame carries its burst and its place in the
// burst's sharpness order (`CullingAttention.burstRank`) — and nothing turned it into a
// decision, so a 10 fps soccer sequence still meant pressing P by hand on each burst's
// best frame. D37 still holds: this runs only when the photographer asks, the app
// confirms the count first, it is one undo step, and rejects are a separate, explicit
// choice. Nothing here ever runs during a scan.
//
// The rules, each pinned by `BurstPickTests`:
//   · a burst counts only when at least two of its frames are in scope — one frame of a
//     burst is not a choice between frames;
//   · the best frame is the lowest rank in scope (a partial selection still has a best),
//     then the higher sharpness, then the earlier frame;
//   · a burst the photographer has already decided — any frame picked, or the best
//     frame rejected — is left alone and counted;
//   · "reject the rest" only touches UNFLAGGED frames of bursts that get a pick here.

import Foundation

public struct BurstPickFrame<ID: Hashable>: Equatable {
    public var id: ID
    public var burstID: Int64?
    public var burstRank: Int?
    public var sharpness: Double?
    public var flag: PhotoFlag

    public init(id: ID, burstID: Int64?, burstRank: Int?, sharpness: Double?,
                flag: PhotoFlag) {
        self.id = id
        self.burstID = burstID
        self.burstRank = burstRank
        self.sharpness = sharpness
        self.flag = flag
    }
}

public struct BurstPickPlan<ID: Hashable>: Equatable {
    /// One frame per burst to flag Pick, in the order the bursts first appear.
    public var picks: [ID] = []
    /// The unflagged other frames of those same bursts, for "reject the rest".
    public var rest: [ID] = []
    /// Bursts in scope with at least two frames.
    public var bursts: Int = 0
    /// Of those, the ones skipped because the photographer already decided them.
    public var alreadyDecided: Int = 0

    public init() {}

    /// The flags to write. Rejects only when asked for.
    public func decisions(rejectRest: Bool) -> [ID: PhotoFlag] {
        var result: [ID: PhotoFlag] = [:]
        for id in picks { result[id] = .pick }
        if rejectRest {
            for id in rest { result[id] = .reject }
        }
        return result
    }
}

public enum BurstPick {

    public static func plan<ID: Hashable>(_ frames: [BurstPickFrame<ID>]) -> BurstPickPlan<ID> {
        var order: [Int64] = []
        var groups: [Int64: [(index: Int, frame: BurstPickFrame<ID>)]] = [:]
        for (index, frame) in frames.enumerated() {
            guard let burst = frame.burstID else { continue }
            if groups[burst] == nil { order.append(burst) }
            groups[burst, default: []].append((index, frame))
        }

        var plan = BurstPickPlan<ID>()
        for burst in order {
            guard let members = groups[burst], members.count >= 2 else { continue }
            plan.bursts += 1
            guard let best = members.min(by: { isBetter($0, than: $1) }) else { continue }
            if members.contains(where: { $0.frame.flag == .pick })
                || best.frame.flag == .reject {
                plan.alreadyDecided += 1
                continue
            }
            plan.picks.append(best.frame.id)
            for member in members where member.index != best.index
                && member.frame.flag == .unflagged {
                plan.rest.append(member.frame.id)
            }
        }
        return plan
    }

    /// Lower rank first (a missing rank last), then higher sharpness (a missing score
    /// lowest), then the earlier frame.
    private static func isBetter<ID>(_ a: (index: Int, frame: BurstPickFrame<ID>),
                                     than b: (index: Int, frame: BurstPickFrame<ID>)) -> Bool {
        let rankA = a.frame.burstRank ?? Int.max
        let rankB = b.frame.burstRank ?? Int.max
        if rankA != rankB { return rankA < rankB }
        let sharpA = a.frame.sharpness ?? -Double.infinity
        let sharpB = b.frame.sharpness ?? -Double.infinity
        if sharpA != sharpB { return sharpA > sharpB }
        return a.index < b.index
    }

    /// The confirmation's sentence, so the count the photographer agrees to is the
    /// count that gets written.
    public static func confirmation<ID>(_ plan: BurstPickPlan<ID>) -> String {
        var text = "Flags the sharpest frame Pick in \(plan.picks.count) "
            + (plan.picks.count == 1 ? "burst" : "bursts") + "."
        if plan.alreadyDecided > 0 {
            text += " \(plan.alreadyDecided) "
                + (plan.alreadyDecided == 1 ? "burst already has" : "bursts already have")
                + " a decision and will be left alone."
        }
        text += " The ranking is evidence from the culling pass, not a verdict; ⌘Z takes "
            + "the whole step back."
        return text
    }
}
