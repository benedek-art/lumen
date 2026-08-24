// LatencyHUD.swift
// The numbers behind "the sliders feel slow" (docs/23 M1b).
//
// Nine responsiveness fixes have landed across three rounds of this project and not
// one was ever verified by a measurement on the machine that matters. This is the
// instrument that ends that: with the HUD on (Debug menu), every draft and settle
// stamps its wall time — measured around the await, so actor queueing is included,
// because queueing is what a hand feels — and every pixel-touching edit stamps the
// input side, so the headline number is input→draft-on-screen, the latency contract's
// own definition (docs/12 §12.2).
//
// Off by default and free when off: the writes are gated on `enabled`, so no
// @Published fires per frame for a HUD nobody is looking at.

#if os(macOS)

import Foundation
import SwiftUI

@MainActor
final class LatencyHUD: ObservableObject {

    static let shared = LatencyHUD()
    private init() {}

    /// Gates every write. Plain var: toggling rides AppState's own publish.
    var enabled = false

    @Published private(set) var inputToDraftMs: Double?
    @Published private(set) var draftMs: Double?
    @Published private(set) var draftLongEdge: Int?
    @Published private(set) var settleMs: Double?
    @Published private(set) var settleLongEdge: Int?

    private var lastInputAt: UInt64?

    /// A pixel-touching edit happened. The next draft that lands closes the loop.
    func noteInput() {
        guard enabled else { return }
        lastInputAt = DispatchTime.now().uptimeNanoseconds
    }

    func noteDraft(milliseconds: Double, longEdge: Int) {
        guard enabled else { return }
        draftMs = milliseconds
        draftLongEdge = longEdge
        if let input = lastInputAt {
            inputToDraftMs = Double(DispatchTime.now().uptimeNanoseconds - input) / 1e6
            lastInputAt = nil  // one edit, one closure of the loop
        }
    }

    func noteSettle(milliseconds: Double, longEdge: Int) {
        guard enabled else { return }
        settleMs = milliseconds
        settleLongEdge = longEdge
    }
}

/// The overlay itself: three monospaced lines in the loupe's corner. Numbers, not
/// judgement — the budgets live in docs/12 and the owner's eye.
struct LatencyHUDView: View {
    @ObservedObject private var hud = LatencyHUD.shared

    private func line(_ label: String, _ ms: Double?, _ edge: Int?) -> String {
        guard let ms else { return "\(label)      —" }
        let size = edge.map { " @\($0)" } ?? ""
        return String(format: "%@ %6.1f ms%@", label, ms, size)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(line("input→draft", hud.inputToDraftMs, nil))
            Text(line("draft      ", hud.draftMs, hud.draftLongEdge))
            Text(line("settle     ", hud.settleMs, hud.settleLongEdge))
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(Lumen.primaryText)
        .padding(6)
        .background(Color.black.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .allowsHitTesting(false)
    }
}

#endif
