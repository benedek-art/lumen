// InteractionTimeline.swift
// What happened between a control moving and the picture changing, as a list of
// stamped events: the input, the render request it led to, the render starting, and
// the frame being handed to the view; beside them, each overlay picture put on screen
// and the main-thread time each input cost. The summary is the starvation test —
// frames that landed while input was still arriving, and the longest wait between them.

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
        /// An overlay picture depicting `revision` was put on screen. `name` says which.
        case overlay
        /// The run-loop turn an input was written in has ended, Core Animation's commit
        /// included. `mainMilliseconds` is the main-thread time from that input to here.
        case turn
    }

    public struct Stamp: Codable, Sendable, Equatable {
        public let kind: Stage
        /// Monotonic uptime, nanoseconds.
        public let nanoseconds: UInt64
        /// The edit revision the entry concerns — the value identity of a frame.
        public let revision: Int
        /// Frames only: draft or settle, and the delivered long edge.
        public var draft: Bool?
        public var longEdge: Int?
        /// Frames only: render handed over to frame landed, as its requester saw it.
        public var renderMilliseconds: Double?
        /// Frames only: the part of that spent inside the renderer. The difference is
        /// the two hops and any wait for the requester's thread.
        public var laneMilliseconds: Double?
        /// Overlays only: which one.
        public var name: String?
        /// Turns only.
        public var mainMilliseconds: Double?

        public init(kind: Stage, nanoseconds: UInt64, revision: Int, draft: Bool? = nil,
                    longEdge: Int? = nil, renderMilliseconds: Double? = nil,
                    laneMilliseconds: Double? = nil, name: String? = nil,
                    mainMilliseconds: Double? = nil) {
            self.kind = kind
            self.nanoseconds = nanoseconds
            self.revision = revision
            self.draft = draft
            self.longEdge = longEdge
            self.renderMilliseconds = renderMilliseconds
            self.laneMilliseconds = laneMilliseconds
            self.name = name
            self.mainMilliseconds = mainMilliseconds
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
        /// From an input to the viewer asking for its draft: main-thread time alone.
        public var medianInputToRequestMilliseconds: Double?
        public var maxInputToRequestMilliseconds: Double?
        /// Draft frames: as the requester saw them, and inside the renderer.
        public var medianDraftRenderMilliseconds: Double?
        public var medianDraftLaneMilliseconds: Double?
        /// Main-thread time per input, to the end of its run-loop turn: the handler,
        /// every view body the edit invalidated, layout and the commit.
        public var medianInputTurnMilliseconds: Double?
        public var maxInputTurnMilliseconds: Double?
        /// Each overlay by name, measured as frames are.
        public var overlays: [String: Following] = [:]
        public var lastInputRevision: Int?
        public var lastFrameRevision: Int?

        /// The final value reached the screen.
        public var lastInputWasRendered: Bool {
            guard let input = lastInputRevision else { return true }
            guard let frame = lastFrameRevision else { return false }
            return frame >= input
        }
    }

    /// How well one stream of pictures followed the input.
    public struct Following: Codable, Sendable, Equatable {
        public var updates = 0
        public var updatesDuringInput = 0
        public var maxGapMilliseconds: Double?
        public var maxInputToUpdateMilliseconds: Double?
        public var lastInputToUpdateMilliseconds: Double?
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
        let drafts = frames.filter { $0.draft == true }
        out.medianDraftRenderMilliseconds = Self.median(drafts.compactMap(\.renderMilliseconds))
        out.medianDraftLaneMilliseconds = Self.median(drafts.compactMap(\.laneMilliseconds))
        let turns = entries.compactMap { $0.kind == .turn ? $0.mainMilliseconds : nil }
        out.medianInputTurnMilliseconds = Self.median(turns)
        out.maxInputTurnMilliseconds = turns.max()

        let shown = Self.following(frames, inputs: inputs)
        out.framesDuringInput = shown.updatesDuringInput
        out.maxFrameGapMilliseconds = shown.maxGapMilliseconds
        out.maxInputToFrameMilliseconds = shown.maxInputToUpdateMilliseconds
        out.lastInputToFrameMilliseconds = shown.lastInputToUpdateMilliseconds
        let overlays = entries.filter { $0.kind == .overlay }
        for name in Set(overlays.compactMap(\.name)) {
            out.overlays[name] = Self.following(overlays.filter { $0.name == name },
                                                inputs: inputs)
        }
        guard let first = inputs.first, let last = inputs.last else { return out }
        out.inputSpanMilliseconds = Self.milliseconds(first.nanoseconds, last.nanoseconds)

        let asking: [Double] = entries.compactMap { request in
            guard request.kind == .request,
                  let input = Self.lastInput(atOrBefore: request.revision, in: inputs),
                  input.revision == request.revision,
                  request.nanoseconds >= input.nanoseconds else { return nil }
            return Self.milliseconds(input.nanoseconds, request.nanoseconds)
        }
        out.medianInputToRequestMilliseconds = Self.median(asking)
        out.maxInputToRequestMilliseconds = asking.max()
        return out
    }

    private static func milliseconds(_ from: UInt64, _ to: UInt64) -> Double {
        to >= from ? Double(to - from) / 1e6 : 0
    }

    /// `marks` in time order: frames, or one overlay's updates.
    private static func following(_ marks: [Stamp], inputs: [Stamp]) -> Following {
        var out = Following()
        out.updates = marks.count
        guard let first = inputs.first?.nanoseconds,
              let last = inputs.last?.nanoseconds else { return out }
        out.updatesDuringInput = marks.filter {
            $0.nanoseconds > first && $0.nanoseconds <= last
        }.count

        // The gap walk ends on the first update at or after the last input: a drag that
        // delivered nothing until release then reads as one gap the length of the drag.
        if let closing = marks.first(where: { $0.nanoseconds >= last })?.nanoseconds {
            var previous = first
            var longest: Double = 0
            for mark in marks where mark.nanoseconds > first
                && mark.nanoseconds <= closing {
                longest = Swift.max(longest, milliseconds(previous, mark.nanoseconds))
                previous = mark.nanoseconds
            }
            out.maxGapMilliseconds = longest
        }

        // Only the first update to show a newer revision counts: a settle of a revision
        // already on screen is sharpness arriving, not the value arriving.
        let lastRevision = inputs.last?.revision
        var newestShown = Int.min
        for mark in marks where mark.revision > newestShown {
            newestShown = mark.revision
            guard let input = lastInput(atOrBefore: mark.revision, in: inputs),
                  mark.nanoseconds >= input.nanoseconds else { continue }
            let took = milliseconds(input.nanoseconds, mark.nanoseconds)
            out.maxInputToUpdateMilliseconds =
                Swift.max(out.maxInputToUpdateMilliseconds ?? 0, took)
            if input.revision == lastRevision { out.lastInputToUpdateMilliseconds = took }
        }
        return out
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
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
