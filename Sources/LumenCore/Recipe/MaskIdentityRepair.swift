// MaskIdentityRepair.swift
// Two masks carrying one id (S-07), repaired on load where that changes no picture and
// reported where it would.
//
// Nothing this app writes produces a collision — `appendingMasks` re-issues colliding
// ids on paste — so a duplicate comes from a hand-edited sidecar or another writer. The
// renderers all agree on what one MEANS: a `maskRef` to the id resolves FIRST-WINS
// (`MaskRaster.referenced`, `MaskDependency`'s `byID`, `Recipe.renderIdentity`), and
// every row still renders. What they do not agree on is the rest: the GPU keys its
// mask alphas by id (`RenderGraph.maskImages[mask.id]`), so both rows were composited
// through whichever alpha was baked last, while the reference rasterizes each row on
// its own. And the panel selects, expands and deletes by id, so it cannot tell the two
// rows apart at all.
//
// THE REPAIR. Every row after the first carrying an id gets a fresh one, `<id>-2`,
// `<id>-3`, … skipping anything already taken — deterministic, so decoding the same
// sidecar twice gives the same ids. No reference is rewritten: every reference to the
// id already resolves to the FIRST row, which keeps it, so every reference keeps its
// meaning untouched.
//
// WHEN IT IS NOT SAFE, IT IS NOT DONE. The one thing a rename can change is the cycle
// guard. While a duplicate row is being rasterized its own id is in `resolving`, so a
// reference to that id reached from inside the row — directly, or through a chain of
// other masks — is refused as a cycle. Renamed, the same reference would resolve to the
// first row and select something. Such a row is left exactly as it was and reported in
// `unresolved`, for the panel to say so; guessing which mask the author meant is the
// "silently attach a different mask" the backlog forbids.
//
// A recipe with no duplicate id is returned untouched, so a well-formed recipe moves no
// pixel and keeps its bytes. `Recipe.renderIdentity` canonicalizes ids to stack
// positions and resolves references first-wins, so a repaired recipe also keeps its
// `recipe_fp`.

public enum MaskIdentityRepair {

    public struct Renamed: Equatable, Sendable {
        /// The row's position in the stack.
        public var row: Int
        public var from: String
        public var to: String
    }

    public struct Outcome: Equatable, Sendable {
        public var masks: [Mask]
        public var renamed: [Renamed]
        /// Ids still carried by more than one row after the repair, in stack order:
        /// the rows a rename would have changed the picture of.
        public var unresolved: [String]
    }

    public static func repair(_ masks: [Mask]) -> Outcome {
        var counts: [String: Int] = [:]
        for mask in masks { counts[mask.id, default: 0] += 1 }
        guard counts.values.contains(where: { $0 > 1 }) else {
            return Outcome(masks: masks, renamed: [], unresolved: [])
        }

        // First-wins targets, exactly as every resolver builds them — from the ORIGINAL
        // list, which the repair never changes for a first row.
        var byID: [String: Mask] = [:]
        for mask in masks where byID[mask.id] == nil { byID[mask.id] = mask }

        var taken = Set(masks.map(\.id))
        var seen: Set<String> = []
        var out = masks
        var renamed: [Renamed] = []
        var unresolved: [String] = []
        for (row, mask) in masks.enumerated() {
            // The first row carrying an id keeps it: it is what every reference means.
            if seen.insert(mask.id).inserted { continue }
            if reaches(mask.id, from: mask, byID: byID) {
                if !unresolved.contains(mask.id) { unresolved.append(mask.id) }
                continue
            }
            var n = 2
            while taken.contains("\(mask.id)-\(n)") { n += 1 }
            let fresh = "\(mask.id)-\(n)"
            taken.insert(fresh)
            out[row].id = fresh
            renamed.append(Renamed(row: row, from: mask.id, to: fresh))
        }
        return Outcome(masks: out, renamed: renamed, unresolved: unresolved)
    }

    /// Whether a reference to `id` can be reached from inside `root`, following
    /// references first-wins. Over-approximates the rasterizer (it ignores the depth
    /// limit and does not stop at an intermediate cycle), which errs toward leaving a
    /// row alone: a false "reaches" costs a notice, a false "does not" would cost a
    /// changed picture.
    static func reaches(_ id: String, from root: Mask, byID: [String: Mask]) -> Bool {
        var queue = refs(of: root)
        var visited: Set<String> = []
        while let ref = queue.popLast() {
            if ref == id { return true }
            guard visited.insert(ref).inserted, let target = byID[ref] else { continue }
            queue.append(contentsOf: refs(of: target))
        }
        return false
    }

    private static func refs(of mask: Mask) -> [String] {
        mask.components.compactMap { $0.kind == .maskRef ? $0.maskRef : nil }
    }
}

extension Recipe {
    /// Mask ids carried by more than one row — what is left after
    /// `MaskIdentityRepair` declined to rename a row because doing so would change what
    /// it selects. The panel says so rather than guessing.
    public var duplicateMaskIDs: [String] { MaskIdentityRepair.duplicateIDs(in: masks) }
}

extension MaskIdentityRepair {
    /// Ids carried by more than one row, in stack order of their second appearance.
    public static func duplicateIDs(in masks: [Mask]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for mask in masks where !seen.insert(mask.id).inserted && !out.contains(mask.id) {
            out.append(mask.id)
        }
        return out
    }
}
