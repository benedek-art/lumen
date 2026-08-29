// DevelopColumn.swift
// The develop column's arrangement: five workspaces where eight icon tabs used to be,
// and an accordion of sections inside each one.
//
// docs/28 Phase 4 items 13 and 15, and the owner's own words are the specification:
// "the tabs and menus can be a bit better and maybe be put into less ... maybe make it
// into collapsible tabs like lightroom has it because I think the tabs is great but I
// think we can make it into maybe 3-4 tabs not the 6ish we have now."
//
// WHY WORKSPACES ARE WORDS AND TABS WERE ICONS. Eight `Image(systemName:)`s with the
// title hidden in a tooltip is a row a photographer has to learn by position, and the
// owner said he did not: "I genuinely don't get some of it." Four fit in 320 points as
// text with room to spare, and a name that is legible without hovering is the whole
// reason four is better than eight.
//
// The arrangement itself is `WorkspaceLayout` in LumenCore — which workspace, which
// sections are open, which register — and the rules that move it (`SectionExpansion`,
// the register's visibility) are there too, with tests. `PanelLayout` is the observable
// that holds it. Nothing in this file decides what a click MEANS; it decides what a
// click looks like.

#if os(macOS)
import LumenCore
import SwiftUI

// MARK: - The workspace switcher

struct WorkspaceSwitcher: View {
    @ObservedObject var panel: PanelLayout
    /// A tab is a DESTINATION, not an arrangement — see `AppState.enter`. The strip used
    /// to call `panel.select` directly, which moved the column and nothing else, so
    /// clicking Cull left you in the loupe and clicking Crop left the crop tool off. The
    /// menu items had both fixes written into them individually; the tabs, which are what
    /// a photographer actually clicks, had neither.
    @EnvironmentObject private var state: AppState

    /// Which tab the pointer is over, and whether it is on the mask door. Row-local, so
    /// crossing the strip invalidates the strip and nothing else — hover state never
    /// reaches an `ObservableObject` (`LumenHoverModifier`, and what `CommandState`
    /// cost before it).
    @State private var hovered: Workspace?
    @State private var maskHovered = false
    @State private var backHovered = false

    /// THE SWITCHER IS ALSO THE WAY OUT OF MASKING, because masking is on this axis.
    ///
    /// While the mask editor has the column there is nothing here to switch between —
    /// every workspace's sections are off screen — so the strip becomes the one control
    /// that matters, which is the door back. Drawing the five tabs anyway would say the
    /// column is showing a workspace when it is not, and would leave the way out to be
    /// found by pressing the same icon twice.
    var body: some View {
        if panel.layout.isMasking {
            maskingBar
        } else {
            workspaceStrip
        }
    }

    /// "‹ Develop", naming the workspace underneath rather than saying "Back": the label
    /// is the destination, so the photographer knows what they are returning to before
    /// they commit to going. `layout.workspace` still holds it — masking never wrote it.
    private var maskingBar: some View {
        HStack(spacing: 6) {
            Button {
                panel.setMasking(false)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    // THE ONE PLACE A WORKSPACE WEARS ITS GLYPH, because the strip
                    // above deliberately does not (see `workspaceStrip`).
                    //
                    // This button's whole job is to name a destination, and it has the
                    // column's full width to name it in — nothing else is in the bar but
                    // a spacer and the word "Masks". So it is the one spot where a
                    // symbol takes no room away from a word, and it lets the way out be
                    // drawn from the same table the View menu will want when it comes to
                    // list these five (`Workspace.symbolName`) rather than from a glyph
                    // chosen here and nowhere else.
                    Image(systemName: panel.layout.workspace.symbolName)
                        .font(.system(size: 11))
                    Text(panel.layout.workspace.title)
                        .font(.lumenBody)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(tabFill(selected: false, hovered: backHovered))
                .foregroundStyle(backHovered ? Lumen.primaryText : Lumen.secondaryText)
                .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusTab,
                                            style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { backHovered = $0 }
            .lumenClickCursor()
            .help("Leave masking and go back to \(panel.layout.workspace.title) "
                  + "(Escape, or M)")
            Spacer(minLength: 0)
            // The column has to say where it is. The five tabs did that by highlighting
            // one of themselves; with them gone, this word is the only thing left that
            // does.
            LumenCapsLabel(text: "Masks", size: 11, color: Lumen.primaryText)
                .padding(.trailing, 8)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.12), value: backHovered)
    }

