// PickArming.swift
// What an armed eyedropper was armed ON, so a click can tell when the thing it was for
// has gone.
//
// An armed pick outlived everything except Escape and its own button
// (docs/quality/lanes/WS-02/AUDIT.md §1.6, §5). The catcher re-mounts on the next photo,
// so a neutral armed on DSC_1 solved DSC_2's white balance, a "re-sample swatch 2" armed
// before a `−` re-sampled whichever swatch slid into slot 2, and a mask sample armed on a
// component that was then deleted landed in its neighbour. Each of those is an index or
// an identity that was true when the button was pressed and is no longer true when the
// click arrives.
//
// So the arming takes a snapshot — the photo, the target, and the counts and kinds the
// target's index means something against — and the click is checked against it, before
// the sample is taken and again after, before anything is written. A stale pick is
// REFUSED with a message rather than applied to whatever is there now; the photographer
// re-arms in one click, and a write into the wrong photograph cannot be undone by
// someone who did not see it happen.
//
// Also the home of what the picks SAY: the prompts (every one names Esc) and the
// message after a successful pick. They were in `AppState` and two of five targets said
// nothing at all on success, so the only feedback was the picture changing.

import Foundation

public struct PickArming: Equatable, Sendable {

    /// The LumenCore twin of the app's `PickTarget`: what the next click is for.
    public enum Target: Equatable, Sendable {
        case neutral
        case newPointColor
        case mixerBand
        case pointColor(index: Int)
        case maskSample(maskID: String, component: Int)
        case maskPointColor(maskID: String)

        /// What the status line says while the click is being waited for. Every one
        /// names Escape: the prompt sits in the status bar under the filmstrip, far from
        /// the image, and nothing else on screen says how to get out.
        public var prompt: String {
            switch self {
            case .neutral: return "Click something neutral grey in the picture — Esc to cancel."
            case .newPointColor, .pointColor: return "Click the colour to work on — Esc to cancel."
            case .mixerBand: return "Click a colour — its band selects itself. Esc to cancel."
            case .maskSample: return "Click the colour this mask should select — Esc to cancel."
            case .maskPointColor:
                return "Click the colour to work on inside this mask — Esc to cancel."
            }
        }
    }

    /// Why a click was refused.
    public enum Rejection: Equatable, Sendable, CaseIterable {
        case anotherPhoto
        case swatchesChanged
        case componentChanged
        case maskGone
        case swatchLimit
        case sampleLimit
        case maskSwatchLimit

        public var message: String {
            switch self {
            case .anotherPhoto:
                return "Pick cancelled — it was armed on another photo. Pick again here."
            case .swatchesChanged:
                return "Pick cancelled — the swatches changed since it was armed."
            case .componentChanged:
                return "Pick cancelled — that mask component was removed or changed."
            case .maskGone:
                return "Pick cancelled — that mask no longer exists."
            case .swatchLimit:
                return "\(PickArming.limit) swatches is the limit — remove one to add another."
            case .sampleLimit:
                return "\(PickArming.limit) samples is the limit — remove one to add another."
            case .maskSwatchLimit:
                return "\(PickArming.limit) mask swatches is the limit — remove one to add another."
            }
        }
    }

    public enum Verdict: Equatable, Sendable {
        case accept
        case reject(String)
    }

    /// The cap on swatches, mask samples and mask swatches — the panels' `maxSwatches`.
    public static let limit = 8

    /// The counts and kinds the target's indices are relative to, taken at arm time.
    public struct Snapshot: Equatable, Sendable {
        public var pointColorCount: Int
        /// Nil when the target names no mask, or the mask did not exist when armed.
        public var maskComponentCount: Int?
        public var componentKind: MaskKind?
        public var maskPointColorCount: Int?
    }

    public let photo: URL
    public let target: Target
    public let snapshot: Snapshot

    /// Arm `target` on `photo`, whose recipe is `recipe` at this moment.
    public init(photo: URL, target: Target, recipe: Recipe) {
        self.photo = photo
        self.target = target
        self.snapshot = Self.snapshot(of: target, in: recipe)
    }

