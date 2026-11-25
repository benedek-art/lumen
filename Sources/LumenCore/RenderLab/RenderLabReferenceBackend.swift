// RenderLabReferenceBackend.swift
// Renders lab jobs through ReferenceRenderer: charts, and real photographs from decoded
// plates. Reference-path output, not what the app ships; see renderlab/README.md for the
// stages it does not cover.

import Foundation

public final class RenderLabReferenceBackend: RenderLabBackend {
    public let kind = "reference"
    public let lutSize: Int
    public let maxLongEdge: Int
    /// Loads a plate for a photo id ("6929", "6929-center"); nil when plates are absent.
    public let plateLoader: ((String) throws -> RenderLabPlate)?
    private var charts: [String: RenderLabCharts.Chart] = [:]
    private var plates: [String: RenderLabPlate] = [:]

    public init(lutSize: Int, maxLongEdge: Int,
                plateLoader: ((String) throws -> RenderLabPlate)? = nil) {
        self.lutSize = lutSize
        self.maxLongEdge = maxLongEdge
        self.plateLoader = plateLoader
    }

    /// Plates from a directory of `<id>.plate` files.
    public static func directoryLoader(_ dir: URL) -> (String) throws -> RenderLabPlate {
        { id in
            let url = dir.appendingPathComponent(id + ".plate")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw RenderLabError.missingPhoto("no plate \(url.path); fetch plates (renderlab/README.md)")
            }
            return try RenderLabPlate(data: Data(contentsOf: url))
        }
    }

    public func resolve(path: String) -> String? { "reference" }

    static func chartName(_ photo: String) -> String? {
        photo.hasPrefix("chart:") ? String(photo.dropFirst(6)) : nil
    }

    func plate(_ photo: String) throws -> RenderLabPlate {
        if let p = plates[photo] { return p }
        guard let plateLoader else {
            throw RenderLabError.missingPhoto("\(photo): no plates configured (LUMEN_RENDERLAB_PLATES)")
        }
        let p = try plateLoader(photo)
        plates[photo] = p
        return p
    }

    func chart(_ name: String, _ longEdge: Int) throws -> RenderLabCharts.Chart {
        let key = "\(name)@\(longEdge)"
        if let c = charts[key] { return c }
        let c = try RenderLabCharts.make(name, longEdge: longEdge)
        charts[key] = c
        return c
    }

    public func baseRecipe(photo: String, base: String) throws -> Recipe {
        if base == "blank" { return Recipe() }
        if Self.chartName(photo) != nil { return Recipe.asImported(from: Recipe.SourceFile()) }
        let p = try plate(photo)
        return Recipe.asImported(from: Recipe.SourceFile(isRendered: false,
                                                         iso: p.header.iso.map { Int($0) }))
    }

    public func patches(photo: String) -> [RenderLabPatch]? {
        guard let name = Self.chartName(photo) else { return nil }
        return try? RenderLabCharts.make(name, longEdge: 48).patches
    }

    public func render(photo: String, recipe: Recipe, path: String, longEdge: Int,
                       draftLongEdge: Int?, crop: [Double]?) throws -> RenderLabRender {
        if crop != nil {
            throw RenderLabError.render("the reference path has no geometry stage; for 1:1 work "
                + "use the native crop plates (photo ids like 6929-crop40-40)")
        }
        let edge = Swift.min(longEdge, maxLongEdge)
        let started = Date()
        let frame: ImageBuffer
        var kelvin = 5500.0, tint = 0.0, iso: Double?
        var noiseScale = 1.0
        var note = "reference path (ReferenceRenderer, LUT \(lutSize)); no geometry, no GPU-only stages"
        if let name = Self.chartName(photo) {
            frame = try chart(name, edge).image
        } else {
            let p = try plate(photo)
            frame = RenderLabPlate.downscale(p.image, longEdge: edge)
            kelvin = p.header.asShotTemperature
            tint = p.header.asShotTint
            iso = p.header.iso
            let s = p.header.scale * Double(Swift.max(frame.width, frame.height))
                / Double(Swift.max(p.image.width, p.image.height))
            noiseScale = s * s
            note += "; plate \(p.header.id) at decode scale \(String(format: "%.3f", s))"
        }
        if edge < longEdge { note += "; long edge capped at \(edge)" }
        let plan = RenderPlan(recipe: recipe, asShotKelvin: kelvin, asShotTint: tint,
                              lutSize: lutSize, captureISO: iso)
        var staged = frame
        if !plan.denoiseIsIdentity {
            staged = plan.classicalDenoise.scaled(noiseScale: noiseScale).apply(frame)
        }
        let planned = Date()
        let rendered = ReferenceRenderer.render(staged, plan: plan)
        let image = RenderLabImage(displayLinear: rendered)
        let done = Date()
        return RenderLabRender(
            image: image,
            timings: ["planAndDenoise": planned.timeIntervalSince(started) * 1000,
                      "render": done.timeIntervalSince(planned) * 1000,
                      "total": done.timeIntervalSince(started) * 1000],
            note: note)
    }

    public func encodePNG(_ image: RenderLabImage) throws -> Data {
        RenderLabSheet.encodePNG(image)
    }
}