    /// FIVE WORDS AND NO GLYPHS, and the tape measure is the argument rather than
    /// taste.
    ///
    /// The owner asked for "a little bit more visual stuff" and the section headers
    /// below now carry a symbol each, so this strip was the obvious next place. It is
    /// the wrong one, and the column's own arithmetic says so. It opens at
    /// `Lumen.defaultPanelWidth` — 380 points — of which 8 go to this row's padding,
    /// about 30 to the mask door, 9 to the divider and its margins, and 12 to the six
    /// gaps, leaving roughly 321 for five equal tabs: **64 points each**. "Develop" is
    /// about 52 of those at 12pt medium, so an 11-point glyph and its gap do not fit in
    /// the dozen that are left, and the first tab to truncate would be the selected one
    /// — which is the bold one, which is the one the photographer is looking at. The
    /// column is draggable NARROWER than 380 as well (`ContentView.columnResizer`), so
    /// the margin only ever gets worse.
    ///
    /// And there is a reason older than the measurement, in this file's opening
    /// paragraph: the strip this replaced was eight `Image(systemName:)`s with the
    /// words hidden in tooltips, and the owner's verdict on it was "I genuinely don't
    /// get some of it". Words won that argument. Putting the icons back beside them
    /// would spend the win on decoration and buy nothing a reader of the word does not
    /// already have.
    ///
    /// The mask door keeps its glyph and is not the counter-example it looks like — it
    /// is deliberately NOT a workspace, and being the single icon in a row of words is
    /// how a photographer can see that without being told.
    private var workspaceStrip: some View {
        HStack(spacing: 2) {
            ForEach(Workspace.allCases, id: \.self) { workspace in
                let isCurrent = panel.layout.workspace == workspace
                Button {
                    state.enter(workspace)
                } label: {
                    Text(workspace.title)
                        .font(isCurrent ? .lumenBodyStrong : .lumenBody)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(tabFill(selected: isCurrent,
                                            hovered: hovered == workspace))
                        .foregroundStyle(isCurrent ? Lumen.primaryText : Lumen.secondaryText)
                        // The selected fill was an unclipped square corner in a panel
                        // whose every other surface is rounded — the one place the strip
                        // looked drawn rather than built.
                        //
                        // `radiusTab`, which is the strip's own and nearly a capsule: the
                        // owner named these five by name as the place he most wanted the
                        // corner opened up. See `Lumen.radiusTab` for why it is a
                        // separate number from the chip radius rather than the same one.
                        .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusTab,
                                                    style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        hovered = workspace
                    } else if hovered == workspace {
                        hovered = nil
                    }
                }
                .lumenClickCursor()
                // The chord, in the tooltip, because a switcher that teaches its own
                // shortcut is how a photographer stops using the switcher.
                .help("\(workspace.title) (⌘\(workspace.shortcutDigit))")
            }
            // MASKING NEEDS A DOOR THAT IS NOT A KEY.
            //
            // `M` opens it, but a surface whose only way in is a keystroke is half-built
            // — it is exactly the "I genuinely don't get some of it" the tab strip
            // earned. Set apart by a divider and drawn as an icon rather than a word, so
            // five words plus one glyph cannot be misread as six workspaces. It never
            // shows a selected state, because the strip it sits in is not on screen once
            // masking has the column.
            Divider()
                .frame(height: 14)
                .overlay(Lumen.separator)
                .padding(.horizontal, 4)
            Button {
                panel.setMasking(true)
            } label: {
                Image(systemName: "theatermasks")
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(tabFill(selected: false, hovered: maskHovered))
                    .foregroundStyle(maskHovered ? Lumen.primaryText : Lumen.secondaryText)
                    .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusTab,
                                                style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { maskHovered = $0 }
            .lumenClickCursor()
            .help("Masks (M) — the column becomes the mask editor")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.12), value: maskHovered)
    }

    /// ONE BACKGROUND, THREE STATES — rest, hover, selected.
    ///
    /// `lumenHoverable()` cannot serve this strip and it is worth saying why, because
    /// the mistake is invisible until you try it: the modifier paints its fill as a
    /// `.background`, BEHIND the content, and a selected tab already paints an opaque
    /// one. Stacking the two would have given every tab a hover except the one under
    /// the pointer's most likely destination. A colour computed from both states cannot
    /// be occluded by either.
    ///
    /// `controlActive` rather than the `fillColor.opacity(0.30)` this used to composite:
    /// against `windowBase` those land within a thousandth of each other, so nothing
    /// visible changed — but the tab now names the same rung of the ladder as every
    /// other selected control in the app instead of arriving at it by arithmetic.
    private func tabFill(selected: Bool, hovered: Bool) -> Color {
        if selected { return Lumen.controlActive }
        if hovered { return Lumen.controlHover }
        return .clear
    }
}

