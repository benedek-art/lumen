// ShortcutParityKeys.swift
// The Lightroom-habit keys, carried out: J, W, I and ? (bare, claimed by the
// dispatcher's switch in Keymap.swift), ⌘← / ⌘→ and Tab / ⇧Tab (special keys, offered
// here by two one-line hooks in `KeyDispatcher.handle`), and ⌘= / ⌘− (View menu).
//
// What each key MEANS lives in LumenCore — `ShortcutParity.swift` and `CaptureInfo.swift`
// — where it is tested. This file only reads the state and applies the answer.

#if os(macOS)

import AppKit
import Foundation
import LumenCore
import LumenPipeline
import SwiftUI

@MainActor
enum ParityKeys {

    /// What the last Tab / ⇧Tab hid, so the next press brings back exactly that.
    private static var panelToggle = PanelChromeToggle()

    // MARK: Bare keys

    /// J: the both-ends clipping overlay, or off.
    static func toggleClippingOverlay(state: AppState) {
        let next = ClippingOverlay.toggledByJ(state.clippingOverlay)
        state.clippingOverlay = next
        state.statusMessage = next == nil
            ? "Clipping overlay off"
            : "Clipping overlay: highlights red, shadows blue"
    }

    /// W: arm the white-balance eyedropper, or put it away — the Basic panel's button.
    static func toggleNeutralPick(state: AppState) {
        if state.pickTarget == .neutral {
            state.cancelPick()
        } else {
            state.beginPick(.neutral)
        }
    }

    /// I: off → exposure → full card → off.
    static func cycleCaptureInfo(state: AppState) {
        let display = CaptureInfoDisplay.shared
        display.mode = display.mode.next
        state.statusMessage = display.mode.statusText
    }

    // MARK: Special keys

    /// ⌘← / ⌘→ page the roll. Asked BEFORE the dispatcher's ⌘ guard, because the bare
    /// arrows stand down while the loupe is zoomed in (they pan) or a slider holds focus
    /// (they nudge) — and those are exactly the moments a photographer checking focus
    /// across a burst wants the next frame. Nil for anything else, so every other ⌘
    /// chord still reaches the menu.
    static func pageChord(_ event: NSEvent, state: AppState,
                          flags: NSEvent.ModifierFlags) -> Bool? {
        let held = flags.intersection([.command, .shift, .option, .control])
        guard held == .command,
              let first = event.charactersIgnoringModifiers?.unicodeScalars.first
        else { return nil }
        switch Int(first.value) {
        case NSRightArrowFunctionKey:
            state.selectNext()
        case NSLeftArrowFunctionKey:
            state.selectPrevious()
        default:
            return nil
        }
        return true
    }

    /// Tab hides the sidebar and the develop column; ⇧Tab (which arrives as backtab,
    /// 0x19) hides the filmstrip as well. A focused slider keeps Tab for moving focus.
    static func panelChord(_ event: NSEvent, state: AppState,
                           flags: NSEvent.ModifierFlags) -> Bool? {
        guard let first = event.charactersIgnoringModifiers?.unicodeScalars.first
        else { return nil }
        let value = Int(first.value)
        guard value == 0x09 || value == 0x19 else { return nil }
        guard !state.sliderHoldsFocus else { return nil }
        // Held down, Tab would flicker the layout at the key-repeat rate.
        if event.isARepeat { return true }

        let chord: PanelChord = (value == 0x19 || flags.contains(.shift))
            ? .allPanels : .sidePanels
        applyPanels(chord, state: state)
        return true
    }

