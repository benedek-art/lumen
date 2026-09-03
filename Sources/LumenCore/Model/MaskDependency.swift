// MaskDependency.swift
// WHICH MASKS A RENDER HAS TO RASTERIZE, which is not the list of masks whose
// adjustments reach the picture — and every roster in the application that treated the
// two as one list has carried the same defect.
//
// `enabled` says whether a mask's ADJUSTMENTS reach the picture. It has never meant the
// mask stops SELECTING. `MaskRaster.referenced` lends a disabled mask's finished alpha
// to any `maskRef` pointing at it, deliberately and on the record — "turning off the Sky
// mask to look at something must not silently empty every mask built on it" — and
// `RenderPlan` carries `allMasks` beside `masks` so both renderers can honour that.
//
// A PROMISE ABOUT SELECTION IS ONLY AS GOOD AS THE INPUTS BEHIND IT. A mask does not
// rasterize out of thin air. A Vision kind needs its matte generated; a brush needs its
// stroke blob read off the disk. Both of those are decided by a SEPARATE walk of the
// recipe, and both walks said `for mask in recipe.masks where mask.enabled`:
//
//   · `VisionMattes.kinds(in:)` — the only source of "which mattes to generate", for the
//     background pass and for the export's synchronous one alike (audit F5-01).
//   · `BrushStrokes.references` / `.unresolvedReferences` — the only source of "which
//     blobs a delivery needs", and the only thing that warms the session cache the
//     export then reads.
//
// So the rasterizer kept its promise for the kinds that need no input — a radial, a
// polygon, a gradient — and broke it for exactly the two kinds that do. Mask A is a
// Subject mask, switched off to look past it; mask B is "Another Mask → A". A's matte is
// never generated, so A's only component is not evaluable, so A lends nothing, so B is
// empty — in the loupe, and in the delivered file, with no badge anywhere, because B's
// row is a reference row and never reaches the model note. Re-enabling A "fixes" it,
// which is the shape of bug nobody can reproduce twice.
//
// The answer is one walk, here, that both rosters ask: the masks whose adjustments reach
// the picture, PLUS everything reachable from them through `maskRef`. It lives in
// LumenCore rather than beside either caller because it is a rule about a recipe, and
// because this is the lane that can test it.

import Foundation

public enum MaskDependency {

    /// Every mask this recipe's render will ask the rasterizer for, in stack order.
    ///
    /// Two sources, unioned. The ROOTS are the masks whose adjustments reach the picture
    /// — `recipe.effective`, so a member of a switched-off folder is a root exactly when
    /// a switched-off mask is, which is to say not. The rest is REACHABILITY: whatever
    /// those roots point at through `maskRef`, transitively, whether or not the target
    /// is switched on, because that is precisely the case `MaskRaster.referenced`
    /// exists to serve.
    ///
    /// A reference to a mask that is not in the recipe is dropped rather than followed:
    /// a deleted mask has no inputs to fetch, and `MaskRaster` already treats a dangling
    /// reference as an absent component rather than an empty one.
    ///
    /// CYCLES TERMINATE by construction — an id enters the queue once. A → B → A costs
    /// two visits and asks for both masks' inputs, which is the honest answer: the
    /// rasterizer will decline to evaluate the loop, but nothing here can know at what
    /// depth it will decline, and fetching a matte that goes unused costs one pass while
    /// missing one costs a silently empty mask.
    ///
    /// Reachability is deliberately NOT bounded by `MaskRaster.referenceDepthLimit` for
    /// the same reason: the limit is a property of evaluation, and duplicating it here
    /// would be a second answer to keep in step with the first.
    public static func contributing(in recipe: Recipe) -> [Mask] {
        // First-wins on a duplicate id for the TARGET lookup, which is what every
        // `firstIndex(where:)` in the application resolves to — resolving a reference
        // here must not disagree with them.
        var byID: [String: Mask] = [:]
        for mask in recipe.masks where byID[mask.id] == nil { byID[mask.id] = mask }

        // The ROOTS are walked by ROW, not by id, and that distinction is a defect this
        // walk had. `RenderPlan.masks` is a `compactMap` over rows, so two masks sharing
        // one id both RENDER — while seeding the queue by id skipped the second one
        // entirely, and its `maskRef` targets were never fetched. The second row then
        // rendered empty, in the loupe and in the file, with no badge: exactly the bug
        // this file exists to close, reintroduced by the lookup rather than by the rule.
        //
        // Ids are not unique by construction — `Mask.init(from:)` invents one when the
        // key is absent, so a hand-edited sidecar or a catalog from another writer can
        // carry a collision, and `appendingMasks` re-issues ids without remapping.
        var wanted: Set<String> = []
        var queue: [String] = []
        for mask in recipe.masks where recipe.effective(mask).enabled {
            wanted.insert(mask.id)
            for component in mask.components where component.kind == .maskRef {
                guard let ref = component.maskRef, !ref.isEmpty, byID[ref] != nil,
                      wanted.insert(ref).inserted else { continue }
                queue.append(ref)
            }
        }

        var head = 0
        while head < queue.count {
            let id = queue[head]
            head += 1
            guard let mask = byID[id] else { continue }
            for component in mask.components where component.kind == .maskRef {
                guard let ref = component.maskRef, !ref.isEmpty, byID[ref] != nil,
                      wanted.insert(ref).inserted else { continue }
                queue.append(ref)
            }
        }

        // Stack order, not discovery order: `BrushStrokes.references` promises the order
        // the render will fetch in, and a folder of blobs read back to front is a
        // different sequence of disk reads for no reason.
        return recipe.masks.filter { wanted.contains($0.id) }
    }