extension Workspace {

    /// The switcher's label. Deliberately not `rawValue`: the raw value is a
    /// persistence key (`PanelLayout`), and a key that doubles as a caption is a key
    /// that cannot be renamed without moving a photographer's stored panel state.
    var title: String {
        switch self {
        case .cull: return "Cull"
        case .develop: return "Develop"
        case .crop: return "Crop"
        case .grade: return "Grade"
        case .deliver: return "Deliver"
        }
    }

    /// ⌘1–⌘5, in declaration order. The owner chose the modifier so that bare `1`–`5`
    /// stay star ratings and culling keeps its Lightroom muscle memory (docs/29 §2.1).
    var shortcutDigit: String {
        String((Self.allCases.firstIndex(of: self) ?? 0) + 1)
    }

    /// The workspace's glyph — drawn on the way out of masking, and nowhere else in
    /// this file on purpose (`workspaceStrip` states the arithmetic that ruled it out
    /// of the tab strip).
    ///
    /// It exists as a table anyway because the switcher is not the only surface that
    /// names these five: the View menu lists all of them, and a menu and a bar that
    /// picked their own icons would be two tables to keep in step. One table, read from
    /// wherever a workspace has to be drawn.
    var symbolName: String {
        switch self {
        // The grid, which is what Cull IS: `sections` is empty for this workspace and
        // the emptiness is the feature, so the glyph names the centre pane rather than
        // a column that is not there.
        case .cull: return "square.grid.2x2"
        // Sliders, because that is what the column becomes. Not a wand or a dial —
        // Develop is the normalising half of the split and its work is numeric.
        case .develop: return "slider.horizontal.3"
        // `crop.rotate` rather than the plain `crop` that `WorkspaceSection.frame`
        // wears. The workspace holds Crop AND Lens, so it is geometry entire, and the
        // two would otherwise be the same glyph one row apart on the same screen.
        case .crop: return "crop.rotate"
        // The interpreting half. A brush, deliberately not a palette: `color` and
        // `looks` already wear the two palettes, and Grade is the act rather than the
        // swatches.
        case .grade: return "paintbrush"
        // Sending, not saving. `square.and.arrow.up` belongs to Export Recipes, which
        // is one section INSIDE this workspace; using it here as well would say the
        // workspace and the section were the same thing.
        case .deliver: return "paperplane"
        }
    }
}

// MARK: - Glyphs

// AN SF SYMBOL PER SECTION, AND WHY THE TABLE LIVES HERE RATHER THAN IN LUMENCORE.
//
// The owner asked for it in his own words: "I'd also love it if we could add visuals a
// little bit more … giving the curves item a curve emoticon, and stuff like that, or
// overall just livening the app up a little bit more." He means SF Symbols; it is also
// docs/30 item 1.6, which wanted "an SF Symbol per section — a point-curve glyph for
// Curve, an aperture for Detail" and, in the same breath, a single home for it "so the
// header and the ⌘K palette read the same one".
//
// This file is that home, and `Workspace.swift` says why it cannot be the enum's: "What
// is deliberately not here … Anything presentational: no symbol names, no widths, no
// colours." A symbol name is the one fact about a section that would have to be thrown
// away if this app were ever drawn by something that is not SwiftUI. `title` is data —
// the header prints it. A glyph is a drawing instruction, so it sits beside the views
// that draw it, next to `Workspace.title` and `shortcutDigit`, which are here for
// exactly this reason.
//
// BOTH SWITCHES ARE EXHAUSTIVE AND NEITHER HAS A `default:`, which is the whole reason
// they are switches rather than dictionaries. A fifteenth section added to LumenCore
// cannot compile until it has answered this, and that matters more than it usually does
// because of how the failure looks: `Image(systemName:)` handed a name macOS does not
// know draws NOTHING AT ALL — no placeholder, no log line, no red. A missing case, a
// `default:` returning "", or one mistyped character all produce the same silent gap in
// the column, and the person who added the section would have no reason to look.
//
// WHICH NAMES ARE SAFE. Package.swift declares `.macOS(.v15)`, so the floor is SF
// Symbols 6 and every name below clears it with room. Most have existed since SF
// Symbols 1; the four that have not — `circle.lefthalf.filled` (3),
// `thermometer.medium`, `swatchpalette` and the curve (all 4) — arrived with macOS 12
// and 13. `camera.aperture` is already drawn in `FilterBar`, which is the one name here
// this codebase has seen render.

