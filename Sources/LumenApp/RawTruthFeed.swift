// RawTruthFeed.swift
// The caller `RawStatistics` never had.
//
// The binning, the encode and the decode have been in LumenCore since the first scopes
// commit, and their only callers were two blob round-trip tests — tests that stayed
// green whether or not a photographer ever saw a number. This file is the path from a
// selected photograph to the panel: cache first, decode only when the cache misses,
// write the result back so the second look is free.
//
// Three rules, and each one is a defect that would otherwise be invisible:
//
//   · NOTHING IS MEASURED UNTIL SOMEBODY ASKS. `⇧H` is off by default and a closed
//     panel schedules nothing. docs/10 §10.5 also describes a background sweep at
//     background QoS after the scan; that queue is `photosMissingRawStatistics` in the
//     store and it has no driver yet, which is stated in docs/21 rather than implied by
//     a panel that fills in on its own.
//   · THE MEASUREMENT NEVER CANCELS A RENDER. It goes through the coordinator's
//     non-ticketed path, so it cannot supersede the frame the viewer is waiting on.
//   · A STALE RESULT NEVER LANDS. Generation-checked on both sides of the await, the
//     same discipline `scheduleScopeRefresh` uses, because paging fast through a folder
//     otherwise puts the previous photo's clipping under this photo's name — and the
//     numbers look completely plausible.
//
// What is cached is keyed on the FILE, not on the edit, and that is correct precisely
// because of what is being measured: the decode runs before every Lumen stage, so no
// slider in the app can change these numbers. Raw pixels never change (docs/15 G27),
// which is why the row has no recipe fingerprint in it.

#if os(macOS)

import Foundation
import LumenCore
import SwiftUI

extension AppState {

    /// Fill the `⇧H` panel for the current selection.
    func scheduleRawTruthRefresh() {
        guard showRawTruth else { return }
        guard let photo = primarySelection else {
            rawTruth = nil
            rawTruthPlan = nil
            rawTruthMeasuring = false
            return
        }

        rawTruthGeneration &+= 1
        let generation = rawTruthGeneration
        let url = photo.id
        let photoID = photo.catalogID
        let recipe = recipe(for: photo)
        let coordinator = renderCoordinator
        let catalog = self.catalog

        // Cleared rather than left showing: the previous photo's numbers under this
        // photo's filename is the worst of the three states this can be in, because it
        // is the one that looks like an answer. The plan goes with them — a caption
        // describing how the LAST frame was sampled, printed under this frame's
        // numbers, is the same failure one line smaller.
        rawTruth = nil
        rawTruthPlan = nil
        rawTruthMeasuring = true

        // Which reading this file can produce, decided from the file rather than from
        // the row, so the cache lookup asks for the same thing the decoder will store.
        // Ask for `.sceneLinearDecode` on a JPEG and every open recomputes a row that
        // is already there and can never match.
        let expected: RawStatistics.Provenance =
            RawTruth.provenance(isRenderedFile: PhotoFormats.isRendered(url))

        Task { [weak self] in
            if let catalog, let photoID,
               let cached = await catalog.rawStatistics(photoID: photoID,
                                                        provenance: expected) {
                guard let self, self.rawTruthGeneration == generation else { return }
                self.rawTruth = cached
                self.rawTruthMeasuring = false
                return
            }
            guard let self, self.rawTruthGeneration == generation else { return }

            let measured = await coordinator.clippingStatistics(url: url, recipe: recipe)
            guard self.rawTruthGeneration == generation else { return }
            self.rawTruthMeasuring = false
            guard let measured else { return }
            self.rawTruth = measured.0
            self.rawTruthPlan = measured.1
            if let catalog, let photoID {
                catalog.recordRawStatistics(measured.0, photoID: photoID)
            }
        }
    }
}

#endif