    /// ONE mask and everything its raster depends on, in stack order: itself, plus every
    /// mask reachable from it through `maskRef`.
    ///
    /// This is the CACHE question rather than the fetch question, and it has the same
    /// shape for the same reason. A baked mask raster is keyed on the mask's own
    /// canonical form, which is complete for every kind but this one: a reference is a
    /// LIVE view of another mask, so softening the Sky mask's edge changes the raster of
    /// every mask built on Sky without changing one byte of their own definitions. A key
    /// that names only the one mask therefore serves a raster from before the edit —
    /// in the loupe and, since the delivery bakes through the same cache, in the file.
    ///
    /// `mask` leads whether or not it is in `masks`, so a mask being edited off the list
    /// still keys on itself. Cycles produce a finite walk, as everywhere else here.
    public static func closure(of mask: Mask, in masks: [Mask]) -> [Mask] {
        var byID: [String: Mask] = [:]
        for m in masks where byID[m.id] == nil { byID[m.id] = m }
        if byID[mask.id] == nil { byID[mask.id] = mask }

        var seen: Set<String> = [mask.id]
        var queue: [String] = [mask.id]
        var head = 0
        while head < queue.count {
            let id = queue[head]
            head += 1
            guard let m = byID[id] else { continue }
            for component in m.components where component.kind == .maskRef {
                guard let ref = component.maskRef, !ref.isEmpty, byID[ref] != nil,
                      seen.insert(ref).inserted else { continue }
                queue.append(ref)
            }
        }

        var out: [Mask] = []
        if !masks.contains(where: { $0.id == mask.id }) { out.append(mask) }
        out.append(contentsOf: masks.filter { seen.contains($0.id) })
        return out
    }

    /// The matte kinds a render of this recipe has to have in hand, optionally narrowed
    /// to one provider.
    ///
    /// `from: .vision` is the roster the on-device segmenter generates. Narrowing here
    /// rather than at the call site keeps the walk — the part that was wrong — in one
    /// place, and lets a lane with no Vision framework test it.
    public static func wantedMattes(in recipe: Recipe,
                                    from provider: MaskKind.MatteProvider? = nil)
        -> Set<MaskKind> {
        var wanted: Set<MaskKind> = []
        for mask in contributing(in: recipe) {
            for component in mask.components {
                let kind = component.kind
                guard kind.needsMatte else { continue }
                if let provider, kind.matteProvider != provider { continue }
                wanted.insert(kind)
            }
        }
        return wanted
    }
}