extension WorkspaceSection {

    /// The glyph the section header draws, and the same one the ⌘K palette puts beside
    /// the control it is offering to take you to. One table, two surfaces, so a
    /// photographer who learns the mark in the column recognises it in the palette.
    var symbolName: String {
        switch self {
        // Colour temperature, which is exactly what Temp and Tint are. The alternative
        // was a droplet, and a droplet says "water" in a panel that already draws an
        // eyedropper two rows down for the white-balance PICK — one glyph per idea.
        case .whiteBalance: return "thermometer.medium"
        // Light against dark across one shape: the six-slider tone contract in a
        // circle. It is the closest thing SF Symbols has to a contrast control.
        case .tone: return "circle.lefthalf.filled"
        // The section is called Crop and this is called `crop`. Nothing to argue.
        case .frame: return "crop"
        // THE ONE THE OWNER ASKED FOR BY NAME — "giving the curves item a curve
        // emoticon". It is a bezier between two control points, which is not a glyph
        // that merely suggests a curve; it is a picture of the editor underneath it.
        case .curve: return "point.topleft.down.to.point.bottomright.curvepath"
        // Texture, Clarity and Dehaze — the three sliders that make a flat frame read
        // as present. The standard "enhance" glyph, and the only near-collision in this
        // table: `LumenSlider`'s per-row auto button is `wand.and.stars`. They differ
        // in silhouette and never in position — that wand is at the right end of a
        // slider row, this one at the left end of a header.
        case .presence: return "wand.and.rays"
        // Sharpening and denoise, which is work done at the pixel. A dot grid says
        // "the fine structure" without pretending to be a magnifier; the app's one
        // `magnifyingglass` belongs to the filter bar's search.
        case .detail: return "circle.grid.3x3"
        // An aperture for the lens section, which is docs/30 1.6's own example.
        case .optics: return "camera.aperture"
        // A swatch fan: a SET of finished looks to pick from, which is what saved Looks
        // are. Not `photo.stack` — this app has photo stacks, and they are a different
        // thing in the library sidebar.
        case .looks: return "swatchpalette"
        // The mixer, Point Colour and B&W. A painter's palette is mixing, which is the
        // verb of this section, against the swatch fan above it which is choosing.
        case .color: return "paintpalette"
        // Three overlapping filter circles — the shadows/midtones/highlights wheels
        // drawn as the thing they are. Reads as colour grading in every tool that has
        // ever shipped one.
        case .grading: return "camera.filters"
        // A filmstrip, for the section that emulates film.
        case .filmLab: return "film"
        // Vignette, grain and retouch. The generic "effects" glyph, used generically on
        // purpose: these are the adjustments that do not belong to any one discipline.
        case .effects: return "sparkles"
        // A soft proof is a rehearsal of a print, so the glyph is the printer it is
        // rehearsing for.
        case .softProof: return "printer"
        // The share glyph, because export is the file leaving the app. Its workspace
        // wears `paperplane` instead so the two are not one mark twice.
        case .exportRecipes: return "square.and.arrow.up"
        }
    }
}

// MARK: - The accordion

/// One workspace's sections, each collapsible, solo by default.
///
/// `layout.visibleSections` already answers "which sections, in which order, under this
/// register" — this walks that list and nothing else, so a section can never appear here
/// that the model does not think is visible, and the canonical order is the model's.
struct WorkspaceSections: View {
    @ObservedObject var panel: PanelLayout
    /// Which sections carry a non-default value, for the header dot and for the
    /// hidden-active indicator. Derived from the recipe by the caller, because the
    /// LumenCore model deliberately does not know how to read a recipe.
    let nonDefault: Set<WorkspaceSection>

