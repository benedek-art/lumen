// CropPanel.swift
// The Crop workspace's column: the ratio menu and its padlock, the orientation swap, the
// angle, the ruler, the guide overlay, and the commit grammar — plus the session state
// the on-image tool and the panel both read.
//
// It left `EffectsPanel` because the crop stopped being a row of settings. The rectangle
// is dragged, rotated and committed on the photograph; what is left in the column is the
// half of the tool that needs a name — a ratio you can say out loud, an angle you can
// type, a guide you can choose — and it needs to share four pieces of session state with
// the overlay that does the rest. Sharing those through `LoupeViewport`, which is what
// the aspect lock did, is what this file is a correction of.
//
// THE LOCK BELONGS TO THE PHOTOGRAPH. `LoupeViewport.cropAspectLock` was one `Double?`
// for the whole application, so choosing 16:9 on one frame quietly held every frame
// afterwards to 16:9 — including frames shot in portrait, where the first corner drag
// then fought the lock. Worse, the only control that could clear it was "Original",
// which also threw the rectangle away, so "keep this crop but stop holding the ratio"
// could not be said at all. Here the lock carries the photograph it was chosen for and
// answers `nil` for any other, and the padlock clears it without touching the rectangle.
//
// WHAT IS DELIBERATELY NOT STORED PER PHOTOGRAPH: the guide overlay. docs/09 files the
// shield opacity as "remembered globally, not per photo" and a guide is the same kind of
// thing — a way of looking, not a property of the picture. It is also why neither is in
// the recipe.

#if os(macOS)

import Foundation
import LumenCore
import SwiftUI

// MARK: - Guides

/// What the crop rectangle draws inside itself.
///
/// docs/09 lists six and binds them to O; four are here, and the two that are not —
/// Golden Spiral and Triangle — are the two that need an orientation cycle of their own
/// to be worth anything. A spiral you cannot turn is a decoration.
enum CropOverlayStyle: String, CaseIterable, Identifiable, Sendable {
    /// Spelled `off` rather than `none`, matching `BeforeAfterMode`: a case called
    /// `none` on a non-optional value reads as `Optional.none` to every human who
    /// glances at a comparison, and eventually to the compiler in some context where
    /// the value has become optional.
    case off
    case thirds
    case grid
    case golden
    case diagonals

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "None"
        case .thirds: return "Thirds"
        case .grid: return "Grid"
        case .golden: return "Golden Ratio"
        case .diagonals: return "Diagonals"
        }
    }

    /// The fractions of the rectangle's width and height the guides sit at, or nil for
    /// the styles that are not a set of straight divisions.
    ///
    /// One list drives both axes because every one of these divisions is scale-free —
    /// thirds are thirds of whatever edge they cut, and φ is φ. A style that needed
    /// different fractions per axis would be describing a shape rather than a division.
    var divisions: [Double]? {
        switch self {
        case .off, .diagonals: return nil
        case .thirds: return [1.0 / 3, 2.0 / 3]
        case .grid: return [0.25, 0.5, 0.75]
        // 1/φ and 1−1/φ. The same two numbers photographers know as 0.382 and 0.618.
        case .golden: return [1 - 1 / 1.618033988749895, 1 / 1.618033988749895]
        }
    }
}

// MARK: - The tool's session state

/// What the crop tool remembers that the recipe does not.
///
/// Four things, and each is here rather than in `Recipe` for the same reason: none of
/// them changes the picture. The lock governs the NEXT drag, the guide is a way of
/// looking, the baseline is what Escape would put back, and the arming timestamps are
/// how a double press of R is told from two single ones.
///
/// Not `@MainActor`-annotated, for the reason `LoupeViewport` gives above its own
/// `shared`: an isolated static cannot be referenced from a view's property initializer,
/// and every view that needs this holds it as an `@ObservedObject` declared inline.
final class CropTool: ObservableObject {

    static let shared = CropTool()

    private init() {}

    // MARK: The ratio lock

    /// A ratio the drags must hold, and the photograph it was chosen for.
    struct Lock: Equatable, Sendable {
        var photo: URL
        var aspect: Double
    }

    @Published private(set) var activeLock: Lock?

