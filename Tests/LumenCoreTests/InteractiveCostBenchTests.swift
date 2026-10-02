// The CPU half of the paths a photographer feels, priced piece by piece on Linux.
//
// `PlanCostProbeTests` prices a whole `RenderPlan`; `SpeedBenchTests` prices a few
// recipes end to end. Neither says WHERE a plan's milliseconds go, which is the
// question a fix has to start from. This bench decomposes one slider tick into the
// objects `RenderPlan.init` builds and the keys it spells, prices the three cold
// table bakes beside them, prices the recipe fingerprint the settle frame and the
// catalog write pay, and prices the grid's catalog queries on a 20 000-photo
// synthetic roll.
//
// Gated behind LUMEN_BENCH like `SpeedBenchTests`, so CI never pays for it. Run it in
// a release build (`-c release -Xswiftc -enable-testing`) — a debug build inflates the
// arithmetic roughly tenfold and moves the shares. Every row is a MEDIAN over repeats;
// the absolute numbers belong to whatever machine ran them, read the shares.
import XCTest
@testable import LumenCore

final class InteractiveCostBenchTests: XCTestCase {

    private var enabled: Bool {
        guard let raw = ProcessInfo.processInfo.environment["LUMEN_BENCH"] else { return false }
        return !["", "0", "false", "no", "off"].contains(
            raw.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Median wall time of `body` in milliseconds, after one warm-up call.
    @discardableResult
    private func median(_ name: String, repeats: Int = 41, _ body: () -> Void) -> Double {
        body()
        var samples: [Double] = []
        samples.reserveCapacity(repeats)
        for _ in 0..<repeats {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        print(String(format: "BENCH %-58@ p50 %9.4f ms  min %9.4f  max %9.4f",
                     name as NSString, p50, samples.first ?? 0, samples.last ?? 0))
        return p50
    }

    /// The working recipe: tone, colour, a grade, a curve, detail and two masks — an
    /// edited photograph, not a default one, so no identity short-circuit prices a
    /// plan nobody builds.
    private func edited() -> Recipe {
        var r = Recipe()
        r.develop.tone.exposure = 0.4
        r.develop.tone.contrast = 20
        r.develop.tone.highlights = -40
        r.develop.tone.shadows = 25
        r.develop.tone.whites = 10
        r.develop.raw.temp = 5200
        r.develop.color.vibrance = 10
        r.develop.color.saturation = 5
        r.develop.curve.parametric.lights = 15
        r.develop.detail.clarity = 25
        r.develop.detail.sharpen.amount = 60
        r.develop.denoise.mode = .classic
        r.look.wheels.high.sat = 20
        r.look.wheels.high.hue = 40
        r.look.vignette = -0.5
        for i in 0..<2 {
            var m = Mask(id: "m\(i)", name: "Mask \(i)")
            m.adjust.exposure = 0.3
            r.masks.append(m)
        }
        return r
    }

    func testDecomposeOneSliderTick() throws {
        try XCTSkipUnless(enabled, "set LUMEN_BENCH=1")
        #if DEBUG
        print("BENCH build: DEBUG — read shares only, and prefer a release run")
        #else
        print("BENCH build: RELEASE")
        #endif
        let recipe = edited()
        let develop = recipe.develop
        let look = recipe.look
        PlanTableCache.clear()
        PlanTableCache.setRenderIdentity("bench")
        defer { PlanTableCache.setRenderIdentity("") }

        // ---- whole plans: a warm cache, the shape of a drag of an untabled control
        _ = RenderPlan(recipe: recipe)
        var t = 0.0
        median("plan: texture tick (all tables hit)") {
            t += 1e-3
            var r = recipe
            r.develop.detail.texture = t
            _ = RenderPlan(recipe: r, allowStaleTables: true)
        }
        median("plan: exposure tick, draft (tone cube rebakes)") {
            t += 1e-3
            var r = recipe
            r.develop.tone.exposure = t
            _ = RenderPlan(recipe: r, allowStaleTables: true)
        }

        // ---- the pieces RenderPlan.init builds, in its order
        median("piece: ToneEngine(tone:zones:)") {
            _ = ToneEngine(tone: develop.tone, zones: develop.zones)
        }
        let tone = ToneEngine(tone: develop.tone, zones: develop.zones)
        median("piece: ToneEngine.bakeGainLUT()") { _ = tone.bakeGainLUT() }
        let gain = tone.bakeGainLUT()
        median("piece: tone cube bake 32^3") {
            var peak = 1.0
            for v in gain.samples { peak = Swift.max(peak, v) }
            _ = LUT3D(size: 32) { e in RGB(gray: gain.evaluate(e.r) / peak) }
        }
        median("piece: ColorEngine(...)") {
            _ = ColorEngine(mixer: develop.mixer, pointColors: develop.pointColors,
                            color: develop.color, primaries: look.primaries,
                            bw: look.bw, bandMeanHues: nil)
        }
        median("piece: GradeEngine(...)") {
            _ = GradeEngine(wheels: look.wheels, printerLights: look.printerLights,
                            whiteAnchorEV: tone.whiteAnchorEV,
                            blackAnchorEV: tone.blackAnchorEV)
        }
        median("piece: DisplayTransform.forRecipe") {
            _ = DisplayTransform.forRecipe(recipe, displayWhiteTarget: nil, space: .rec2020)
        }
        median("piece: CurveStack(curve)") { _ = CurveStack(develop.curve) }
        median("piece: ClassicalDenoise(...)") {
            _ = ClassicalDenoise(ISODefaults.classic(for: develop.denoise),
                                 profile: NoiseProfile.forISO(100))
        }
        median("key: colour-grade key (7 subtrees)") {
            _ = PlanTableCache.key(["cg"], [develop.mixer, develop.pointColors,
                                            develop.color, look.primaries, look.bw,
                                            look.wheels, look.printerLights])
        }
        median("key: finish key (render + curve + film)") {
            _ = PlanTableCache.key(["fin"], [look.render, develop.curve])
        }
        median("key: tone cube key (tone + zones)") {
            _ = PlanTableCache.key(["tonecube"], [develop.tone, develop.zones])
        }

        // ---- cold bakes, what a settle pays after a tabled control moved
        let grade = GradeEngine(wheels: look.wheels, printerLights: look.printerLights,
                                whiteAnchorEV: tone.whiteAnchorEV,
                                blackAnchorEV: tone.blackAnchorEV)
        let color = ColorEngine(mixer: develop.mixer, pointColors: develop.pointColors,
                                color: develop.color, primaries: look.primaries,
                                bw: look.bw, bandMeanHues: nil)
        median("cold bake: colour-grade 33^3", repeats: 11) {
            _ = LUT3D(size: LUT3D.interactiveSize) { e in
                LumenLog.encode(grade.apply(color.apply(LumenLog.decode(e))))
            }
        }
        let transform = DisplayTransform.forRecipe(recipe, displayWhiteTarget: nil,
                                                   space: .rec2020)
        let curve = CurveStack(develop.curve)
        let boundary = RenderPlan.sharedGamutBoundary
        median("cold bake: finish 33^3", repeats: 11) {
            _ = LUT3D(size: LUT3D.interactiveSize) { e in
                let formed = transform.apply(LumenLog.decode(e), gamut: boundary)
                return curve.apply(formed, white: transform.white, space: .rec2020)
                    / transform.white
            }
        }

        // ---- what every exported photograph bakes, uncached by design (export size)
        median("export bake: finish \(LUT3D.exportSize)^3", repeats: 3) {
            _ = LUT3D(size: LUT3D.exportSize) { e in
                let formed = transform.apply(LumenLog.decode(e), gamut: boundary)
                return curve.apply(formed, white: transform.white, space: .rec2020)
                    / transform.white
            }
        }
        median("export bake: colour-grade \(LUT3D.exportSize)^3", repeats: 3) {
            _ = LUT3D(size: LUT3D.exportSize) { e in
                LumenLog.encode(grade.apply(color.apply(LumenLog.decode(e))))
            }
        }

        // ---- one mask raster at the draft proxy (context only: the mask caches own it)
        var radial = Mask(id: "r", name: "Radial")
        radial.components = [MaskComponent(op: .add, kind: .radial)]
        median("mask raster: radial fold 1024x683", repeats: 11) {
            _ = MaskRaster.combine(mask: radial, size: (1024, 683))
        }

        // ---- fingerprints and canonical forms
        median("fingerprint: RecipeFingerprint.fingerprint") {
            _ = try? RecipeFingerprint.fingerprint(recipe)
        }
        median("fingerprint: canonicalRecipeJSON") {
            _ = try? CanonicalJSON.canonicalRecipeJSON(recipe)
        }
        median("fingerprint: tree(of: Recipe()) — the defaults baseline") {
            _ = try? CanonicalJSON.tree(of: Recipe())
        }
        median("fingerprint: tree(of: recipe)") {
            _ = try? CanonicalJSON.tree(of: recipe)
        }
        median("fingerprint: decodeRecipe(sparse json)") {
            let json = (try? CanonicalJSON.canonicalRecipeJSON(recipe)) ?? "{}"
            _ = try? CanonicalJSON.decodeRecipe(from: Data(json.utf8))
        }
        median("fingerprint: recipe == recipe (Equatable)") {
            var r = recipe
            r.develop.detail.texture = t
            _ = r == recipe
        }
    }

    func testCatalogQueriesOnATwentyThousandPhotoRoll() throws {
        try XCTSkipUnless(enabled, "set LUMEN_BENCH=1")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-bench-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // LUMEN_BENCH_KEEP=1 leaves the seeded roll on disk so the SQL can be timed
        // outside Swift (which is how the SQLite share of a row below was separated).
        let keep = ProcessInfo.processInfo.environment["LUMEN_BENCH_KEEP"] == "1"
        defer { if !keep { try? FileManager.default.removeItem(at: directory) } }
        if keep { print("BENCH catalog kept at \(directory.path)") }
        let store = try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                                     cachePath: directory.appendingPathComponent("cache.db").path)
        let count = 20_000
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/bench")
        let files = (0..<count).map {
            ScannedFile(filename: String(format: "DSC%05d.ARW", $0),
                        fileSize: Int64(40_000_000 + $0), fileMTime: 1_700_000_000,
                        ext: $0 % 7 == 0 ? "jpg" : "arw")
        }
        let seed0 = DispatchTime.now().uptimeNanoseconds
        _ = try store.scan(folderID: folderID, files: files, at: CatalogStore.now())
        let ids = try store.photos(folderID: folderID).map(\.id)
        let cameras = ["X-T5", "Z8", "A7R V", "R5"]
        let lenses = ["35mm", "50mm", "24-70", "70-200", "90mm macro"]
        var batch: [(photoID: Int64, metadata: PhotoMetadata)] = []
        for (i, id) in ids.enumerated() {
            batch.append((id, PhotoMetadata(captureAt: 1_700_000_000 + Int64((i * 7919) % count),
                                            camera: cameras[i % cameras.count],
                                            lens: lenses[i % lenses.count],
                                            iso: [100, 400, 1600, 6400][i % 4],
                                            aperture: [1.4, 2.8, 5.6, 8][i % 4],
                                            width: 6000, height: i % 3 == 0 ? 6000 : 4000)))
        }
        try store.setMetadata(batch)
        for stars in 1...5 {
            try store.setRating(stars, photoIDs: ids.enumerated()
                .filter { $0.offset % 6 == stars }.map(\.element))
        }
        try store.setFlag(.pick, photoIDs: ids.enumerated().filter { $0.offset % 5 == 0 }.map(\.element))
        try store.setFlag(.reject, photoIDs: ids.enumerated().filter { $0.offset % 11 == 0 }.map(\.element))
        try store.setLabel(.red, photoIDs: ids.enumerated().filter { $0.offset % 9 == 0 }.map(\.element))
        for k in 0..<12 {
            _ = try store.addKeyword("kw\(k)", photoIDs: ids.enumerated()
                .filter { $0.offset % (k + 3) == 0 }.map(\.element))
        }
        print(String(format: "BENCH catalog seed %d photos: %.0f ms", count,
                     Double(DispatchTime.now().uptimeNanoseconds - seed0) / 1e6))

        var q = PhotoQuery()
        for line in try store.queryPlan(for: q, folderID: folderID) {
            print("BENCH plan photos(all): \(line)")
        }
        median("catalog: photos(all), captureTime", repeats: 11) {
            _ = try? store.photos(matching: q, folderID: folderID)
        }
        for key in [PhotoQuery.SortKey.filename, .rating, .fileType, .aspectRatio] {
            q.sortKey = key
            median("catalog: photos(all), sort \(key.rawValue)", repeats: 11) {
                _ = try? store.photos(matching: q, folderID: folderID)
            }
        }
        q = PhotoQuery()
        median("catalog: photoOrder(all), captureTime", repeats: 11) {
            _ = try? store.photoOrder(matching: q, folderID: folderID)
        }
        q.sortKey = .rating
        median("catalog: photoOrder(all), sort rating", repeats: 11) {
            _ = try? store.photoOrder(matching: q, folderID: folderID)
        }
        q = PhotoQuery()
        q.rating = 3
        q.flags = [.pick]
        median("catalog: photos(★3+ picks)", repeats: 11) {
            _ = try? store.photos(matching: q, folderID: folderID)
        }
        q = PhotoQuery()
        q.keywords = ["kw2"]
        median("catalog: photos(keyword)", repeats: 11) {
            _ = try? store.photos(matching: q, folderID: folderID)
        }
        q = PhotoQuery()
        median("catalog: countPhotos(all)", repeats: 21) {
            _ = try? store.countPhotos(matching: q, folderID: folderID)
        }
        median("catalog: cullCounts", repeats: 21) {
            _ = try? store.cullCounts(folderID: folderID)
        }
        median("catalog: facetCounts(for: all)", repeats: 7) {
            _ = try? store.facetCounts(for: q, folderID: folderID)
        }
        q.rating = 2
        median("catalog: facetCounts(for: ★2+)", repeats: 7) {
            _ = try? store.facetCounts(for: q, folderID: folderID)
        }
    }
}
