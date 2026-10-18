#if os(macOS)
import AppKit
import ImageIO
import XCTest
import LumenCore
@testable import LumenApp

private enum MatteFixtureError: Error { case producerDidNotStart }

private actor MatteProducerBarrier {
    private var calls = 0
    private var releasedAll = false
    private let pausedCalls: Set<Int>
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
    init(pausedCalls: Set<Int> = [1]) { self.pausedCalls = pausedCalls }
    func waitForCall(_ number: Int = 1) async throws {
        let deadline = Date().addingTimeInterval(5)
        while calls < number {
            guard Date() < deadline else { throw MatteFixtureError.producerDidNotStart }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    func produce() async -> [String: Plane] {
        calls += 1
        let number = calls
        if !releasedAll && pausedCalls.contains(number) {
            await withCheckedContinuation { releases[number] = $0 }
        }
        return [MaskKind.aiSubject.rawValue: Plane(width: 8, height: 8,
                                                   fill: number == 1 ? 0.25 : 0.75)]
    }
    func release(_ number: Int = 1) { releases.removeValue(forKey: number)?.resume() }
    func releaseAll() {
        releasedAll = true
        let pending = Array(releases.values)
        releases.removeAll()
        for continuation in pending { continuation.resume() }
    }
    func count() -> Int { calls }
}

final class MatteSourceFreshnessTests: XCTestCase {
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.png")
        try write(url, width: 32)
        return url
    }
    private func write(_ url: URL, width: Int) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 24,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 24))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private var recipe: Recipe {
        var value = Recipe()
        value.masks = [Mask(id: "subject", components: [MaskComponent(op: .add, kind: .aiSubject)])]
        return value
    }
    private func suspendedReplacement(refresh: Bool, invalidate: Bool) async throws {
        let url = try fixture()
        let barrier = MatteProducerBarrier()
        defer { Task { await barrier.releaseAll() } }
        let coordinator = RenderCoordinator(matteProducer: { _, _ in await barrier.produce() })
        let recipe = recipe
        let first = Task { await coordinator.ensureMattes(url: url, recipe: recipe) }
        try await barrier.waitForCall()
        if invalidate {
            await coordinator.invalidate(url: url)
        } else {
            try write(url, width: 64)
            if refresh { _ = await coordinator.nativeSize(for: url) }
        }
        await barrier.release()
        let discarded = await first.value
        XCTAssertTrue(discarded.sourceChanged)
        XCTAssertTrue(discarded.available.isEmpty, "obsolete pixels must not publish a plane")
        XCTAssertTrue(discarded.attempted.isEmpty, "obsolete work must not suppress a fresh attempt")
        let fresh = await coordinator.ensureMattes(url: url, recipe: recipe)
        XCTAssertEqual(fresh.available, [MaskKind.aiSubject.rawValue])
        let calls = await barrier.count()
        XCTAssertEqual(calls, 2)
    }
    func testReplacementDetectedByAnotherConsumerRejectsSuspendedMatte() async throws {
        try await suspendedReplacement(refresh: true, invalidate: false)
    }
    func testReplacementWithoutActorLookupRejectsSuspendedMatte() async throws {
        try await suspendedReplacement(refresh: false, invalidate: false)
    }
    func testExplicitInvalidationRejectsSuspendedMatteEvenWithUnchangedStat() async throws {
        try await suspendedReplacement(refresh: false, invalidate: true)
    }
    func testFullyAttemptedEntryRefreshesSourceBeforeFastReturn() async throws {
        let url = try fixture()
        let barrier = MatteProducerBarrier()
        defer { Task { await barrier.releaseAll() } }
        let coordinator = RenderCoordinator(matteProducer: { _, _ in await barrier.produce() })
        let recipe = recipe
        let first = Task { await coordinator.ensureMattes(url: url, recipe: recipe) }
        try await barrier.waitForCall()
        await barrier.release()
        _ = await first.value
        try write(url, width: 64)
        _ = await coordinator.ensureMattes(url: url, recipe: recipe)
        let calls = await barrier.count()
        XCTAssertEqual(calls, 2, "a fully attempted A entry must not suppress B")
    }
    func testLateOldCompletionDoesNotClearNewerMatte() async throws {
        let url = try fixture()
        let barrier = MatteProducerBarrier()
        defer { Task { await barrier.releaseAll() } }
        let coordinator = RenderCoordinator(matteProducer: { _, _ in await barrier.produce() })
        let recipe = recipe
        let first = Task { await coordinator.ensureMattes(url: url, recipe: recipe) }
        try await barrier.waitForCall()
        try write(url, width: 64)
        let newer = await coordinator.ensureMattes(url: url, recipe: recipe)
        XCTAssertEqual(newer.available, [MaskKind.aiSubject.rawValue])
        await barrier.release()
        let late = await first.value
        XCTAssertEqual(late.available, newer.available)
        XCTAssertEqual(late.attempted, newer.attempted)
        let alpha = await coordinator.maskAlpha(url: url, recipe: recipe, maskID: "subject",
                                                strokeSets: [:], longEdge: 16)
        let plane = try XCTUnwrap(alpha)
        XCTAssertEqual(plane[plane.width / 2, plane.height / 2], 0.75)
        let calls = await barrier.count()
        XCTAssertEqual(calls, 2)
    }

    private enum NoCatalog: Error { case fixture }
    @MainActor
    private func withCallerState(url: URL, coordinator: RenderCoordinator,
                                 body: @MainActor (AppState) async throws -> Void) async throws {
        let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let state = AppState(catalogDirectory: { throw NoCatalog.fixture },
                             previewDirectory: { nil }, renderCoordinator: coordinator)
        defer {
            state.prepareToQuit()
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        state.openFolder(url.deletingLastPathComponent(), restrictedTo: [url])
        let deadline = Date().addingTimeInterval(5)
        while state.isScanning && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(state.isScanning)
        let photo = try XCTUnwrap(state.allPhotos.first { $0.id == url })
        state.primarySelection = photo
        state.selection = [url]
        state.recipes[url] = recipe
        try await body(state)
    }

    @MainActor
    private func waitForCaller(_ state: AppState, url: URL) async throws {
        let deadline = Date().addingTimeInterval(5)
        while state.pendingMattes.contains(url) && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(state.pendingMattes.contains(url), "matte caller did not finish")
    }

    @MainActor
    func testCallerAutomaticallyRetriesReplacementAndPublishesFreshPlane() async throws {
        let url = try fixture()
        let barrier = MatteProducerBarrier()
        defer { Task { await barrier.releaseAll() } }
        let coordinator = RenderCoordinator(matteProducer: { _, _ in await barrier.produce() })
        try await withCallerState(url: url, coordinator: coordinator) { state in
            state.ensureMaskMattes()
            try await barrier.waitForCall()
            try write(url, width: 64)
            await barrier.release()
            try await waitForCaller(state, url: url)
            XCTAssertEqual(state.maskMatteKinds(for: url), [MaskKind.aiSubject.rawValue])
            let alpha = await coordinator.maskAlpha(url: url, recipe: recipe, maskID: "subject",
                                                    strokeSets: [:], longEdge: 16)
            let plane = try XCTUnwrap(alpha)
            XCTAssertEqual(plane[plane.width / 2, plane.height / 2], 0.75)
            let calls = await barrier.count()
            XCTAssertEqual(calls, 2)
        }
    }

    @MainActor
    func testCallerStopsAfterOneReplacementRetryWhenSourceKeepsChanging() async throws {
        let url = try fixture()
        let barrier = MatteProducerBarrier(pausedCalls: [1, 2])
        defer { Task { await barrier.releaseAll() } }
        let coordinator = RenderCoordinator(matteProducer: { _, _ in await barrier.produce() })
        try await withCallerState(url: url, coordinator: coordinator) { state in
            state.ensureMaskMattes()
            try await barrier.waitForCall()
            try write(url, width: 64)
            await barrier.release()
            try await barrier.waitForCall(2)
            try write(url, width: 96)
            await barrier.release(2)
            try await waitForCaller(state, url: url)
            XCTAssertTrue(state.maskMatteKinds(for: url).isEmpty)
            let calls = await barrier.count()
            XCTAssertEqual(calls, 2, "second replacement must not start an unbounded retry")
        }
    }

    @MainActor
    func testCallerMissingFileIsUnavailableWithoutRetryingProducer() async throws {
        let url = try fixture()
        let barrier = MatteProducerBarrier()
        defer { Task { await barrier.releaseAll() } }
        let coordinator = RenderCoordinator(matteProducer: { _, _ in await barrier.produce() })
        try await withCallerState(url: url, coordinator: coordinator) { state in
            try FileManager.default.removeItem(at: url)
            state.ensureMaskMattes()
            try await waitForCaller(state, url: url)
            if case .unavailable = state.matteStatus(for: .aiSubject) {} else {
                XCTFail("caller must report a missing original as unavailable")
            }
            let pass = await coordinator.ensureMattes(url: url, recipe: recipe)
            XCTAssertTrue(pass.sourceUnavailable)
            XCTAssertFalse(pass.sourceChanged)
            XCTAssertTrue(pass.attempted.isEmpty)
            let calls = await barrier.count()
            XCTAssertEqual(calls, 0)
        }
    }

}
#endif