    /// Width ÷ height in pixels this photograph's drags must hold, or nil for a free
    /// crop. A lock chosen on another frame answers nil, which is the whole fix.
    func lockedAspect(for photo: URL) -> Double? {
        guard let activeLock, activeLock.photo == photo else { return nil }
        return activeLock.aspect
    }

    func setLock(_ aspect: Double?, for photo: URL) {
        guard let aspect, aspect.isFinite, aspect > 0 else {
            activeLock = nil
            return
        }
        activeLock = Lock(photo: photo, aspect: aspect)
    }

    /// The last three hand-typed ratios, newest first (docs/09: "Custom ratios
    /// remembered in a 3-slot recency list inside the menu").
    @Published private(set) var recentCustomAspects: [Double] = []

    func rememberCustom(_ aspect: Double) {
        guard aspect.isFinite, aspect > 0 else { return }
        var next = recentCustomAspects.filter { abs($0 - aspect) > 0.005 }
        next.insert(aspect, at: 0)
        recentCustomAspects = Array(next.prefix(3))
    }

    // MARK: Guides

    @Published var overlay: CropOverlayStyle = .thirds

    // MARK: Commit and revert

    private var baseline: (photo: URL, geometry: Geometry)?

    /// Remember what the frame looked like when the tool opened, so Revert has something
    /// to put back. Re-arming on the same photograph does not overwrite it: leaving the
    /// tool and coming back is still one framing session, and taking a new baseline there
    /// would make Revert put back the crop it was asked to undo.
    func beginSession(photo: URL, geometry: Geometry) {
        guard baseline?.photo != photo else { return }
        baseline = (photo, geometry)
    }

    func baselineGeometry(for photo: URL) -> Geometry? {
        guard let baseline, baseline.photo == photo else { return nil }
        return baseline.geometry
    }

    func endSession() { baseline = nil }

    /// Put the frame back the way it was when the tool opened, and close it.
    ///
    /// ON THE TOOL RATHER THAN IN THE PANEL because Escape cannot reach the panel.
    /// `KeyDispatcher` installs an `NSEvent` monitor in FRONT of the responder chain and
    /// spends `0x1B` before any view sees it, so a `.keyboardShortcut(.escape)` on the
    /// crop column would be dead code wearing a shortcut — the defect this project has
    /// shipped twice and now has a test for. The panel's Revert button calls the same
    /// path, so the key and the button cannot drift.
    ///
    /// THREE FIELDS, not the whole `Geometry`: Lens Corrections lives in this same
    /// workspace, and a revert that also un-ticked the built-in lens profile would undo
    /// something the photographer did not do inside the crop tool.
    @MainActor
    func revert(in state: AppState) {
        guard let photo = state.primarySelection,
              let baseline = baselineGeometry(for: photo.id) else {
            endSession()
            forgetArming()
            return
        }
        state.updateRecipe(coalescingKey: "geometry.revert") { recipe in
            recipe.develop.geometry.crop = baseline.crop
            recipe.develop.geometry.angle = baseline.angle
            recipe.develop.geometry.flipH = baseline.flipH
        }
        setLock(nil, for: photo.id)
        endSession()
        forgetArming()
    }

    // MARK: The double press

    /// How close together two presses of R have to be to mean "reset", in seconds.
    ///
    /// A shade longer than a double click, because R is a bare key on a full-size
    /// keyboard rather than two taps on one button, and the second press is a decision
    /// rather than a reflex.
    private static let doublePressWindow: TimeInterval = 0.45

    private var lastArmingChange: Date?

    /// Forget the last transition, so a press of R that follows a click on Done is a
    /// first press rather than the second half of something the mouse started.
    func forgetArming() { lastArmingChange = nil }

    /// Report that the tool was armed or disarmed, and answer whether that was the second
    /// half of a double press.
    ///
    /// R TOGGLES, so a double press is two toggles and not two arms — pressed from
    /// outside the tool it reads open-then-closed, and from inside it reads
    /// closed-then-open. Counting transitions rather than states is what makes one rule
    /// cover both, and the caller finishes the job by leaving the tool open either way.
    func noteArming(at now: Date = Date()) -> Bool {
        defer { lastArmingChange = now }
        guard let last = lastArmingChange else { return false }
        guard now.timeIntervalSince(last) <= CropTool.doublePressWindow else { return false }
        // Cleared, so a third press starts a new pair rather than resetting again.
        lastArmingChange = nil
        return true
    }
}

