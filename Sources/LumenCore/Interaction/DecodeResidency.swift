// DecodeResidency.swift
// THE PROCESS-WIDE CEILING ON HELD RAW DECODES — the arithmetic, in LumenCore, where a
// lane without a Mac can run it.
//
// The rule used to be a constant and two loops inside `RenderCoordinator`, in LumenApp,
// which no CI lane builds. What that bought is the defect this file exists to end:
// the constant said 768 MiB and the loops could not get under 1792 MiB, and nothing
// anywhere could notice, because the number was a comment and the loops were a
// different comment. A budget that no test can multiply out is a claim, not a bound.
//
// So the two halves are separated here and both are pure:
//
// · `processBudgetBytes` is DERIVED from the per-source bounds it has to accommodate,
//   rather than chosen as a round number and hoped for. A budget below what one
//   photograph is allowed to hold cannot be met by any trim, however aggressive —
//   short of taking the decode of the photograph currently on screen, which
//   manufactures exactly the repeated demosaic the decode cache exists to prevent.
//   That inequality is `budgetCoversOneSource`, and it is the assertion that makes the
//   number honest instead of aspirational.
//
// · `releaseOrder` is the trim's whole policy: which source gives up what, in which
//   order, given only how many sources there are. `RenderCoordinator` walks it and
//   subtracts what each release actually freed; `residualBytes` walks the same order
//   against modelled holdings, so the bound can be PROVED here rather than asserted
//   about a file that does not compile on this machine.

import Foundation

/// What the app is willing to hold as decoded pixels, and how it gets back under that
/// line when it is over.
public enum DecodeResidency {

    // MARK: - The two per-source bounds this is built out of

    /// The interactive working set one source may hold — the viewer's settle, the rung
    /// under the hand, the 512 px probes, the mask raster.
    ///
    /// A MIRROR of `AppleRawSource.decodeCacheByteBudget`, which is `private` inside
    /// `#if os(macOS)` and therefore unreadable from any lane that can run a test. The
    /// duplication is deliberate and is the lesser of two evils: the alternative is a
    /// process budget derived from numbers it cannot see, which is how 768 came to be
    /// written beside a floor of 1792. The two are pinned to each other by a text scan
    /// (`RenderBudgetTests`), so a change to either that is not made to the other goes
    /// red rather than silent.
    public static let interactiveWorkingSetBytes: Int = 320 * 1024 * 1024

    /// THE MOST ONE SOURCE CAN HOLD, and the number the whole budget is anchored to.
    ///
    /// Two classes, bounded separately by `AppleRawSource.evictDecodes`:
    ///
    /// · the interactive working set, bounded by `interactiveWorkingSetBytes` — EXCEPT
    ///   that the byte loop refuses to evict below one entry (`count > 1`), so a single
    ///   entry larger than the budget survives it. What bounds that one is
    ///   `DraftLadder.mayHoldAsPixels`, which is why the ceiling below is a `max` and
    ///   not the interactive budget alone. It is reachable: an interactive ask is
    ///   capped at `interactiveLongEdgeCeiling`, `CIRAWFilter.scaleFactor` is a request
    ///   a decoder may decline, and a declined 4096 px ask on a 60 MP body delivers
    ///   9504 × 6336 × 8 = 459 MiB in one entry.
    ///
    /// · at most one native inspection plane, EXEMPT from that budget so a settle at
    ///   zoom is not alternate-evicted by the drag beneath it, and bounded only by
    ///   `DraftLadder.materializedDecodeByteCeiling`.
    ///
    /// Nothing may take these from the photograph currently being rendered, which is
    /// what makes this a floor rather than a target: it is the residency the app has
    /// already decided is worth its cost, for exactly one photograph.
    public static var sourceCeilingBytes: Int {
        Swift.max(interactiveWorkingSetBytes, DraftLadder.materializedDecodeByteCeiling)
            + DraftLadder.materializedDecodeByteCeiling
    }

    // MARK: - The budget

    /// THE PROCESS-WIDE BUDGET, DERIVED RATHER THAN DECLARED.
    ///
    /// One photograph entire — its interactive working set and its inspection plane —
    /// plus a second photograph's working set beside it, which is what a compare pane
    /// and a before/after need and what the trim must therefore not take.
    ///
    /// That sentence is the one the old 768 MiB constant carried word for word, and
    /// the arithmetic under it had never been done: one inspection plane (512 MiB) and
    /// one full interactive working set (320 MiB) is 832 MiB before a second photograph
    /// is considered at all. The advertised budget was smaller than the residency of a
    /// single source — so no trim could reach it, and the two loops that were supposed
    /// to enforce it stopped at 1792 MiB instead.
    ///
    /// This number is larger than the one it replaces and that is the correction, not a
    /// regression: 768 was never held, and the memory it stood for was 1792. What
    /// changes on disk is the ceiling that is actually enforced, from 1792 MiB
    /// unreachable to `processBudgetBytes` reachable — `residualBytes` proves the trim
    /// gets under it from any starting state.
    public static var processBudgetBytes: Int {
        sourceCeilingBytes + interactiveWorkingSetBytes
    }