    private static func snapshot(of target: Target, in recipe: Recipe) -> Snapshot {
        var shot = Snapshot(pointColorCount: recipe.develop.pointColors.count,
                            maskComponentCount: nil, componentKind: nil,
                            maskPointColorCount: nil)
        switch target {
        case .maskSample(let maskID, let component):
            if let mask = recipe.masks.first(where: { $0.id == maskID }) {
                shot.maskComponentCount = mask.components.count
                if mask.components.indices.contains(component) {
                    shot.componentKind = mask.components[component].kind
                }
            }
        case .maskPointColor(let maskID):
            if let mask = recipe.masks.first(where: { $0.id == maskID }) {
                shot.maskPointColorCount = mask.adjust.pointColors.count
            }
        case .neutral, .newPointColor, .mixerBand, .pointColor:
            break
        }
        return shot
    }

    /// Whether a click on `photo`, whose recipe is now `recipe`, may still do what this
    /// pick was armed to do.
    public func accepts(photo clicked: URL, recipe: Recipe) -> Verdict {
        guard clicked == photo else { return .reject(Rejection.anotherPhoto.message) }
        switch target {
        case .neutral, .mixerBand:
            return .accept
        case .newPointColor:
            return recipe.develop.pointColors.count >= Self.limit
                ? .reject(Rejection.swatchLimit.message) : .accept
        case .pointColor(let index):
            // The list it indexes has to be the list it was armed against: after a `−`
            // the same index names a different swatch, or none.
            let swatches = recipe.develop.pointColors
            guard swatches.count == snapshot.pointColorCount,
                  swatches.indices.contains(index)
            else { return .reject(Rejection.swatchesChanged.message) }
            return .accept
        case .maskSample(let maskID, let component):
            guard let mask = recipe.masks.first(where: { $0.id == maskID }),
                  snapshot.maskComponentCount != nil
            else { return .reject(Rejection.maskGone.message) }
            guard mask.components.count == snapshot.maskComponentCount,
                  mask.components.indices.contains(component),
                  mask.components[component].kind == snapshot.componentKind
            else { return .reject(Rejection.componentChanged.message) }
            // A component's single placeholder grey is replaced by the first pick, so it
            // never counts against the cap.
            let samples = mask.components[component].samples ?? []
            if samples.count >= Self.limit && samples != [Self.placeholderSample] {
                return .reject(Rejection.sampleLimit.message)
            }
            return .accept
        case .maskPointColor(let maskID):
            guard let mask = recipe.masks.first(where: { $0.id == maskID }),
                  snapshot.maskPointColorCount != nil
            else { return .reject(Rejection.maskGone.message) }
            return mask.adjust.pointColors.count >= Self.limit
                ? .reject(Rejection.maskSwatchLimit.message) : .accept
        }
    }

    /// The grey a colour-driven mask component is born with (`AppState.placeholderSample`
    /// restated, so the cap above can tell a placeholder from a choice).
    public static let placeholderSample: [Double] = [0.18, 0.18, 0.18]

    // MARK: - What a successful pick says

    /// The status line after a pick that wrote the recipe, read off the recipe AFTER the
    /// write so the number is the one the panel now shows. 1-based, as the panels count.
    /// Nil for the two targets whose message is not about the recipe (`neutralMessage`,
    /// `bandMessage`), or when the thing written is no longer there.
    public func successMessage(after recipe: Recipe) -> String? {
        switch target {
        case .neutral, .mixerBand:
            return nil
        case .newPointColor:
            let count = recipe.develop.pointColors.count
            return count > 0 ? "Swatch \(count) added." : nil
        case .pointColor(let index):
            return "Swatch \(index + 1) re-sampled."
        case .maskSample(let maskID, let component):
            guard let mask = recipe.masks.first(where: { $0.id == maskID }),
                  mask.components.indices.contains(component)
            else { return nil }
            let count = mask.components[component].samples?.count ?? 0
            return "Sample \(count) of \(Self.limit) added."
        case .maskPointColor(let maskID):
            guard let mask = recipe.masks.first(where: { $0.id == maskID }) else { return nil }
            return "Mask swatch \(mask.adjust.pointColors.count) added."
        }
    }

    /// The neutral pick's message.
    public static func neutralMessage(kelvin: Double, tint: Double) -> String {
        String(format: "Neutral picked — %.0f K, tint %.0f", kelvin, tint)
    }

    /// The mixer pick's message, for the band it selected.
    public static func bandMessage(bandName: String) -> String {
        "\(bandName) selected."
    }
}