// MARK: - Aspect ratios

/// The standard ratio list (docs/09 §13.1), in Lightroom's order. `ratio` is
/// width ÷ height in *image* pixels; nil is Original, which means the camera's own.
private struct CropAspect: Identifiable {
    let name: String
    let ratio: Double?

    var id: String { name }
}

private let cropAspects: [CropAspect] = [
    CropAspect(name: "Original", ratio: nil),
    CropAspect(name: "1:1", ratio: 1.0),
    CropAspect(name: "5:4", ratio: 5.0 / 4.0),
    CropAspect(name: "4:3", ratio: 4.0 / 3.0),
    CropAspect(name: "3:2", ratio: 3.0 / 2.0),
    CropAspect(name: "7:5", ratio: 7.0 / 5.0),
    CropAspect(name: "16:9", ratio: 16.0 / 9.0),
    CropAspect(name: "16:10", ratio: 16.0 / 10.0),
]

/// The frame aspect the ratio menu falls back to before the real one is known.
///
/// The crop is stored as a fraction of the usable frame, so turning "3:2" into a
/// rectangle needs that frame's own size. `AppState.primaryFrameSize` supplies it from
/// the decoded dimensions; this covers the moment before that lands, and the case where
/// there is no selection at all. It is right for most of the corpus and wrong in a
/// visible way — not the silent way it was wrong when it was the ONLY path.
private let assumedFrameAspect: Double = 3.0 / 2.0

// MARK: - The panel

struct CropSection: View {

    @EnvironmentObject var state: AppState
    /// This surface shows the edit, so it observes the edit signal —
    /// `AppState.recipes` is deliberately not published (see `EditRevision`).
    @EnvironmentObject var edits: EditRevision

    /// The rectangle, the ruler and the guides all live in the viewer, so the panel
    /// needs handles on the same two objects the overlay reads.
    @ObservedObject private var viewport: LoupeViewport = LoupeViewport.shared
    @ObservedObject private var tool: CropTool = CropTool.shared

    @State private var customRatio: String = ""
    @State private var showsCustomField: Bool = false

    private var binder: RecipeBinder { RecipeBinder(state: state) }
    private var recipe: Recipe { state.currentRecipe }
    private var photoID: URL? { state.primarySelection?.id }

    var body: some View {
        DevelopSection("Crop", isModified: isGeometryModified,
                       onReset: { resetGeometry() }) {
            VStack(alignment: .leading, spacing: 2) {
                aspectRow
                if showsCustomField { customRow }
                sizeRow
                LumenSlider(title: "Angle",
                            value: binder.value(\.develop.geometry.angle, "geometry.angle"),
                            range: -45...45, hardRange: nil, defaultValue: 0,
                            step: 0.1, decimals: 1)
                rulerRow
                guidesRow
                LumenToggleRow(title: "Flip horizontal",
                               isOn: binder.flag(\.develop.geometry.flipH, "geometry.flipH"),
                               help: "Mirror the frame. This is a mirror, not a rotation "
                                   + "— turning the crop between portrait and landscape "
                                   + "is the ⇅ button beside the ratio.")
                if viewport.showCrop { commitRow }
                // No perspective rows: `Upright` is a wire format with no stage behind
                // it, and a control that reaches nothing is the defect this panel's
                // Lens section was cut down for.
            }
        }
        .onAppear {
            guard let photoID, viewport.showCrop else { return }
            tool.beginSession(photo: photoID, geometry: recipe.develop.geometry)
        }
        // DOUBLE-R RESETS THE CROP (docs/09: "Return commits, Esc reverts, double-press R
        // resets the crop entirely"). R itself is the dispatcher's, and it toggles, so
        // what arrives here is a pair of transitions rather than a pair of presses — see
        // `CropTool.noteArming`. Forcing the tool open afterwards is what makes the two
        // orders mean the same thing: you reset the crop and you are still cropping.
        .onChange(of: viewport.showCrop) { _, armed in
            if tool.noteArming() {
                resetGeometry()
                viewport.showCrop = true
            } else if armed, let photoID {
                tool.beginSession(photo: photoID, geometry: recipe.develop.geometry)
            }
        }
    }

