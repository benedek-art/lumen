import Foundation

/// Owns one scalar press until its release. The binding can follow another target
/// while a row stays alive, so each sample must still belong to its opening target,
/// mapping and last actual written value. This object has no observation publisher;
/// recording a sample does not itself invalidate a SwiftUI control.
public final class ScalarDragSession<Context: Equatable> {
    public private(set) var isActive = false
    private var invalidated = false
    private var context: Context?
    private var mapping: SliderTrack?
    private var expectedValue = 0.0

    public init() {}

    @discardableResult
    public func begin(context: Context, value: Double, mapping: SliderTrack) -> Bool {
        guard !isActive, !invalidated else { return false }
        self.context = context
        self.mapping = mapping
        expectedValue = value
        isActive = true
        return true
    }

    public func accepts(context: Context, value: Double, mapping: SliderTrack) -> Bool {
        guard isActive, !invalidated else { return false }
        guard self.context == context, self.mapping == mapping, expectedValue == value else {
            invalidated = true
            return false
        }
        return true
    }

    public func recordWrittenValue(_ value: Double) {
        guard isActive, !invalidated else { return }
        expectedValue = value
    }

    /// True means the caller owes exactly one editing-end notification.
    @discardableResult
    public func cancel() -> Bool {
        guard isActive else { return false }
        isActive = false
        invalidated = true
        return true
    }

    /// A cancelled press cannot reopen before this release arrives.
    @discardableResult
    public func finish() -> Bool {
        let shouldClose = isActive
        isActive = false
        invalidated = false
        context = nil
        mapping = nil
        return shouldClose
    }
}
