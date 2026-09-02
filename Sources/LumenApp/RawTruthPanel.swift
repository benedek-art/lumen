// RawTruthPanel.swift
// The `⇧H` panel: per-channel clipping at cull time (docs/10 §10.5, README goal 3).
//
// This is the surface half of the FastRawViewer pillar. The other half — the
// measurement, the binning, the clipping arithmetic, the verdict and the cache — is
// LumenCore, where it is tested; this file draws what `RawTruth.Readout` already
// decided and computes nothing of its own. That split is deliberate: everything a test
// on this machine could check about the numbers is on the other side of it.
//
// WHAT THE PANEL IS ALLOWED TO SAY, which is the whole reason it is written this way.
// docs/10 §10.5 specifies a SENSOR histogram: undemosaiced CFA sites against the
// saturation level in the file's metadata. Lumen has no raw reader and cannot produce
// that. What it can produce is the decoded scene-linear frame — Apple's demosaic at
// Lumen's flat settings, before every Lumen stage and before the display transform —
// and that is what these numbers are. So the header prints the provenance the
// measurement carries rather than the word "raw", the qualifications underneath state
// the remaining gap in a sentence, and the header cannot be edited to claim more
// without `RawTruth.Provenance` changing to match. A control that overstates where its
// numbers came from is worse than no control.
//
// The panel is available wherever culling happens — the grid included — because a
// keep/kill decision made in the contact sheet is the decision this instrument exists
// to inform. The develop column is loupe-and-compare only, which is why this is an
// overlay on the centre pane rather than another section of that column.

#if os(macOS)

import Foundation
import LumenCore
import SwiftUI

struct RawTruthPanel: View {

    @EnvironmentObject var state: AppState

    private static let width: CGFloat = 268

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider().overlay(Lumen.separator)
            if let stats = state.rawTruth {
                content(RawTruth.readout(stats, plan: state.rawTruthPlan))
            } else if state.rawTruthMeasuring {
                Text("Measuring…")
                    .font(.system(size: 11))
                    .foregroundStyle(Lumen.secondaryText)
            } else {
                Text(state.primarySelection == nil
                     ? "No photo selected."
                     : "This photograph could not be decoded, so there is nothing to "
                        + "measure.")
                    .font(.system(size: 11))
                    .foregroundStyle(Lumen.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(width: Self.width, alignment: .leading)
        .background(Lumen.panelBackground.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: Lumen.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Lumen.radiusCard, style: .continuous)
            .stroke(Lumen.separator, lineWidth: 1))
        .foregroundStyle(Lumen.primaryText)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Clipping")
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Button {
                state.showRawTruth = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Lumen.secondaryText)
            .help("Close (⇧H)")
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ readout: RawTruth.Readout) -> some View {
        // The provenance, first and unmissable. It is the answer to "these numbers are
        // of what?", and it is printed from the measurement rather than from a literal
        // in this file so it cannot describe a reading the row does not carry.
        Text(readout.provenanceLabel.uppercased())
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Lumen.accent)

        Text(readout.verdict.summary)
            .font(.system(size: 12, weight: .medium))
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 2) {
            ForEach(readout.channels, id: \.name) { line in
                row(line)
            }
            Divider().overlay(Lumen.separator).padding(.vertical, 2)
            row(readout.luma)
        }

        Text(readout.headline)
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(Lumen.secondaryText)
            .textSelection(.enabled)

        Text(readout.ceilingNote)
            .font(.lumenCaption)
            .foregroundStyle(Lumen.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

        // Every qualification the readout produced, printed. Not a disclosure triangle:
        // the sentence that says these are not the sensor's own values is the sentence
        // most worth reading, and a collapsed one is a sentence nobody reads.
        ForEach(readout.qualifications, id: \.self) { note in
            Text(note)
                .font(.lumenCaption)
                .foregroundStyle(Lumen.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }

        Text("Hold [ to lift the shadows, ] to inspect the highlights. Neither writes "
             + "an edit.")
            .font(.lumenCaption)
            .foregroundStyle(Lumen.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One channel: name, the bar, the number, and the near-clipped figure beside it.
    private func row(_ line: RawTruth.Line) -> some View {
        HStack(spacing: 6) {
            Text(line.name)
                .font(.system(size: 10, weight: .medium).monospaced())
                .frame(width: 16, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Lumen.swatchRadius(6))
                        .fill(Lumen.trackColor)
                    RoundedRectangle(cornerRadius: Lumen.swatchRadius(6))
                        .fill(line.isClipped ? Lumen.accent : Lumen.fillColor)
                        .frame(width: geometry.size.width * Self.barFraction(line))
                }
            }
            .frame(height: 6)
            Text(RawTruth.percent(line.clippedPercent))
                .font(.system(size: 10).monospacedDigit())
                .frame(width: 46, alignment: .trailing)
            Text(RawTruth.percent(line.nearClippedPercent))
                .font(.lumenCaptionNumeric)
                .foregroundStyle(Lumen.secondaryText)
                .frame(width: 44, alignment: .trailing)
                .help("Within 0.25 EV of the ceiling")
        }
        .frame(height: 14)
    }

    /// The bar is a square-root scale, stated because a linear one would draw 2.1% as
    /// two pixels and a photographer would read "nothing is clipped" off a bar that
    /// disagrees with the number printed next to it. The number is the measurement; the
    /// bar is a glance.
    private static func barFraction(_ line: RawTruth.Line) -> Double {
        guard line.clippedPercent.isFinite, line.clippedPercent > 0 else { return 0 }
        let fraction = min(max(line.clippedPercent / 100, 0), 1)
        return fraction.squareRoot()
    }
}

#endif
