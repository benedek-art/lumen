// DevelopPanel.swift
// Phase-1 develop panel: the walking-skeleton slider set (docs/16 Phase 1) bound to
// the real Recipe model — exposure (EV), WB Kelvin/tint, highlights/shadows, NR
// toggle — plus JPEG export. Slider ranges are the docs/04 contract; the full
// slider-contract ergonomics (D45) arrive with the real panel system in Phase 3.

#if os(macOS)

import AppKit
import LumenCore
import LumenPipeline
import SwiftUI

struct DevelopPanel: View {
    @EnvironmentObject var state: AppState
    let photo: PhotoItem

    @State private var exportMessage: String?

    var body: some View {
        let recipe = state.recipe(for: photo)

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(photo.filename)
                    .font(.headline)
                    .lineLimit(1)

                Group {
                    slider("Exposure", value: recipe.develop.tone.exposure,
                           range: -5...5, format: "%+.2f EV") { v, r in
                        r.develop.tone.exposure = v
                    }
                    slider("Temp", value: recipe.develop.raw.temp ?? 5500,
                           range: 2000...50000, format: "%.0f K") { v, r in
                        r.develop.raw.temp = v
                    }
                    slider("Tint", value: recipe.develop.raw.tint ?? 0,
                           range: -150...150, format: "%+.0f") { v, r in
                        r.develop.raw.tint = v
                    }
                    slider("Highlights", value: recipe.develop.tone.highlights,
                           range: -100...100, format: "%+.0f") { v, r in
                        r.develop.tone.highlights = v
                    }
                    slider("Shadows", value: recipe.develop.tone.shadows,
                           range: -100...100, format: "%+.0f") { v, r in
                        r.develop.tone.shadows = v
                    }
                }

                Toggle("Noise reduction", isOn: Binding(
                    get: { state.recipe(for: photo).develop.denoise.mode != .off },
                    set: { on in
                        state.updateRecipe(for: photo) {
                            $0.develop.denoise.mode = on ? .classic : .off
                        }
                    }))

                Button("Reset") {
                    state.updateRecipe(for: photo) { $0 = Recipe() }
                }

                Divider()

                Button {
                    exportCurrent()
                } label: {
                    Label("Export JPEG…", systemImage: "square.and.arrow.up")
                }
                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
        }
    }

    private func slider(_ label: String, value: Double,
                        range: ClosedRange<Double>, format: String,
                        apply: @escaping (Double, inout Recipe) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: format, value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { value },
                set: { v in state.updateRecipe(for: photo) { apply(v, &$0) } }
            ), in: range)
        }
    }

    private func exportCurrent() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            photo.id.deletingPathExtension().lastPathComponent + ".jpg"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let recipe = state.recipe(for: photo)
        let url = photo.id
        exportMessage = "Exporting…"
        Task {
            let result = await RenderCoordinator.shared.export(
                url: url, recipe: recipe, to: destination,
                settings: ExportSettings(jpegQuality: 0.9, maxLongEdge: nil))
            await MainActor.run {
                switch result {
                case .success: exportMessage = "Exported \(destination.lastPathComponent)"
                case .failure(let error): exportMessage = "Export failed: \(error)"
                }
            }
        }
    }
}

#endif
