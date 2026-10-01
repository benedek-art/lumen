// ViewerGestureGate.swift
// Which of the loupe's pointer gestures may move the viewport right now.

/// ONE RULE FOR THE FOUR VIEWER GESTURES, so a fifth cannot be added without it.
///
/// The loupe has four pointer routes to the viewport: the drag (pan), the trackpad
/// pinch, the scroll wheel, and the double-click that toggles fit and 1:1. The first
/// three each began with `guard !cropArmed`; the double-click, added later, began with
/// nothing (V7 D3). So with the crop tool armed — a canvas that ignores zoom and pan —
/// a double-click set the zoom to 1:1 where nobody could see it, and the picture jumped
/// the moment the tool was put away. That is exactly the hazard the drag guard's own
/// comment describes.
///
/// Two answers rather than one, because the gestures are not equally deliberate:
///
///   - `continuous` (drag, pinch, scroll) is refused only while Crop is armed. While a
///     mask is being edited or a colour is being picked, panning and zooming in to
///     place a handle precisely is the whole point, and those gestures cannot happen
///     by accident.
///   - `doubleClickZoom` is refused while Crop is armed AND while masking or picking.
///     There a click is the instrument: placing a handle, brushing, landing a sample.
///     Two of them in quick succession are ordinary work, and must not also toggle
///     the zoom underneath the tool.
public struct ViewerGestureGate: Equatable, Sendable {
    public var cropArmed: Bool
    public var masking: Bool
    public var picking: Bool

    public init(cropArmed: Bool, masking: Bool, picking: Bool) {
        self.cropArmed = cropArmed
        self.masking = masking
        self.picking = picking
    }

    /// Drag, pinch and scroll.
    public var continuous: Bool { !cropArmed }

    /// The fit ↔ 1:1 double-click.
    public var doubleClickZoom: Bool { !cropArmed && !masking && !picking }
}
