import AppKit
import Foundation
import LumenCore
@testable import LumenApp

@main struct AppProbe {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: "/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/audit/app-probe-\(UUID().uuidString)")
        let photos = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories:true)
        let photo = photos.appendingPathComponent("test.png")
        try FileManager.default.copyItem(at: URL(fileURLWithPath:"/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/audit/ui/photos/Audit-chart.png"),to:photo)
        let state=AppState(catalogDirectory:{root.appendingPathComponent("catalog")},previewDirectory:{root.appendingPathComponent("previews")})
        state.openFolder(photos)
        for _ in 0..<1000 {
            if !state.isScanning { break }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        guard let item=state.allPhotos.first else { fatalError("No photo scanned") }
        state.select(item)
        let original=state.recipe(for:item).develop.tone.exposure
        state.sliderGesture(active:true)
        state.updateRecipe(coalescingKey:"tone.exposure") { $0.develop.tone.exposure=original+1 }
        let closedFirst = CommandLine.arguments.contains("closed")
        if closedFirst { state.sliderGesture(active:false) }
        state.undo()
        print("UNDO closedFirst=\(closedFirst) memory=\(state.recipe(for:item).develop.tone.exposure) gestureActive=\(state.sliderGestureActive)")
        state.sliderGesture(active:false)
        state.prepareToQuit()
        print("CATALOG_PATH \(root.appendingPathComponent("catalog/lumen.db").path)")
        print("SIDECAR_PATH \(photos.appendingPathComponent("test.png.xmp").path)")
        print("FINAL_MEMORY \(state.recipe(for:item).develop.tone.exposure)")
        let widths = [-2.0,-4,-6,-8,-10]
        var width=380.0
        for delta in widths { width=min(max(width-delta,320),520) }
        print("COLUMN_RESIZE five events to -10pt:actualWidth=\(width) expected=390")
        var width2=380.0
        for delta in stride(from:-1.0,through:-10.0,by:-1.0) { width2=min(max(width2-delta,320),520) }
        print("COLUMN_RESIZE ten events to -10pt:actualWidth=\(width2) expected=390")
    }
}
