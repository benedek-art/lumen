// InteractionTimeline.swift
// What happened between a control moving and the picture changing, as a list of
// stamped events: the input, the render request it led to, the render starting, and
// the frame being handed to the view. The summary is the starvation test — frames
// that landed while input was still arriving, and the longest wait between them.

import Foundation

public struct InteractionTimeline: Sendable, Equatable {

    public enum Stage: String, Codable, Sendable {
        /// A pixel-touching edit was written. `revision` is the edit revision after it.
        case input
        /// The viewer asked for a draft of `revision`.
        case request
        /// A render of `revision` began on the render lane.
        case start
        /// A frame depicting `revision` was handed to the view.
        case frame
    }

    public struct Stamp: Codable, Sendable, Equatable {
        public let kind: Stage
        /// Monotonic uptime, nanoseconds.
        public let nanoseconds: UInt64
        /// The edit revision the entry concerns — the value identity of a frame.
        public let revision: Int
        /// Frames only: draft or settle, delivered long edge, render start to landing.
        public var draft: Bool?
        public var longEdge: Int?
        public var renderMilliseconds: Double?

        public init(kind: Stage, nanoseconds: UInt64, revision: Int, draft: Bool? = nil,
                    longEdge: Int? = nil, renderMilliseconds: Double? = nil) {
            self.kind = kind
            self.nanoseconds = nanoseconds
            self.revision = revision
            self.draft = draft
            self.longEdge = longEdge
            self.renderMilliseconds = renderMilliseconds
        }
    }

    /// Oldest entries are dropped past this: minutes of dragging, a few megabytes.
    public static let capacity = 32_768

    public private(set) var entries: [Stamp] = []

    public init() {}

    public mutating func record(_ entry: Stamp) {
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    public mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    public struct Summary: Codable, Sendable, Equatable {
        public var inputs = 0
        public var frames = 0
        /// First input to last input.
        public var inputSpanMilliseconds: Double = 0
        /// Frames handed to the view after the first input and no later than the last.
        public var framesDuringInput = 0
        /// The longest wait for a frame between the first input and the first frame
        /// at or after the last input. Nil when there was no input, or no frame after it.
        public var maxFrameGapMilliseconds: Double?
        /// The longest time from an input to the first frame depicting it. Inputs that
        /// were skipped past are not counted.
        public var maxInputToFrameMilliseconds: Double?
        /// The last input to the first frame depicting it. Nil if it never rendered.
        public var lastInputToFrameMilliseconds: Double?
        public var lastInputRevision: Int?
        public var lastFrameRevision: Int?

        /// The final value reached the screen.
        public var lastInputWasRendered: Bool {
            guard let input = lastInputRevision else { return true }
            guard let frame = lastFrameRevision else { return false }
            return frame >= input
        }
    }

    /// The summary beside the entries it was computed from: what a driver writes out.
    public struct Transcript: Codable, Sendable, Equatable {
        public let summary: Summary
        public let entries: [Stamp]
    }

    public func transcript() -> Transcript {
        Transcript(summary: summary(), entries: entries)
    }

    public func summary() -> Summary {
        var out = Summary()
        let inputs = entries.filter { $0.kind == .input }
        let frames = entries.filter { $0.kind == .frame }
        out.inputs = inputs.count
        out.frames = frames.count
        out.lastInputRevision = inputs.last?.revision
        out.lastFrameRevision = frames.map(\.revision).max()
        guard let first = inputs.first?.nanoseconds,
              let last = inputs.last?.nanoseconds else { return out }
        func milliseconds(_ from: UInt64, _ to: UInt64) -> Double {
            to >= from ? Double(to - from) / 1e6 : 0
        }
        out.inputSpanMilliseconds = milliseconds(first, last)
        out.framesDuringInput = frames.filter {
            $0.nanoseconds > first && $0.nanoseconds <= last
        }.count

        // The gap walk ends on the first frame at or after the last input: a drag that
        // delivered nothing until release then reads as one gap the length of the drag.
        if let closing = frames.first(where: { $0.nanoseconds >= last })?.nanoseconds {
            var previous = first
            var longest: Double = 0
            for frame in frames where frame.nanoseconds > first
                && frame.nanoseconds <= closing {
                longest = Swift.max(longest, milliseconds(previous, frame.nanoseconds))
                previous = frame.nanoseconds
            }
            out.maxFrameGapMilliseconds = longest
        }

        // Only the first frame to show a newer revision counts: a settle of a revision
        // already on screen is sharpness arriving, not the value arriving.
        var slowest: Double?
        var newestShown = Int.min
        for frame in frames where frame.revision > newestShown {
            newestShown = frame.revision
            guard let input = Self.lastInput(atOrBefore: frame.revision, in: inputs),
                  frame.nanoseconds >= input.nanoseconds else { continue }
            let took = milliseconds(input.nanoseconds, frame.nanoseconds)
            slowest = Swift.max(slowest ?? 0, took)
            if input.revision == out.lastInputRevision { out.lastInputToFrameMilliseconds = took }
        }
        out.maxInputToFrameMilliseconds = slowest
        return out
    }

    /// Inputs are recorded in revision order, so this is a binary search.
    private static func lastInput(atOrBefore revision: Int, in inputs: [Stamp]) -> Stamp? {
        var low = 0
        var high = inputs.count
        while low < high {
            let middle = (low + high) / 2
            if inputs[middle].revision <= revision { low = middle + 1 } else { high = middle }
        }
        return low > 0 ? inputs[low - 1] : nil
    }
}