    /// 8, not 2, and the gap is now doing work rather than merely existing.
    ///
    /// Each section is a card (`WorkspaceSectionView`), so this is the trough between
    /// two of them — the darker `windowBase` the column paints showing through. Below
    /// about 6 the cards read as one banded surface; much above 10 and the column starts
    /// to feel gappy while scrolling.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(panel.layout.visibleSections, id: \.self) { section in
                WorkspaceSectionView(
                    section: section,
                    isExpanded: panel.layout.expanded.contains(section),
                    isModified: nonDefault.contains(section),
                    onToggle: { optionHeld in
                        panel.headerClicked(section, optionHeld: optionHeld)
                    })
            }
            hiddenIndicator
        }
    }

    /// THE REGISTER'S CONTROL AND ITS HONESTY CLAUSE, in one line at the foot of the
    /// column — which is where the eye ends up after reading the sections.
    ///
    /// Two jobs that had to become one. The honesty clause first: a register that hides
    /// a section does NOT revert it (that is `DisclosureRegister`'s stated contract), so
    /// Simple can be concealing live adjustments, and a photographer looking at a
    /// picture that does not match the controls in front of them has no way to find out
    /// why. That is worse than the eight tabs this replaces.
    ///
    /// But an indicator that only appears when something is MODIFIED leaves a second
    /// hole, and it is the one the tab strip did not have: in Simple, Develop draws
    /// three sections of six and Grade two of five, and a photographer who has never
    /// touched Grading has nothing on screen telling them Grading exists. Hiding a
    /// feature until you have already used it is not a simple mode, it is a missing one.
    ///
    /// So the line is always drawn. It carries the count and the accent dot when there
    /// is something concealed, and plain wording when there is not, and either way it is
    /// the door.
    @ViewBuilder
    private var hiddenIndicator: some View {
        let concealed = panel.layout.hiddenActiveIndicator(nonDefault: nonDefault)
        let isSimple = panel.layout.register == .simple
        Button {
            panel.toggleRegister()
        } label: {
            HStack(spacing: 4) {
                if concealed != nil {
                    Circle().fill(Lumen.accent).frame(width: 5, height: 5)
                }
                Text(concealed ?? (isSimple ? "Show all sections" : "Show fewer sections"))
                    .font(.lumenCaption)
                    .foregroundStyle(Lumen.secondaryText)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // THE TWELVE POINTS CAME OUT OF THE LABEL, and that had to happen before a hover
        // fill could go on at all. `.padding(.top, 12)` was INSIDE the button's label, so
        // the button's bounds — and therefore anything painted behind them — began twelve
        // points above the words: a hover would have drawn a tall empty pill with the
        // text stuck along its bottom edge. The space before a control is not part of it.
        .lumenHoverable(radius: Lumen.radiusChip)
        .lumenClickCursor()
        .padding(.top, 12)
        .padding(.horizontal, 4)
        .help(isSimple
              ? "Show every section in this workspace"
              : "Show only the sections most edits need")
    }
}

/// One section: its header, and its rows when it is open — drawn as a CARD.
///
/// The header is the column's rather than the panel's, so that every section in every
/// workspace gets the same chevron, the same boundary and the same click rule —
/// including the ones assembled out of several panels' pieces, which could not have
/// agreed on it themselves.
///
/// THE CARD IS THE SEPARATOR, and it is the answer to the loudest thing in the owner's
/// second review: "I get a fatigue when I scroll down because everything is so close
/// together … Lightroom has some sort of kind of separator from each different area so
/// that you can tell somewhat that you're entering into a new area."
///
/// A hairline was the obvious reading of that sentence and it is the wrong one here.
/// `Lumen.separator` measures 1.48:1 against the panel — a line the eye does not resolve
/// without being told where to look — so the choice would have been between an invisible
/// rule and repainting a token that eleven other files draw with. And a rule between two
/// stretches of identical grey only says "a line happened"; it does not say the surface
/// changed. `LumenSurface.swift` argues the alternative at length and had zero call
/// sites: give the section an EDGE — a lit top border over its own fill, sitting in a
/// darker trough — and the eye stops hunting for a boundary and starts reading an
/// object. Six of those down a column is unmistakably six areas, at any scroll speed.
///
/// THE HORIZONTAL ARITHMETIC, and it changed on the owner's third review: "I feel like
/// there isn't enough padding from the sides of the Exposure, Contrast, stuff like that,
/// the text, so it's really, really close to the wall. Can we move those in just a little
/// bit more so it's a little more comfortable?"
///
/// He is right, and the number says why. `scrollColumn` gave up its 8 points of side
/// padding to 4 and the card held the other 4, so "Exposure" began **8 points** from the
/// panel's edge — a gutter narrower than the gap between two of its own letters, on a
/// card whose corner radius is now 14. Ten points inside the card puts the label 14 from
/// the edge, which is the same distance as the corner, so the text clears the curve
/// instead of tucking under it.
///
/// It costs the track 12 points, and that is affordable now in a way it was not before:
/// the column is draggable (`ContentView.columnResizer`), so a photographer who wants
/// those points back takes them, and the default width is 380 rather than the 320 the
/// original arithmetic was measured against.
private struct WorkspaceSectionView: View {
    let section: WorkspaceSection
    let isExpanded: Bool
    let isModified: Bool
    let onToggle: (Bool) -> Void
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // `topRhythm: 0` — the card's own padding is the boundary now, and stacking
            // twenty more points of blank panel on top of it inside the card would only
            // push the title away from the rows it names.
            LumenSectionHeader(title: section.title,
                               symbol: section.symbolName,
                               isExpanded: .constant(isExpanded),
                               isModified: isModified,
                               onReset: reset,
                               topRhythm: 0,
                               onToggle: onToggle)
            // CLOSED MEANS CLOSED. `DevelopSection` and `DevelopDisclosure` both take
            // their content as a closure now for this reason: a section that collapses
            // but still CONSTRUCTS its rows costs a drag exactly what the accordion
            // claims to save, and Look holds 38 sliders in one of these.
            if isExpanded {
                WorkspaceSectionBody(section: section)
                    // UNFOLDING, NOT SLIDING — the other half of "the animation for the
                    // open and close for the chevrons are not great".
                    //
                    // It was `.move(edge: .top)`, which translates the whole body
                    // downward by its own height while the column's height grows to meet
                    // it. On a section of three rows that reads as a drawer; on Look's
                    // thirty-eight it is a long vertical wipe travelling at a completely
                    // different speed from the card growing around it, and the two fight
                    // visibly. A scale anchored at the top has no distance in it to get
                    // wrong: the body expands from the header's own edge, at 0.97 so it
                    // is felt rather than watched, and the card's clip keeps it from ever
                    // painting over the section below.
                    .transition(.opacity.combined(
                        with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        // `.flush`: an edge but no cast shadow. Six drop shadows stacked down a
        // scrolling column is a pile of floating tiles, and these are tiled edge to
        // edge — which is the case `Lumen.Elevation` names this step for.
        .lumenSurface(radius: Lumen.radiusCard, elevation: .flush, fill: Lumen.panel)
    }

    /// RESET BELONGS TO THE SECTION HEADER NOW, and the section is the column's idea of
    /// one rather than any single panel's.
    ///
    /// It used to belong to whichever `DevelopSection` a panel happened to draw, which
    /// left three holes the accordion would have shipped: a section assembled from
    /// several panels — Optics out of Crop and Lens, Effects out of Vignette, Grain and
    /// Retouch — had no single Reset at all; a section folded into a `DevelopDisclosure`
    /// lost the one it had, which is what happened to Denoise and to Zones; and a panel
    /// that drops its own header under `only:` would have taken its Reset with it.
    ///
    /// The mutation itself is `WorkspaceSection.reset` in LumenCore, where a property
    /// test asserts the thing that actually matters: reset a section and its dot must go
    /// out, and no other section's may. Two hand-written closures would not have stayed
    /// true to each other for a month.
    private var reset: (() -> Void)? {
        // A button that does nothing is the same lie as a caption promising a dead
        // shortcut. Only offer it where there is something to put back.
        guard isModified else { return nil }
        if section == .softProof {
            // The whole struct, not just the toggle: destination space, intent, gamut
            // warning and paper simulation go together, and a reset that only flipped
            // `enabled` would leave a proof configured for a destination nothing names
            // any more. Not in the recipe at all — soft proof is the session's.
            return { state.softProof = SoftProof() }
        }
        guard section.resetsTheRecipe else { return nil }
        return {
            let denoiseStart = denoiseDefault
            state.updateRecipe(coalescingKey: "workspace.\(section.rawValue).reset") {
                recipe in
                section.reset(&recipe)
                // `reset` writes `Denoise()` because LumenCore cannot know the ISO. The
                // photograph's own starting point is the honest default, and it is the
                // one double-clicking a denoise slider already lands on.
                if section == .detail, let denoiseStart {
                    recipe.develop.denoise = denoiseStart
                }
            }
        }
    }

    /// The photograph's own denoise starting point, or nil for a rendered file that has
    /// no ISO profile to start from.
    private var denoiseDefault: Denoise? {
        guard let photo = state.primarySelection,
              !PhotoFormats.isRendered(photo.id),
              let iso = photo.iso else { return nil }
        return ISODefaults.startingDenoise(forISO: Double(iso))
    }
}

/// The one place a section name becomes a view.
///
/// Every panel takes an `only:` naming the section it should render, so the split ones —
/// Effects across three workspaces, Look across three sections — stay single files with
/// their bindings and their reset logic intact, rather than being cut into pieces that
/// would each need their own copy of both.
private struct WorkspaceSectionBody: View {
    let section: WorkspaceSection
    @EnvironmentObject var state: AppState

    var body: some View {
        switch section {
        case .whiteBalance: BasicPanel(only: .whiteBalance)
        case .tone: BasicPanel(only: .tone)
        case .presence: BasicPanel(only: .presence)
        case .curve: CurveEditorView(histogram: state.scopes?.histogram)
        case .detail: DetailPanel(only: .detail)
        case .frame: EffectsPanel(only: .frame)
        case .optics: EffectsPanel(only: .optics)
        case .looks: LookPanel(only: .looks)
        case .color: ColorPanel(only: .color)
        case .grading: LookPanel(only: .grading)
        case .filmLab: LookPanel(only: .filmLab)
        case .effects: EffectsPanel(only: .effects)
        case .softProof: EffectsPanel(only: .softProof)
        case .exportRecipes: ExportRecipesSection()
        }
    }
}

// MARK: - The mask editor

/// THE COLUMN WHILE MASKING — the whole of it, not a dock above it.
///
/// It was a dock: the mask list stacked on top of the workspace's own sections, both
/// scrolling together. The owner named what was wrong with that — "when I press it, it
/// just shows up on the page that I am showing off" — and asked for "its own page ...
/// its own kind of section area where you can fully customize stuff about the masks".
///
/// The mask model says he is right rather than merely particular. `LocalAdjust` carries
/// twenty scalars plus a local point curve and local grading wheels, so a mask's
/// adjustments are a copy of the globals: stacked, the column offered Tone, Curve,
/// Colour and Grading TWICE, twenty rows apart, meaning different things depending on
/// how far you had scrolled. Nobody masking wants the global Tone — they want this
/// mask's Tone, and it is right here.
///
/// So this replaces `WorkspaceSections` rather than sitting above it, and the switcher
/// above becomes the way back (`WorkspaceSwitcher.maskingBar`). The workspace underneath
/// is untouched — `expanded`, `register` and `workspace` all survive, so leaving returns
/// the column exactly as it was left.
///
/// No header of its own: the bar above prints "Masks", and `MaskPanel` printing it again
/// a row below is the duplication that was here before this was a takeover.
struct MaskEditor: View {
    @ObservedObject var panel: PanelLayout
    /// This surface shows the edit, so it observes the edit signal — `AppState.recipes`
    /// is deliberately not published (see `EditRevision`).
    @EnvironmentObject private var edits: EditRevision

    var body: some View {
        MaskPanel(showsOwnHeader: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Ten, matching `WorkspaceSectionView`: the takeover wears the accordion's
            // card, so it has to wear the accordion's gutter or the column's text edge
            // would jump sideways every time masking opened.
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 8)
            // The same card the accordion's sections wear, for the same reason and to
            // keep the column's edges aligned across the takeover: while masking has the
            // column this IS the area, so it should sit on the surface an area sits on
            // rather than directly on the trough between them.
            .lumenSurface(radius: Lumen.radiusCard, elevation: .flush, fill: Lumen.panel)
    }
}

/// Deliver's second section, and the honest version of it.
///
/// Export recipes exist and are edited, but only inside `ExportSheet` — a modal. There
/// is no panel-shaped view to re-parent here, and inventing a second editor for the same
/// data would be two places for a recipe to be wrong. So the section says what it is and
/// opens the one that exists. Lifting the sheet's editor into the column is its own
/// change, and a larger one than this phase.
private struct ExportRecipesSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DevelopNote("Export recipes are edited in the export sheet.")
            Button("Open Export…") { state.activeSheet = .export }
                .buttonStyle(.plain)
                .font(.lumenBody)
                .foregroundStyle(Lumen.accent)
                .lumenClickCursor()
        }
        .padding(.top, 2)
    }
}
#endif
