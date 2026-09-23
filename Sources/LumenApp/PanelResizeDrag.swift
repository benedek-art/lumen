#if os(macOS)
import Foundation

/// Cumulative gesture translation must be measured from one fixed starting width.
struct PanelResizeDrag {
    private var start: CGFloat?

    mutating func width(current: CGFloat, translation: CGFloat,
                        minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        if start == nil { start = current }
        return min(max((start ?? current) - translation, minimum), maximum)
    }

    mutating func end() { start = nil }
}
#endif