    /// The key's and the View menu item's shared body.
    static func applyPanels(_ chord: PanelChord, state: AppState) {
        let current = PanelVisibility(sidebar: state.sidebarVisible,
                                      developColumn: !state.developColumnHidden,
                                      filmstrip: state.showFilmstrip)
        let next = panelToggle.apply(chord, to: current)
        if state.sidebarVisible != next.sidebar { state.sidebarVisible = next.sidebar }
        if state.developColumnHidden == next.developColumn {
            state.developColumnHidden = !next.developColumn
        }
        if state.showFilmstrip != next.filmstrip { state.showFilmstrip = next.filmstrip }
        let anyShown = next.sidebar || next.developColumn || next.filmstrip
        state.statusMessage = anyShown && next != .all
            ? "Panels partly hidden — Tab or ⇧Tab brings them back"
            : (anyShown ? "Panels shown" : "Panels hidden — ⇧Tab brings them back")
    }

    // MARK: Menu chords

    /// ⌘= / ⌘−, from the View menu.
    static func zoomChord(zoomIn: Bool, state: AppState) {
        switch ZoomChord.resolve(zoomIn: zoomIn, surface: surface(state.viewMode)) {
        case .loupeZoomIn:
            LoupeViewport.shared.zoomIn()
        case .loupeZoomOut:
            LoupeViewport.shared.zoomOut()
        case .stepThumbnails(let delta):
            state.gridThumbnailSize = Swift.min(
                Swift.max(state.gridThumbnailSize + delta, AppState.minThumbnailSize),
                AppState.maxThumbnailSize)
        case .unavailable:
            state.statusMessage = "⌘= and ⌘− zoom the loupe (E) and size the grid"
        }
    }

    private static func surface(_ mode: ViewMode) -> InspectionSurface {
        switch mode {
        case .grid: return .grid
        case .loupe: return .loupe
        case .compare: return .compare
        case .survey: return .survey
        }
    }
}

// MARK: - The loupe's capture-info overlay (I)

/// Which rung of the `I` cycle is showing. An object of its own, observed by the
/// overlay alone, so a press re-bodies one small view and not the window. Not
/// `@MainActor`-annotated, like `LoupeViewport`, so `shared` can seed a view property.
final class CaptureInfoDisplay: ObservableObject {
    static let shared = CaptureInfoDisplay()
    @Published var mode: CaptureInfoMode = .off
}

/// One file's EXIF, read off the main actor.
private struct CaptureInfoLoad: Equatable, Sendable {
    let url: URL
    let metadata: PhotoMetadata?
    let captureTime: DateComponents?
}

/// File name, shutter · aperture · ISO · focal length, and on the second rung camera,
/// lens and capture time. Read from the file rather than the catalog so it works on a
/// folder the metadata backfill has not reached yet.
struct CaptureInfoOverlay: View {

    let photo: PhotoItem
    @ObservedObject private var display: CaptureInfoDisplay = CaptureInfoDisplay.shared
    @State private var loaded: CaptureInfoLoad?

    private struct LoadKey: Equatable {
        let url: URL
        let showing: Bool
    }

    private var lines: [String] {
        guard let loaded, loaded.url == photo.id else {
            // Until the read lands, the name only: "No exposure data" would be a claim.
            return Array(CaptureInfoFormat.lines(mode: display.mode,
                                                 fileName: photo.filename,
                                                 metadata: nil).prefix(1))
        }
        return CaptureInfoFormat.lines(mode: display.mode, fileName: photo.filename,
                                       metadata: loaded.metadata,
                                       captureTime: loaded.captureTime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                LumenBadge(text: line)
            }
        }
        .allowsHitTesting(false)
        .task(id: LoadKey(url: photo.id, showing: display.mode != .off)) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        guard display.mode != .off else { return }
        let url = photo.id
        let read: CaptureInfoLoad = await Task.detached(priority: .utility) {
            CaptureInfoOverlay.read(url: url)
        }.value
        guard !Task.isCancelled else { return }
        loaded = read
    }

    private nonisolated static func read(url: URL) -> CaptureInfoLoad {
        CaptureInfoLoad(url: url,
                        metadata: CaptureMetadataReader.read(url: url),
                        captureTime: CaptureMetadataReader.captureWallClock(url: url))
    }
}

#endif
