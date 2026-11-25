// MaskOverlayRule.swift
// Which mask's overlay the loupe shows, as one pure reducer.
//
// Lightroom Classic's "Automatically Toggle Overlay": the overlay is up while a selection
// is being made or worked on, goes away at the first adjustment and stays away, and after
// that appears only while the pointer is on the mask's row or pin. `O` (or the panel's
// overlay control) is an explicit Show/Hide that outranks all of that until the
// photographer returns to Automatic. `AppState` feeds every input through `reduce` and
// draws `resolution.id`; nothing else decides what is shown.

public struct MaskOverlayRule: Equatable, Sendable, Codable {

    /// The photographer's explicit choice. `.automatic` is the default and the only
    /// state in which the ambient inputs below matter.
    public enum Choice: String, Equatable, Sendable, Codable, CaseIterable {
        case automatic, show, hide
    }

    /// Why the overlay is up, for the viewer badge and the state dump.
    public enum Reason: String, Equatable, Sendable, Codable {
        case chosen, selectionWork, panelHover, canvasHover, creating
    }

    public struct Resolution: Equatable, Sendable, Codable {
        public var id: String?
        public var reason: Reason?
        public init(id: String? = nil, reason: Reason? = nil) {
            self.id = id
            self.reason = reason
        }
    }

    public enum Event: Equatable, Sendable {
        /// The mask editor opened or closed.
        case masking(Bool)
        /// The photograph under the cursor changed. Mask ids are per-photograph.
        case photoChanged
        /// The effective selection (the panel's mask, or the first one when none is).
        case selected(String?)
        /// A mask was made and selected.
        case created(String)
        /// A component was added to a mask: selection work, like creation.
        case componentAdded(String)
        /// A drag that moves a selection began on a mask (`id`), or ended (nil):
        /// on-canvas geometry, a brush stroke, an Edge slider.
        case selectionGesture(String?)
        /// An adjustment of the mask changed. `held` is whether a slider is still down.
        case adjusted(String, held: Bool)
        /// Every gesture ended (the app's slider latch closed, undo, a dropped release).
        case gesturesEnded
        /// The pointer entered a mask's row in the Masks panel, or left (nil).
        case panelHover(String?)
        /// The pointer is on a mask's pin on the canvas, or on none (nil).
        case canvasHover(String?)
        /// `O`: hide what is shown, or show what is not.
        case toggle
        case choose(Choice)
        /// The photograph's masks after an edit, undo or redo.
        case masksChanged([String])
    }

    public private(set) var choice: Choice
    public private(set) var masking: Bool
    public private(set) var selectedID: String?
    /// Created (or extended) and not adjusted since.
    public private(set) var creatingID: String?
    public private(set) var gestureID: String?
    public private(set) var adjusting: Bool
    public private(set) var panelHoverID: String?
    public private(set) var canvasHoverID: String?

    public init(masking: Bool = false) {
        self.choice = .automatic
        self.masking = masking
        self.adjusting = false
    }

    public var resolution: Resolution {
        guard masking else { return Resolution() }
        switch choice {
        case .hide:
            return Resolution()
        case .show:
            let id = gestureID ?? panelHoverID ?? canvasHoverID ?? selectedID
            return Resolution(id: id, reason: id == nil ? nil : .chosen)
        case .automatic:
            if let id = gestureID { return Resolution(id: id, reason: .selectionWork) }
            if adjusting { return Resolution() }
            if let id = panelHoverID { return Resolution(id: id, reason: .panelHover) }
            if let id = canvasHoverID { return Resolution(id: id, reason: .canvasHover) }
            if let id = creatingID { return Resolution(id: id, reason: .creating) }
            return Resolution()
        }
    }

    public var shownID: String? { resolution.id }

    public mutating func reduce(_ event: Event) {
        switch event {
        case .masking(let on):
            if !on { clearTransient(); choice = .automatic }
            masking = on
        case .photoChanged:
            clearTransient()
            choice = .automatic
        case .selected(let id):
            guard id != selectedID else { return }
            selectedID = id
            if creatingID != id { creatingID = nil }
            if gestureID != id { gestureID = nil }
        case .created(let id):
            selectedID = id
            creatingID = id
        case .componentAdded(let id):
            creatingID = id
        case .selectionGesture(let id):
            gestureID = id
        case .adjusted(_, let held):
            creatingID = nil
            adjusting = held
        case .gesturesEnded:
            gestureID = nil
            adjusting = false
        case .panelHover(let id):
            panelHoverID = id
        case .canvasHover(let id):
            canvasHoverID = id
        case .toggle:
            choice = shownID == nil ? .show : .hide
        case .choose(let next):
            choice = next
        case .masksChanged(let ids):
            func keep(_ id: String?) -> String? { id.flatMap { ids.contains($0) ? $0 : nil } }
            selectedID = keep(selectedID)
            creatingID = keep(creatingID)
            gestureID = keep(gestureID)
            panelHoverID = keep(panelHoverID)
            canvasHoverID = keep(canvasHoverID)
        }
    }

    private mutating func clearTransient() {
        selectedID = nil
        creatingID = nil
        gestureID = nil
        adjusting = false
        panelHoverID = nil
        canvasHoverID = nil
    }

    /// The overlay control's cycle: Automatic → Show → Hide → Automatic.
    public static func nextChoice(after choice: Choice) -> Choice {
        switch choice {
        case .automatic: return .show
        case .show: return .hide
        case .hide: return .automatic
        }
    }
}
