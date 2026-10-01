// BurstGrouping.swift
// Which frames of a shoot are one burst, by capture time (docs/10 §10.2 Stacks).
//
// The spec's auto-stack rule is "capture gap ≤ 2 s AND FeaturePrint distance below
// threshold". This is the first half only. The feature-print half needs a Vision pass
// this build does not run, so the grouping is offered as an explicit command rather
// than switched on by default: a 2-second rule alone will put a fast walk-around of
// different compositions in one stack, and a photographer should choose to try that.

import Foundation

public struct BurstFrame: Equatable, Sendable {
    public var id: Int64
    /// Capture time in microseconds since the epoch, nil when the EXIF had none.
    public var captureMicros: Int64?
    /// The body that took it — serial number where known, else the model. Two cameras
    /// firing in the same second are two bursts, not one.
    public var body: String?

    public init(id: Int64, captureMicros: Int64?, body: String?) {
        self.id = id
        self.captureMicros = captureMicros
        self.body = body
    }

    /// From the catalog's two columns: whole seconds plus `capture_subsec`, which is
    /// microseconds (see `PhotoMetadata.captureSubsec`).
    public init(id: Int64, captureAt: Int64?, captureSubsec: Int?, body: String?) {
        self.init(id: id,
                  captureMicros: captureAt.map { $0 * 1_000_000 + Int64(captureSubsec ?? 0) },
                  body: body)
    }
}

public enum BurstGrouping {

    public static let defaultMaxGapSeconds: Double = 2.0

    /// Bursts of two or more frames, each in capture order, the groups ordered by
    /// their first frame. A frame joins the burst before it when it was taken by the
    /// same body no more than `maxGap` seconds after the previous frame of that body —
    /// a CHAIN, so a 10-second burst at 10 fps is one stack, as it is on the card.
    /// Frames with no capture time are never grouped: there is nothing to group by.
    public static func groups(_ frames: [BurstFrame],
                              maxGap: Double = defaultMaxGapSeconds) -> [[Int64]] {
        let limit = Int64((maxGap * 1_000_000).rounded())
        var byBody: [String: [BurstFrame]] = [:]
        for frame in frames where frame.captureMicros != nil {
            byBody[frame.body ?? "", default: []].append(frame)
        }
        var out: [[Int64]] = []
        for (_, bodyFrames) in byBody {
            let ordered = bodyFrames.sorted {
                ($0.captureMicros!, $0.id) < ($1.captureMicros!, $1.id)
            }
            var current: [BurstFrame] = []
            for frame in ordered {
                if let last = current.last, frame.captureMicros! - last.captureMicros! > limit {
                    if current.count > 1 { out.append(current.map(\.id)) }
                    current = []
                }
                current.append(frame)
            }
            if current.count > 1 { out.append(current.map(\.id)) }
        }
        // Deterministic whatever the dictionary's order: by first frame's time, then id.
        let time = Dictionary(frames.map { ($0.id, $0.captureMicros ?? 0) },
                              uniquingKeysWith: { first, _ in first })
        return out.sorted { (time[$0[0]]!, $0[0]) < (time[$1[0]]!, $1[0]) }
    }
}
