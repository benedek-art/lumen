// CropPanel.swift
// The Crop workspace's column: the ratio menu and its padlock, the orientation swap, the
// angle, the ruler, and the guide overlay — plus the session state the on-image tool and
// the panel both read. The crop saves as you go (owner, pass 4): every drag writes the
// recipe per event, so there is no commit row — R or leaving the workspace puts the tool
// away, Escape reverts to the framing the session opened with, and Reset clears it.
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
    /// shipped twice and now has a test for. Escape is the ONE caller now: the crop
    /// saves as you go, so the Done/Revert row is gone (owner, pass 4) and this is the
    /// whole of the way back that is not Reset.
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
        // ONLY THE PHOTOGRAPH THE BASELINE BELONGS TO. `updateRecipe` writes every
        // `editTargets` entry, and the baseline is taken for the primary selection alone
        // — so with three frames selected, Escape stamped the primary's pre-crop framing
        // onto the other two and their own crops were gone. Recorded as one undo step, so
        // ⌘Z recovered it, but nothing on screen said three photographs had been rewritten
        // by a key that means "cancel". Framing is a per-photograph gesture: the rectangle
        // is on ONE picture and so is the revert.
        // `_, recipe` because naming `targets:` selects the photo-aware overload — the
        // one-argument form has no such parameter. The photograph is already `photo`.
        state.updateRecipe(coalescingKey: "geometry.revert",
                           targets: [photo]) { _, recipe in
            recipe.develop.geometry.crop = baseline.crop
            recipe.develop.geometry.angle = baseline.angle
            recipe.develop.geometry.flipH = baseline.flipH
        }
        setLock(nil, for: photo.id)
        endSession()
        forgetArming()
    }

    /// Throw the framing away: no crop, no angle, no flip.
    ///
    /// BESIDE `revert` RATHER THAN IN THE PANEL, and for the reason `revert` is here too:
    /// a key cannot reach a view. Reset is what a double press of R means (docs/09), R
    /// lands in `KeyDispatcher`, and this column is not mounted at all when the Crop
    /// section is folded or when the photographer is arriving from another workspace — so
    /// a reset that exists only as a closure inside `CropSection` is a reset only the
    /// section header's button can reach. Today that button is the one caller, through
    /// `CropSection.resetGeometry()`; the note on that view's `onChange` says what still
    /// has to happen for the key to be the second.
    ///
    /// THE SAME THREE FIELDS `revert` writes, for the same reason: Lens Corrections lives
    /// in this workspace too, and a reset that also un-ticked the built-in lens profile
    /// would undo something nobody did inside the crop tool.
    @MainActor
    func resetGeometry(in state: AppState) {
        // Outside the edit closure: that one mutates a recipe and may not run here, and
        // the lock is session state rather than recipe state.
        if let photo = state.primarySelection { setLock(nil, for: photo.id) }
        state.updateRecipe(coalescingKey: "geometry.reset") { recipe in
            recipe.develop.geometry.crop = Crop()
            recipe.develop.geometry.angle = 0
            recipe.develop.geometry.flipH = false
        }
    }

    // MARK: The double press

    /// How close together two presses of R have to be to mean "reset", in seconds.
    ///
    /// A shade longer than a double click, because R is a bare key on a full-size
    /// keyboard rather than two taps on one button, and the second press is a decision
    /// rather than a reflex.
    private static let doublePressWindow: TimeInterval = 0.45

    private var lastArmingChange: Date?

    /// Forget the last transition, so a press of R that follows some other way out of
    /// the tool — Escape, leaving the workspace, M — is a first press rather than the
    /// second half of something else started.
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
/// rectangle needs that frame's own size. `AppState.sourceFrameSize` supplies it from
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

    /// Nil when this panel supplies its own header, or the `WorkspaceSection` whose
    /// header the develop column has ALREADY drawn above it.
    ///
    /// ROWS, NOT A SECTION, when the column has drawn the heading — the same split
    /// `BasicPanel` and `LookPanel` both record as a defect they fixed, and the same one
    /// `EffectsPanel` already makes for Soft Proof. `WorkspaceSection.frame.title` is
    /// "Crop" and so is this section's, so the accordion printed CROP twice one row
    /// apart, each with its own chevron, its own modified dot and its own Reset — and
    /// the two Resets had different scope, the outer clearing the workspace section and
    /// the inner clearing crop, angle and flip together. Clicking the inner chevron
    /// collapsed a section inside the section that was already the section.
    var only: WorkspaceSection?

    var body: some View {
        withSession(sectionOrRows)
    }

    @ViewBuilder
    private var sectionOrRows: some View {
        if only == nil {
            DevelopSection("Crop", isModified: isGeometryModified,
                           onReset: { resetGeometry() },
                           resetHelp: "Clears the whole framing — crop, angle and flip. "
                               + "Original in the ratio menu brings just the frame back, "
                               + "keeping the angle.") {
                cropRows
            }
        } else {
            cropRows
        }
    }

    /// What the section holds, with no heading of its own — so the column's header can
    /// carry it, or this panel's own can.
    private var cropRows: some View {
        VStack(alignment: .leading, spacing: Lumen.rowGap) {
                aspectRow
                if showsCustomField { customRow }
                sizeRow
                // The help is where the hand is taught. docs/09 makes rotation a DRAG on
                // the photograph and this slider the same field said as a number, but
                // nothing on the picture said so — the angle readout only ghosts beside
                // the cursor once the drag is already under way, which teaches whoever
                // had already guessed. This row is where somebody looking for "how do I
                // straighten this" ends up, so it is where the gesture gets named.
                LumenSlider(title: "Angle",
                            value: angleBinding,
                            range: -45...45, hardRange: nil, defaultValue: 0,
                            step: 0.1, decimals: 1,
                            help: "How far the picture is turned under the frame — the "
                                + "rectangle keeps its size and its centre while the "
                                + "picture turns. Drag anywhere outside the rectangle "
                                + "on the photograph to set it by hand (⇧ turns "
                                + "finely), or use the ruler below to take it off a "
                                + "horizon.")
                rulerRow
                guidesRow
                // THE CROP MIRRORS WITH THE FRAME, and until now it did not.
                //
                // `geometryRects` applies the mirror FIRST and then measures the crop
                // rectangle from the left edge of the already-mirrored frame. So on a
                // crop of `x=0 w=0.5` — the left half — ticking this box delivered a
                // mirrored version of the RIGHT half: the subject you framed is simply
                // gone, and the masks do not move with it (they are stored in source
                // coordinates and applied before geometry), so they stay on a subject the
                // crop has left. The row's own help says "mirror the frame", which is
                // what a photographer expects and what this now does.
                //
                // One line, and it keeps every stored recipe's meaning stable: a centred
                // crop is its own mirror, so nothing that exists today moves.
                LumenToggleRow(title: "Flip horizontal",
                               isOn: Binding(
                                get: { recipe.develop.geometry.flipH },
                                set: { on in
                                    binder.edit("geometry.flipH") { r in
                                        r.develop.geometry.flipH = on
                                        let c = r.develop.geometry.crop
                                        r.develop.geometry.crop.x = 1 - c.x - c.w
                                    }
                                }),
                               help: "Mirror the frame. The crop mirrors with it, so the "
                                   + "framing stays on the same part of the picture. This "
                                   + "is a mirror, not a rotation — turning the crop "
                                   + "between portrait and landscape is the ⇅ button "
                                   + "beside the ratio.")
                // No Done/Revert row: the crop saves as you go (owner, pass 4). R — or
                // leaving the workspace — puts the tool away, Escape reverts to the
                // framing this session opened with, Reset clears everything. Return no
                // longer means anything here; the grammar change landed in `KeyGrammar`
                // and the help sheet with this.
                // No perspective rows: `Upright` is a wire format with no stage behind
                // it, and a control that reaches nothing is the defect this panel's
                // Lens section was cut down for.
        }
    }

    /// The framing session's lifecycle, on the BODY rather than on the rows: it has to
    /// run whichever of the two shapes above was drawn.
    @ViewBuilder
    private func withSession<V: View>(_ content: V) -> some View {
        content
        .onAppear {
            guard let photoID, viewport.showCrop else { return }
            tool.beginSession(photo: photoID, geometry: recipe.develop.geometry)
        }
        // ONE JOB HERE NOW: start a framing session when the tool arms.
        //
        // The double-press-R reset used to live on this modifier and it has moved to
        // `AppState.toggleCropTool`, where the key actually lands. A view's lifecycle
        // cannot observe a key: this only sees a transition that happens while the Crop
        // SECTION is mounted, and the section is unmounted both when the accordion is
        // folded (`WorkspaceSectionView` constructs no body for a closed section,
        // deliberately) and when the photographer is anywhere but the Crop workspace. So
        // the common route — `R` from Develop — armed the tool at mount time, landed as
        // `onAppear` plus one `onChange`, and the pair was never seen. The grammar worked
        // from inside the workspace with the section open, and nowhere else.
        //
        // It cannot be counted in BOTH places. `noteArming` consumes the timestamp it
        // reads, so a call from here would eat the transition the key's own call depends
        // on, and the reset would go back to being intermittent for a new reason.
        .onChange(of: viewport.showCrop) { _, armed in
            if armed, let photoID {
                tool.beginSession(photo: photoID, geometry: recipe.develop.geometry)
            }
        }
    }

    // MARK: Aspect

    private var aspectRow: some View {
        HStack(spacing: 6) {
            Text("Aspect")
                .font(.lumenBody)
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
                    .font(.lumenCaption)
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
                    if let ratio = aspect.ratio {
                        Button(aspect.name) { applyAspect(ratio) }
                    } else {
                        // "Original" is the way BACK, not another ratio — see
                        // `restoreOriginal()`.
                        Button(aspect.name) { restoreOriginal() }
                    }
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
                    .font(.lumenCaption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The second sentence is the whole hand, in the row a photographer opens
            // first. The rectangle on the picture now teaches itself — brackets you can
            // see, a cursor that changes, an arc out where the rotation lives — but a
            // tooltip costs nothing and this project deleted 59 prose rows on the
            // understanding that the sentences would move onto the controls rather than
            // disappear. Original's clause carries the Reset distinction too, because a
            // menu item cannot hold its own tooltip and this row is where the choice is
            // made.
            .help("Standard ratios, measured against this frame and fitted around the "
                  + "crop you already have. Original brings the whole frame back and "
                  + "releases the ratio lock, keeping the angle and flip — Reset on the "
                  + "section header clears those too. On the photograph: drag a corner "
                  + "or an edge to reframe, inside the rectangle to move it, and "
                  + "outside the frame to turn the picture.")

            // ⇅, not X. docs/09 binds portrait ↔ landscape to X, and X is the reject
            // flag everywhere in this app with no crop-mode branch anywhere in `Keymap`
            // — so a photographer following that binding inside the crop tool rejects
            // the photograph they are cropping.
            Button {
                swapOrientation()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.lumenCaption)
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
                .font(.lumenBody)
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
            TextField("16:9", text: $customRatio)
                .textFieldStyle(.roundedBorder)
                .font(.lumenNumeric)
                .controlSize(.small)
                .onSubmit { commitCustomRatio() }
            Button("Set") { commitCustomRatio() }
                .font(.lumenCaption)
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
        if let frame = state.sourceFrameSize, frame.width > 0, frame.height > 0 {
            let resolved = CropGeometry.resolve(sourceWidth: Double(frame.width),
                                                sourceHeight: Double(frame.height),
                                                geometry: recipe.develop.geometry)
            HStack(spacing: 6) {
                Text("Size")
                    .font(.lumenBody)
                    .foregroundStyle(Lumen.secondaryText)
                    .frame(width: Lumen.labelWidth, alignment: .leading)
                Text("\(resolved.outputWidth) × \(resolved.outputHeight) px")
                    .font(.lumenNumeric)
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
                .font(.lumenBody)
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
            Button(viewport.showStraighten ? "Drag a line…" : "Straighten by line") {
                state.showLoupe()
                viewport.showCrop = true
                viewport.showStraighten.toggle()
            }
            .font(.lumenCaption)
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
                .font(.lumenBody)
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: Lumen.labelWidth, alignment: .leading)
            Menu {
                ForEach(CropOverlayStyle.allCases) { style in
                    Button(style.title) { tool.overlay = style }
                }
            } label: {
                Text(tool.overlay.title)
                    .font(.lumenCaption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Drawn inside the rectangle while you frame. A guide is a way of "
                  + "looking, so it is remembered across photographs and is not part of "
                  + "the recipe.")
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
        if let size = state.sourceFrameSize, size.width > 0, size.height > 0 {
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

    /// "Original" restores the full frame: the crop cleared, the lock released, the
    /// angle and flip kept (owner, pass 4: "Original resets the crop").
    ///
    /// It used to REFIT the existing rectangle to the camera's ratio and arm the lock
    /// with it — which answered "hold this crop at the camera's shape" and left no
    /// control anywhere that answered "give me the whole picture back". The padlock
    /// owns the first job now, so this one is the way back. Angle and flip stay
    /// because straightening is not a crop; Reset on the section header is the one
    /// that clears everything, and both helps say so.
    private func restoreOriginal() {
        if let photoID { tool.setLock(nil, for: photoID) }
        binder.edit("geometry.crop.original") { recipe in
            recipe.develop.geometry.crop = Crop()
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

    /// One path for the section header's Reset, the double press of R, and anything else
    /// that has to put the framing back — see `CropTool.resetGeometry(in:)`.
    private func resetGeometry() {
        tool.resetGeometry(in: state)
    }

    /// The Angle slider writes BOTH fields: the angle, and the crop restated against
    /// the new usable frame (`CropGeometry.reangled`) in the same recipe write — so the
    /// rectangle keeps its pixel size and centre while the picture turns, and a locked
    /// ratio survives the angle (docs/31 #10). The on-image rotate drag and the ruler
    /// do the same through `LoupeView.applyRotation`; three hands, one mechanism.
    ///
    /// The frame size is captured OUTSIDE the escaping closure so the binding does not
    /// hold the view. Before the decode lands it is the assumed 3:2, which makes the
    /// carried rectangle assumption-shaped in the visible way the fallback's own note
    /// accepts — never NaN-shaped.
    private var angleBinding: Binding<Double> {
        let size = frameSizeForCrop
        return binder.custom("geometry.angle",
                             get: { $0.develop.geometry.angle },
                             set: { recipe, angle in
                                 if let size, size.width > 0, size.height > 0 {
                                     recipe.develop.geometry.crop = CropGeometry.reangled(
                                         recipe.develop.geometry.crop,
                                         sourceWidth: size.width,
                                         sourceHeight: size.height,
                                         from: recipe.develop.geometry.angle,
                                         to: angle)
                                 }
                                 recipe.develop.geometry.angle = angle
                             })
    }
}

#endif