    /// THE INVARIANT THAT MAKES THE BUDGET A BOUND INSTEAD OF A WISH.
    ///
    /// The trim never touches the newest source, so a budget below what one source may
    /// hold is unenforceable by construction. False here means the app is advertising a
    /// ceiling it can only meet by evicting the decode of the photograph on screen —
    /// which is the 457 ms-per-frame defect the decode cache was written to prevent.
    public static func budgetCoversOneSource(_ budget: Int = processBudgetBytes) -> Bool {
        budget >= sourceCeilingBytes
    }

    // MARK: - The trim's policy

    /// One source's holdings, split into the two classes that can be released
    /// separately. Used to model the trim; the app measures the same quantities by
    /// what each release returns.
    public struct Holding: Equatable, Sendable {
        /// The interactive working set — bounded, and what a compare pane wants kept.
        public let interactive: Int
        /// The native inspection plane, if this source is holding one.
        public let inspection: Int

        public init(interactive: Int, inspection: Int) {
            self.interactive = interactive
            self.inspection = inspection
        }

        public var total: Int { interactive + inspection }

        /// A source holding as much as `AppleRawSource` will ever let it.
        public static var ceiling: Holding {
            Holding(interactive: Swift.max(interactiveWorkingSetBytes,
                                           DraftLadder.materializedDecodeByteCeiling),
                    inspection: DraftLadder.materializedDecodeByteCeiling)
        }
    }

    /// One release the trim may make, naming a source by its index in use order
    /// (0 coldest, `count - 1` newest).
    public enum Step: Equatable, Sendable {
        /// Drop this source's native inspection planes, keeping its working set.
        case inspection(Int)
        /// Drop everything this source holds.
        case everything(Int)

        public var index: Int {
            switch self {
            case .inspection(let i), .everything(let i): return i
            }
        }
    }

    /// EVERY RELEASE THE TRIM IS ALLOWED TO MAKE, cheapest-to-lose first.
    ///
    /// Three phases, coarsening as they go, because the classes are worth very
    /// different amounts:
    ///
    /// 1. The inspection planes of every source but the newest. A native plane belongs
    ///    to whichever photograph is being INSPECTED and only one can be; every other
    ///    source holding one is holding it against a zoom that already ended.
    /// 2. Everything held by the cold sources — the ones outside the live set that
    ///    alternates at full render cost.
    /// 3. Everything held by the live set too, coldest first, still excluding the
    ///    newest. THIS PHASE IS THE FIX. Without it the order simply stopped while over
    ///    budget, and the four spared working sets were the 960 MiB half of a 1792 MiB
    ///    floor that no amount of paging could persuade the trim to release. It is last
    ///    for the reason phase 2 exists at all — a compare pane really does want its
    ///    pane's decode between frames — and it is reached only when releasing every
    ///    colder thing has failed, at which point the choice is one re-demosaic on a
    ///    pane nobody is currently rendering against a machine that swaps.
    ///
    /// The newest source appears in no phase. It is the photograph a render just asked
    /// for, and taking its decode is taking the one that is about to be used; that is
    /// why `budgetCoversOneSource` has to hold rather than being a nicety.
    ///
    /// - Parameters:
    ///   - sourceCount: how many sources are held, in use order.
    ///   - liveSources: how many of the most recent alternate at full render cost.
    public static func releaseOrder(sourceCount: Int, liveSources: Int) -> [Step] {
        guard sourceCount > 1 else { return [] }
        let live = Swift.max(1, liveSources)
        let colder = 0..<(sourceCount - 1)
        // Below this index a source is not in the live set at all.
        let liveFrom = Swift.max(0, sourceCount - live)

        var steps: [Step] = colder.map { .inspection($0) }
        steps += colder.filter { $0 < liveFrom }.map { .everything($0) }
        steps += colder.filter { $0 >= liveFrom }.map { .everything($0) }
        return steps
    }

    /// What is still held once `releaseOrder` has been walked with the same early exit
    /// the app uses: stop the moment the total is under budget.
    ///
    /// The MODEL of `RenderCoordinator.trimDecodeResidency`, and the reason the bound
    /// is provable rather than argued. The app's loop differs in one respect only — it
    /// learns what a release freed from the release's own return value instead of from
    /// a `Holding` — which is why the order is the thing that lives here.
    public static func residualBytes(holdings: [Holding], budget: Int,
                                     liveSources: Int) -> Int {
        var remaining = holdings
        var total = remaining.reduce(0) { $0 + $1.total }
        guard total > budget else { return total }
        for step in releaseOrder(sourceCount: remaining.count,
                                 liveSources: liveSources) {
            guard total > budget else { return total }
            let held = remaining[step.index]
            switch step {
            case .inspection(let i):
                total -= held.inspection
                remaining[i] = Holding(interactive: held.interactive, inspection: 0)
            case .everything(let i):
                total -= held.total
                remaining[i] = Holding(interactive: 0, inspection: 0)
            }
        }
        return total
    }
}
