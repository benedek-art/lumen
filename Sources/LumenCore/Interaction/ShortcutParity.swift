// ShortcutParity.swift
// The decisions behind the Lightroom-habit keys — J, ⌘= / ⌘−, Tab / ⇧Tab — as pure
// rules, because the dispatcher and the menu that carry them out cannot be tested here.
//
// Each rule is small on purpose. The app layer asks one question per key press and does
// what the answer says; nothing about which panel comes back, or what ⌘= means in the
// grid, is decided in a file that only compiles on a Mac.

import Foundation

// MARK: - J: the both-ends clipping overlay

extension ClippingOverlay {

    /// Lightroom's highlight-clipping red.
    public static let bothEndsHighColour = RGB(1, 0, 0)
    /// Lightroom's shadow-clipping blue, lifted a little so it reads on a dark frame.
    public static let bothEndsLowColour = RGB(0, 0.35, 1)

    /// The mask `bothEnds` returns for a pixel crushed in all three channels. Above
    /// every channel combination (0…7), so `colour(mask:)` can tell it apart and the
    /// five single-ended modes can never produce it.
    public static let bothEndsLowMask: Int = 8

    /// `bothEnds`: 7 when every channel is at the ceiling, `bothEndsLowMask` when every
    /// channel is at the floor, 0 otherwise. All three, not any: one channel at the floor
    /// is a saturated colour, and a whole jersey painted blue would bury the frame.
    public static func bothEndsMask(_ c: RGB) -> Int {
        let high = mask(c, mode: .whites)
        if high == 7 { return 7 }
        let low = mask(c, mode: .blacks)
        if low == 7 { return bothEndsLowMask }
        return 0
    }

    /// What `J` does to the overlay: off → both ends, and anything on → off. A locked
    /// histogram triangle counts as on, so `J` is always the way out.
    public static func toggledByJ(_ current: Mode?) -> Mode? {
        current == nil ? .bothEnds : nil
    }
}

// MARK: - ⌘= / ⌘−

/// What a zoom chord does on the surface in front of the photographer.
public enum ZoomChordAction: Equatable, Sendable {
    case loupeZoomIn
    case loupeZoomOut
    /// The contact sheet: the cell size, by the same step `[` and `]` use there.
    case stepThumbnails(delta: Double)
    /// Compare and Survey keep their zoom inside the view; the chord says so instead.
    case unavailable
}

public enum ZoomChord {

    public static func resolve(zoomIn: Bool, surface: InspectionSurface) -> ZoomChordAction {
        switch surface {
        case .loupe:
            return zoomIn ? .loupeZoomIn : .loupeZoomOut
        case .grid:
            let step = InspectionHolds.thumbnailStep
            return .stepThumbnails(delta: zoomIn ? step : -step)
        case .compare, .survey:
            return .unavailable
        }
    }
}

// MARK: - Tab / ⇧Tab

/// Which of the three hideable panels are on screen, as the photographer set them.
public struct PanelVisibility: Equatable, Sendable {
    public var sidebar: Bool
    public var developColumn: Bool
    public var filmstrip: Bool

    public init(sidebar: Bool, developColumn: Bool, filmstrip: Bool) {
        self.sidebar = sidebar
        self.developColumn = developColumn
        self.filmstrip = filmstrip
    }

    public static let all = PanelVisibility(sidebar: true, developColumn: true, filmstrip: true)
}

public enum PanelChord: Sendable {
    /// Tab: the sources sidebar and the develop column.
    case sidePanels
    /// ⇧Tab: those two and the filmstrip.
    case allPanels
}

/// Lightroom's Tab / ⇧Tab: hide if anything in scope is showing, otherwise bring back
/// what was showing before the last hide. Lights-out is untouched; this is layout only.
public struct PanelChromeToggle: Equatable, Sendable {

    /// What the last hide took away, so the next press restores that rather than
    /// everything. Nil after a restore.
    public private(set) var remembered: PanelVisibility?

    public init(remembered: PanelVisibility? = nil) {
        self.remembered = remembered
    }

    public mutating func apply(_ chord: PanelChord, to current: PanelVisibility) -> PanelVisibility {
        switch chord {
        case .sidePanels:
            if current.sidebar || current.developColumn {
                remembered = current
                var next = current
                next.sidebar = false
                next.developColumn = false
                return next
            }
            var next = current
            next.sidebar = remembered?.sidebar ?? true
            next.developColumn = remembered?.developColumn ?? true
            // A restore that restores nothing would make the key look dead.
            if !next.sidebar && !next.developColumn {
                next.sidebar = true
                next.developColumn = true
            }
            remembered = nil
            return next
        case .allPanels:
            if current.sidebar || current.developColumn || current.filmstrip {
                remembered = current
                return PanelVisibility(sidebar: false, developColumn: false, filmstrip: false)
            }
            var next = remembered ?? .all
            if !next.sidebar && !next.developColumn && !next.filmstrip {
                next = .all
            }
            remembered = nil
            return next
        }
    }
}