    // MARK: Aspect

    private var aspectRow: some View {
        HStack(spacing: 6) {
            Text("Aspect")
                .font(.system(size: 11))
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)

            // THE PADLOCK, which is the control that was missing rather than a decoration
            // on the one that was here. Locking reads the rectangle rather than asking
            // for a ratio, so "hold what I have got" is one click; unlocking leaves the
            // rectangle exactly where it is, which is what "Original" could not do.
            Button {
                guard let photoID else { return }
                if isLocked {
                    tool.setLock(nil, for: photoID)
                } else {
                    tool.setLock(currentRatio, for: photoID)
                }
            } label: {
                Image(systemName: isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 10))
                    .foregroundStyle(isLocked ? Lumen.accent : Lumen.secondaryText)
                    .frame(width: 16, height: Lumen.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isLocked
                  ? "Holding this ratio while you drag. Click to crop freely."
                  : "Crop freely. Click to hold the ratio the rectangle has now.")

            Menu {
                ForEach(cropAspects) { aspect in
                    Button(aspect.name) { applyAspect(aspect.ratio ?? originalRatio) }
                }
                if !tool.recentCustomAspects.isEmpty {
                    Divider()
                    ForEach(tool.recentCustomAspects, id: \.self) { ratio in
                        Button(Self.name(forRatio: ratio)) { applyAspect(ratio) }
                    }
                }
                Divider()
                Button("Custom…") {
                    customRatio = Self.name(forRatio: currentRatio ?? originalRatio)
                    showsCustomField = true
                }
            } label: {
                Text(currentAspectName)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Standard ratios, measured against this frame and fitted around the "
                  + "crop you already have. Press R to crop on the image.")

            // ⇅, not X. docs/09 binds portrait ↔ landscape to X, and X is the reject
            // flag everywhere in this app with no crop-mode branch anywhere in `Keymap`
            // — so a photographer following that binding inside the crop tool rejects
            // the photograph they are cropping.
            Button {
                swapOrientation()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.secondaryText)
                    .frame(width: 16, height: Lumen.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Turn the crop between portrait and landscape, keeping its size and "
                  + "its centre.")
        }
        .frame(height: Lumen.rowHeight)
    }

    /// A ratio typed rather than picked. The parsing is `CropGeometry.aspect(fromText:)`
    /// in LumenCore, so `16:9`, `16/9`, `3 x 2` and `1.85` are one rule with a test on it
    /// rather than four branches in a view.
    private var customRow: some View {
        HStack(spacing: 6) {
            Text("Custom")
                .font(.system(size: 11))
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
            TextField("16:9", text: $customRatio)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .controlSize(.small)
                .onSubmit { commitCustomRatio() }
            Button("Set") { commitCustomRatio() }
                .font(.system(size: 10))
                .disabled(CropGeometry.aspect(fromText: customRatio) == nil)
        }
        .frame(height: Lumen.rowHeight)
    }

    /// What the crop is worth in pixels.
    ///
    /// The one number a ratio cannot tell you, and the one a photographer cropping for a
    /// delivery actually needs — it is also the honest answer to "how much am I throwing
    /// away", which the rectangle on the picture only says as an area.
    @ViewBuilder
    private var sizeRow: some View {
        // The DECODED size only. `frameSizeForCrop` falls back to a bare 3:2 so the
        // ratio arithmetic has something to measure against before the decode lands, and
        // a pixel count derived from that would read "2 × 1 px" — a number that is not
        // an assumption but a lie.
        if let frame = state.primaryFrameSize, frame.width > 0, frame.height > 0 {
            let resolved = CropGeometry.resolve(sourceWidth: Double(frame.width),
                                                sourceHeight: Double(frame.height),
                                                geometry: recipe.develop.geometry)
            HStack(spacing: 6) {
                Text("Size")
                    .font(.system(size: 11))
                    .foregroundStyle(Lumen.secondaryText)
                    .frame(width: Lumen.labelWidth, alignment: .leading)
                Text("\(resolved.outputWidth) × \(resolved.outputHeight) px")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Lumen.primaryText)
                Spacer()
            }
            .frame(height: Lumen.rowHeight)
        }
    }

    /// Arms the ruler and opens the crop tool, which is where it lives — the loupe shows
    /// the whole straightened frame while the tool is open, and that is the frame the
    /// angle is expressed in.
    private var rulerRow: some View {
        HStack(spacing: 6) {
            Text("Ruler")
                .font(.system(size: 11))
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
            Button(viewport.showStraighten ? "Drag a line…" : "Straighten by line") {
                state.showLoupe()
                viewport.showCrop = true
                viewport.showStraighten.toggle()
            }
            .font(.system(size: 10))
            .help("Drag along a horizon or a doorframe and the frame levels to whichever "
                  + "axis that line is nearer. To turn the picture by hand instead, drag "
                  + "outside the rectangle.")
            Spacer()
        }
        .frame(height: Lumen.rowHeight)
    }

    private var guidesRow: some View {
        HStack(spacing: 6) {
            Text("Guides")
                .font(.system(size: 11))
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
            Menu {
                ForEach(CropOverlayStyle.allCases) { style in
                    Button(style.title) { tool.overlay = style }
                }
            } label: {
                Text(tool.overlay.title)
                    .font(.system(size: 10))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Drawn inside the rectangle while you frame. A guide is a way of "
                  + "looking, so it is remembered across photographs and is not part of "
                  + "the recipe.")
        }
        .frame(height: Lumen.rowHeight)
    }

    /// docs/09's commit grammar, as two buttons rather than as two keys.
    ///
    /// Return is here. ESCAPE IS NOT, and it is the one binding in that sentence this
    /// panel cannot have: `KeyDispatcher` claims Escape in front of the responder chain
    /// and spends it on "back to the grid", so a `.cancelAction` attached here would be
    /// unreachable code wearing a shortcut. The button works; the key needs the
    /// dispatcher to yield the way it already yields to a focused slider.
    private var commitRow: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: Lumen.labelWidth)
            Button("Done") { commitCrop() }
                .font(.system(size: 10))
                // Withdrawn while the custom-ratio field is up. A window-wide Return
                // takes the key out from under a field editor, so the ratio you had just
                // typed would put the tool away instead of being applied — and the help
                // stops promising the key in the same breath.
                .keyboardShortcut(showsCustomField
                                  ? nil : KeyboardShortcut(.return, modifiers: []))
                .help(showsCustomField
                      ? "Keep this crop and put the tool away."
                      : "⏎. Keep this crop and put the tool away.")
            Button("Revert") { revertCrop() }
                .font(.system(size: 10))
                .disabled(revertTarget == nil)
                .help("Put the frame back the way it was when you opened the tool.")
            Spacer()
        }
        .frame(height: Lumen.rowHeight)
    }

    // MARK: Reading the rectangle back

    private var isLocked: Bool {
        guard let photoID else { return false }
        return tool.lockedAspect(for: photoID) != nil
    }

    /// The rectangle's own width ÷ height in pixels, against the USABLE frame at the
    /// current angle — which is what the crop is a fraction of. Reading it back against
    /// the source's own aspect makes the menu disagree with the rectangle it just wrote
    /// as soon as the photograph is straightened.
    private var currentRatio: Double? {
        guard let size = frameSizeForCrop else { return nil }
        return CropGeometry.displayedAspect(recipe.develop.geometry.crop,
                                            sourceWidth: size.width,
                                            sourceHeight: size.height,
                                            degrees: recipe.develop.geometry.angle)
    }

    /// The camera's own ratio, which is what "Original" means. Off the SOURCE frame and
    /// not the usable one: straightening does not change what the camera shot.
    private var originalRatio: Double {
        guard let size = frameSizeForCrop, size.height > 0 else { return assumedFrameAspect }
        return size.width / size.height
    }

    /// Reports what the stored rectangle *is*, not what was last clicked — the same
    /// grammar the white-balance preset row uses.
    private var currentAspectName: String {
        guard let ratio = currentRatio else { return "Custom" }
        if abs(ratio - originalRatio) < 0.005 { return "Original" }
        for aspect in cropAspects {
            if let target = aspect.ratio, abs(target - ratio) < 0.005 { return aspect.name }
        }
        return Self.name(forRatio: ratio)
    }

    /// A ratio as the menu prints it: the two whole numbers when there are small ones,
    /// and a decimal otherwise. `1.7778` is a true statement nobody recognises as 16:9.
    private static func name(forRatio ratio: Double) -> String {
        guard ratio.isFinite, ratio > 0 else { return "Custom" }
        for denominator in 1...16 {
            let numerator = ratio * Double(denominator)
            if abs(numerator - numerator.rounded()) < 0.004 {
                return "\(Int(numerator.rounded())):\(denominator)"
            }
        }
        return String(format: "%.3f", ratio)
    }

    /// The source frame in pixels, which the crop arithmetic needs — an aspect alone is
    /// not enough once a straighten angle is involved, because the inscribed rectangle
    /// depends on both edges.
    private var frameSizeForCrop: (width: Double, height: Double)? {
        if let size = state.primaryFrameSize, size.width > 0, size.height > 0 {
            return (Double(size.width), Double(size.height))
        }
        return (assumedFrameAspect, 1)
    }

    // MARK: Writing it

    /// Picking a ratio arms the lock and REFITS the rectangle rather than replacing it.
    ///
    /// Both halves are corrections. Without the lock the menu wrote a 3:2 rectangle and
    /// the very next corner drag made it free-form again, after which the menu read it
    /// back as "Custom". And `centred` threw the framing away on every pick, so changing
    /// your mind about the ratio cost you the composition — `CropGeometry.refit` keeps
    /// the centre and the scale, and is the same call for all nine entries.
    private func applyAspect(_ ratio: Double) {
        guard let size = frameSizeForCrop, let photoID, ratio > 0 else { return }
        tool.setLock(ratio, for: photoID)
        binder.edit("geometry.crop.aspect") { recipe in
            recipe.develop.geometry.crop = CropGeometry.refit(
                recipe.develop.geometry.crop, aspect: ratio,
                sourceWidth: size.width, sourceHeight: size.height,
                degrees: recipe.develop.geometry.angle)
        }
    }

    private func commitCustomRatio() {
        guard let ratio = CropGeometry.aspect(fromText: customRatio) else { return }
        tool.rememberCustom(ratio)
        applyAspect(ratio)
        showsCustomField = false
    }

    private func swapOrientation() {
        guard let size = frameSizeForCrop, let photoID else { return }
        binder.edit("geometry.crop.orientation") { recipe in
            recipe.develop.geometry.crop = CropGeometry.swappingOrientation(
                recipe.develop.geometry.crop,
                sourceWidth: size.width, sourceHeight: size.height,
                degrees: recipe.develop.geometry.angle)
        }
        // The lock turns with the rectangle, or the next drag would fight the swap.
        if let locked = tool.lockedAspect(for: photoID), locked > 0 {
            tool.setLock(1 / locked, for: photoID)
        }
    }

    private var isGeometryModified: Bool {
        let geometry = recipe.develop.geometry
        return geometry.crop != Crop() || geometry.angle != 0 || geometry.flipH
    }

    private func resetGeometry() {
        // Outside the edit closure: that one mutates a recipe and may not run here, and
        // the lock is session state rather than recipe state.
        if let photoID { tool.setLock(nil, for: photoID) }
        binder.edit("geometry.reset") { recipe in
            recipe.develop.geometry.crop = Crop()
            recipe.develop.geometry.angle = 0
            recipe.develop.geometry.flipH = false
        }
    }

    /// What Revert would put back, or nil when there is nothing to put back.
    ///
    /// THREE FIELDS, not the whole `Geometry`. Lens Corrections sits in this same
    /// workspace, and a revert that also un-ticked the built-in profile would be undoing
    /// something the photographer did not do inside the crop tool.
    private var revertTarget: Geometry? {
        guard let photoID,
              let baseline = tool.baselineGeometry(for: photoID) else { return nil }
        let now = recipe.develop.geometry
        let unchanged = baseline.crop == now.crop
            && baseline.angle == now.angle
            && baseline.flipH == now.flipH
        return unchanged ? nil : baseline
    }

    private func commitCrop() {
        tool.endSession()
        tool.forgetArming()
        viewport.showCrop = false
        viewport.showStraighten = false
    }

    private func revertCrop() {
        // One path for the button and the key — see `CropTool.revert(in:)`.
        tool.revert(in: state)
        viewport.showCrop = false
        viewport.showStraighten = false
    }
}

#endif
