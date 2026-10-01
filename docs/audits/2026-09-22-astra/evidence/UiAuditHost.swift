import AppKit
import SwiftUI
import Foundation
import LumenCore
@testable import LumenApp

// Audit-only host. Production views and state objects; isolated catalog, defaults,
// cache and synthetic input. No updater, no production library, no source edits.
private let auditRoot = URL(fileURLWithPath: "/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/work/audit/ui")

@MainActor func saveSnapshot() {
    guard let window = NSApp.keyWindow, let view = window.contentView,
          let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
    view.cacheDisplay(in:view.bounds,to:bitmap)
    let directory=URL(fileURLWithPath:"/Users/AUDIT_USER/Documents/Codex/2026-09-22/ca/outputs/screenshots")
    try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let name="lumen-\(PanelLayout.shared.layout.workspace.rawValue)-\(Int(Date().timeIntervalSince1970)).png"
    try? bitmap.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent(name))
}

@MainActor
func makeState() -> AppState {
    let fm = FileManager.default
    for name in ["catalog", "previews", "photos"] {
        try! fm.createDirectory(at: auditRoot.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let photo = auditRoot.appendingPathComponent("photos/Audit-chart.png")
    if !fm.fileExists(atPath: photo.path) {
        let width = 1536, height = 1024
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
            pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4,
            bitsPerPixel: 32)!
        let data = bitmap.bitmapData!
        let swatches: [(Double, Double, Double)] = [(0.72,0.46,0.32),(0.16,0.45,0.72),
            (0.23,0.51,0.18),(0.82,0.16,0.12),(0.90,0.73,0.12),(0.59,0.18,0.62)]
        for y in 0..<height { for x in 0..<width {
            let i = (y*width+x)*4
            let ramp = Double(x)/Double(width-1)
            var c: (Double,Double,Double)
            if y < height/3 { c = (ramp,ramp,ramp) }
            else if y < 2*height/3 { c = swatches[min(5,x/(width/6))] }
            else { let v = ((x/16+y/16)%2==0 ? 0.2:0.8); c=(v,v,v) }
            data[i]=UInt8(c.0*255); data[i+1]=UInt8(c.1*255); data[i+2]=UInt8(c.2*255); data[i+3]=255
        }}
        try! bitmap.representation(using:.png,properties:[:])!.write(to:photo)
    }
    // Keep SQLite outside the host's FileProvider-backed Documents directory.
    let databaseRoot = URL(fileURLWithPath:"/private/tmp/lumen-ui-audit.TnqCgv")
    let state = AppState(catalogDirectory: { databaseRoot.appendingPathComponent("catalog") },
                         previewDirectory: { databaseRoot.appendingPathComponent("previews") })
    state.openFolder(auditRoot.appendingPathComponent("photos"))
    return state
}

@main
struct LumenAuditHost: App {
    @StateObject private var state = makeState()
    var body: some Scene {
        WindowGroup("Lumen — isolated audit") {
            ContentView()
                .environmentObject(state)
                .environmentObject(state.commands)
                .environmentObject(state.edits)
                .preferredColorScheme(.dark)
                .frame(minWidth:1000,minHeight:700)
        }
        .commands {
            CommandMenu("Audit") {
                Button("Undo") { state.undo() }.keyboardShortcut("z")
                Button("Redo") { state.redo() }.keyboardShortcut("z",modifiers:[.command,.shift])
                Button("Develop") { PanelLayout.shared.select(.develop) }
                Button("Grade") { PanelLayout.shared.select(.grade) }
                Button("Deliver") { PanelLayout.shared.select(.deliver) }
                Button("Toggle latency HUD") { state.showLatencyHUD.toggle() }
                Button("Save audit screenshot") { saveSnapshot() }.keyboardShortcut("s",modifiers:[.command,.shift])
            }
        }
    }
}
