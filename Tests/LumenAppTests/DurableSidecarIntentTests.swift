#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenApp

final class DurableSidecarIntentTests: XCTestCase {
    private static let childRootKey = "LUMEN_DURABLE_INTENT_CHILD_ROOT"
    private static let childModeKey = "LUMEN_DURABLE_INTENT_CHILD_MODE"

    // Executed only by the parent test's isolated xctest subprocess. SIGSTOP makes
    // the crash boundary deterministic: no debounce, deinit or close can run next.
    func testAbruptExitChildFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment[Self.childRootKey] else {
            throw XCTSkip("subprocess fixture; exercised by the killed-process parent")
        }
        let root = URL(fileURLWithPath: path)
        let photo = root.appendingPathComponent("frame.JPG")
        try Data([1, 2, 3]).write(to: photo)
        let seed = try CatalogService(directory: root.appendingPathComponent("catalog"))
        let id = try XCTUnwrap(seed.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        var initial = Recipe(); initial.develop.tone.exposure = 0.5
        seed.saveRecipe(initial, url: photo, catalogID: id)
        await seed.addKeyword("Old", targets: [(id, photo)])
        await seed.addKeyword("Private", targets: [(id, photo)])
        _ = try await seed.querySource(scope: .everywhere, folderPath: root.path)
        seed.flushSidecars()
        seed.close()
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        if ProcessInfo.processInfo.environment[Self.childModeKey] != "keywords" {
            var newest = initial; newest.develop.tone.exposure = 2
            service.saveRecipe(newest, url: photo, catalogID: id)
            var rated = PhotoItem(id: photo); rated.catalogID = id; rated.rating = 4
            service.saveCullingState(rated, labelChanged: false)
        }
        await service.removeKeyword("Private", targets: [(id, photo)])
        await service.addKeyword("Kept", targets: [(id, photo)])
        _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
        try Data(String(id).utf8).write(to: root.appendingPathComponent("ready"), options: .atomic)
        raise(SIGSTOP)
        XCTFail("the parent must kill this stopped child without orderly cleanup")
    }

    private func runKilledChild(root: URL, mode: String = "all") async throws -> Int64 {
        let output = root.appendingPathComponent("child.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        let log = try FileHandle(forWritingTo: output)
        defer { try? log.close() }
        let locator = Process()
        locator.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        locator.arguments = ["--find", "xctest"]
        let location = Pipe(); locator.standardOutput = location
        try locator.run(); locator.waitUntilExit()
        XCTAssertEqual(locator.terminationStatus, 0)
        let executable = try XCTUnwrap(String(data: location.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["-XCTest", "LumenAppTests.DurableSidecarIntentTests/testAbruptExitChildFixture",
                           Bundle(for: Self.self).bundlePath]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.childRootKey] = root.path
        environment[Self.childModeKey] = mode
        child.environment = environment
        child.standardOutput = log; child.standardError = log
        try child.run()
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
        }
        let ready = root.appendingPathComponent("ready")
        let deadline = Date().addingTimeInterval(25)
        while !FileManager.default.fileExists(atPath: ready.path) && child.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let readyBytes = try? Data(contentsOf: ready),
              let text = String(data: readyBytes, encoding: .utf8), let id = Int64(text) else {
            XCTFail("child never reached the committed, unflushed boundary: \((try? String(contentsOf: output, encoding: .utf8)) ?? "no log")")
            throw CocoaError(.fileReadUnknown)
        }
        XCTAssertEqual(kill(child.processIdentifier, SIGKILL), 0)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGKILL)
        return id
    }

    func testKilledProcessRetainsCommittedRecipeAndPortableIntentAcrossExternalRewrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-killed-intent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await runKilledChild(root: root)
        let photo = root.appendingPathComponent("frame.JPG")
        let sidecar = CatalogService.sidecarURL(for: photo)
        let oldContent = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
        XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(try XCTUnwrap(oldContent.recipeJSON).utf8)).develop.tone.exposure, 0.5,
                       "the child must stop before its newest portable write")
        var external = Recipe(); external.develop.tone.exposure = -1.5
        var externalContent = SidecarContent(recipeJSON: try CanonicalJSON.canonicalRecipeJSON(external))
        externalContent.keywords = ["External"]
        let externalBytes = Data(XMPSidecar.serialize(externalContent).utf8)
        try externalBytes.write(to: sidecar)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        let loaded = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo])
        XCTAssertEqual(loaded.recipe?.develop.tone.exposure, 2, "external B cannot erase the killed process's committed C")
        XCTAssertEqual(loaded.rating, 4)
        let conflicts = root.appendingPathComponent("catalog/sidecar-conflicts")
        let archived = (try? FileManager.default.contentsOfDirectory(at: conflicts, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(archived.contains { (try? Data(contentsOf: $0)) == externalBytes }, "preserve exact external B before publication")
        service.flushSidecars()
        let published = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
        XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(try XCTUnwrap(published.recipeJSON).utf8)).develop.tone.exposure, 2)
        XCTAssertEqual(published.rating, 4)
        XCTAssertEqual(published.keywords, ["External", "Kept"])
        let store = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
        defer { store.close() }
        XCTAssertEqual(try store.currentRecipe(photoID: id)?.develop.tone.exposure, 2)
        XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
    }

    func testOlderSuccessfulFlushDoesNotSettleNewerRecipeIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-overlap-intent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.JPG")
        try Data([1]).write(to: photo)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        let sidecar = CatalogService.sidecarURL(for: photo)
        try Data(XMPSidecar.serialize(SidecarContent()).utf8).write(to: sidecar)
        var older = Recipe(); older.develop.tone.exposure = 1
        service.saveRecipe(older, url: photo, catalogID: id)
        _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
        var reads = 0
        service.sidecarDataReader = { path in
            reads += 1
            service.sidecarDataReader = { try Data(contentsOf: $0) }
            var newer = older; newer.develop.tone.exposure = 2
            service.saveRecipe(newer, url: photo, catalogID: id)
            _ = service.registerAndLoad(folder: root, files: [photo])
            return try Data(contentsOf: path)
        }
        service.flushSidecars()
        XCTAssertEqual(reads, 1)
        let store = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
        defer { store.close() }
        let owed = try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey))
        XCTAssertEqual(owed.first?.photoID, id)
        XCTAssertNotNil(owed.first?.generation)
        XCTAssertEqual(try store.currentRecipe(photoID: id)?.develop.tone.exposure, 2)
        service.flushSidecars()
        XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
        let published = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
        XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(try XCTUnwrap(published.recipeJSON).utf8)).develop.tone.exposure, 2)
    }
    func testRejectedIntentRollsBackCatalogAndDoesNotEnqueuePortableEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-refused-intent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.JPG")
        try Data([1]).write(to: photo)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        var baseline = Recipe(); baseline.develop.tone.exposure = 0.5
        service.saveRecipe(baseline, url: photo, catalogID: id)
        _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
        service.flushSidecars()
        let sidecar = CatalogService.sidecarURL(for: photo)
        let beforeBytes = try Data(contentsOf: sidecar)
        let store = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
        defer { store.close() }
        let before = try store.currentEdit(photoID: id)
        try store.debugExecute("CREATE TRIGGER reject_intent BEFORE INSERT ON meta WHEN NEW.key = 'sidecar_unsaved' BEGIN SELECT RAISE(ABORT, 'injected intent refusal'); END;")
        var failures: [String] = []
        service.onFailure = { failures.append($0) }
        var changed = baseline; changed.develop.tone.exposure = 2
        service.saveRecipe(changed, url: photo, catalogID: id)
        _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
        service.flushSidecars()
        XCTAssertEqual(try store.currentEdit(photoID: id), before)
        XCTAssertEqual(try Data(contentsOf: sidecar), beforeBytes)
        XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
        XCTAssertTrue(failures.contains { $0.contains("injected intent refusal") })
    }

    func testNewerRatingPublicationCarriesInflightRecipeAndRejectsOlderWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-full-intent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.JPG")
        try Data([1]).write(to: photo)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        let sidecar = CatalogService.sidecarURL(for: photo)
        try Data(XMPSidecar.serialize(SidecarContent()).utf8).write(to: sidecar)
        var recipe = Recipe(); recipe.develop.tone.exposure = 1.25
        service.saveRecipe(recipe, url: photo, catalogID: id)
        _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
        var newestBytes: Data?
        var reads = 0
        service.sidecarDataReader = { path in
            reads += 1
            let oldBytes = try Data(contentsOf: path)
            service.sidecarDataReader = { try Data(contentsOf: $0) }
            var rated = PhotoItem(id: photo); rated.catalogID = id; rated.rating = 5
            service.saveCullingState(rated, labelChanged: false)
            _ = service.registerAndLoad(folder: root, files: [photo])
            // Publish generation 2 while generation 1 is still holding old bytes.
            service.flushSidecars()
            newestBytes = try Data(contentsOf: path)
            return oldBytes
        }
        service.flushSidecars()
        XCTAssertEqual(reads, 1)
        let finalBytes = try Data(contentsOf: sidecar)
        XCTAssertEqual(finalBytes, try XCTUnwrap(newestBytes), "the older batch must not write after generation 2")
        let published = try XCTUnwrap(XMPSidecar.parse(finalBytes))
        XCTAssertEqual(published.rating, 5)
        XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(try XCTUnwrap(published.recipeJSON).utf8)).develop.tone.exposure, 1.25,
                       "the newer rating intent also owes the in-flight recipe")
        let store = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
        defer { store.close() }
        XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
    }

    func testMalformedJournalSurvivesOpenCloseAndRefusesNewMutations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-bad-intent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.JPG")
        try Data([1]).write(to: photo)
        let catalog = root.appendingPathComponent("catalog")
        let seed = try CatalogService(directory: catalog)
        let id = try XCTUnwrap(seed.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        var baseline = Recipe(); baseline.develop.tone.exposure = 0.5
        seed.saveRecipe(baseline, url: photo, catalogID: id)
        seed.close()
        let store = try CatalogStore(path: catalog.appendingPathComponent("lumen.db").path)
        defer { store.close() }
        let before = try store.currentEdit(photoID: id)
        let journals = [
            "{unreadable journal: preserve these exact bytes}",
            "[{\"photoPath\":\"/fixture\",\"stated\":64}]",
            "[{\"photoPath\":\"/fixture\",\"stated\":8,\"futurePainting\":\"opaque\"}]"
        ]
        for raw in journals {
            try store.setMetaValue(UnsavedSidecarRecord.metaKey, raw)
            let service = try CatalogService(directory: catalog)
            XCTAssertTrue(service.unsavedSidecarNotice?.contains("journal was preserved") == true)
            var changed = baseline; changed.develop.tone.exposure = 2
            service.saveRecipe(changed, url: photo, catalogID: id)
            var rated = PhotoItem(id: photo); rated.catalogID = id; rated.rating = 4
            service.saveCullingState(rated, labelChanged: false)
            await service.addKeyword("Refused", targets: [(id, photo)])
            _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
            do { try await service.requireAvailablePhoto(photoID: id); XCTFail("unknown journal cannot authorize export") }
            catch { }
            service.close()
            XCTAssertEqual(try store.currentEdit(photoID: id), before)
            XCTAssertEqual(try store.photo(id: id)?.rating, 0)
            XCTAssertEqual(try store.keywords(photoID: id), [])
            XCTAssertEqual(try store.metaValue(UnsavedSidecarRecord.metaKey), raw)
        }
    }

    func testLegacyNilGenerationCannotWriteAfterNewerGenerationSettles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-legacy-intent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.JPG")
        try Data([1]).write(to: photo)
        let catalog = root.appendingPathComponent("catalog")
        let seed = try CatalogService(directory: catalog)
        let id = try XCTUnwrap(seed.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        var recipe = Recipe(); recipe.develop.tone.exposure = 1.25
        seed.saveRecipe(recipe, url: photo, catalogID: id)
        seed.close()
        let store = try CatalogStore(path: catalog.appendingPathComponent("lumen.db").path)
        defer { store.close() }
        let legacy = UnsavedSidecarRecord(photoPath: photo.path, photoID: id, stated: [.recipe, .strokes])
        try store.setMetaValue(UnsavedSidecarRecord.metaKey, UnsavedSidecarRecord.encode([legacy]))
        let sidecar = CatalogService.sidecarURL(for: photo)
        try Data(XMPSidecar.serialize(SidecarContent()).utf8).write(to: sidecar)
        let service = try CatalogService(directory: catalog)
        defer { service.close() }
        _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
        XCTAssertNil(try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey)).first?.generation)
        var newestBytes: Data?
        var reads = 0
        service.sidecarDataReader = { path in
            reads += 1
            let oldBytes = try Data(contentsOf: path)
            service.sidecarDataReader = { try Data(contentsOf: $0) }
            var rated = PhotoItem(id: photo); rated.catalogID = id; rated.rating = 5
            service.saveCullingState(rated, labelChanged: false)
            _ = service.registerAndLoad(folder: root, files: [photo])
            service.flushSidecars()
            newestBytes = try Data(contentsOf: path)
            return oldBytes
        }
        service.flushSidecars()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try Data(contentsOf: sidecar), try XCTUnwrap(newestBytes))
        let published = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
        XCTAssertEqual(published.rating, 5)
        XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(try XCTUnwrap(published.recipeJSON).utf8)).develop.tone.exposure, 1.25)
        XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
    }
    func testLegacyFailedReadCannotRecreateSettledOlderIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-legacy-intent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.JPG")
        try Data([1]).write(to: photo)
        let catalog = root.appendingPathComponent("catalog")
        let seed = try CatalogService(directory: catalog)
        let id = try XCTUnwrap(seed.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        var recipe = Recipe(); recipe.develop.tone.exposure = 1.25
        seed.saveRecipe(recipe, url: photo, catalogID: id)
        seed.close()
        let store = try CatalogStore(path: catalog.appendingPathComponent("lumen.db").path)
        defer { store.close() }
        let legacy = UnsavedSidecarRecord(photoPath: photo.path, photoID: id, stated: [.recipe, .strokes])
        try store.setMetaValue(UnsavedSidecarRecord.metaKey, UnsavedSidecarRecord.encode([legacy]))
        let sidecar = CatalogService.sidecarURL(for: photo)
        try Data(XMPSidecar.serialize(SidecarContent()).utf8).write(to: sidecar)
        let service = try CatalogService(directory: catalog)
        defer { service.close() }
        _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
        XCTAssertNil(try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey)).first?.generation)
        var newestBytes: Data?
        var reads = 0
        service.sidecarDataReader = { path in
            reads += 1
            let oldBytes = try Data(contentsOf: path)
            service.sidecarDataReader = { try Data(contentsOf: $0) }
            var rated = PhotoItem(id: photo); rated.catalogID = id; rated.rating = 5
            service.saveCullingState(rated, labelChanged: false)
            _ = service.registerAndLoad(folder: root, files: [photo])
            service.flushSidecars()
            newestBytes = try Data(contentsOf: path)
            _ = oldBytes
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }
        service.flushSidecars()
        XCTAssertEqual(reads, 1)
        service.flushSidecars()
        XCTAssertEqual(try Data(contentsOf: sidecar), try XCTUnwrap(newestBytes))
        let published = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
        XCTAssertEqual(published.rating, 5)
        XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(try XCTUnwrap(published.recipeJSON).utf8)).develop.tone.exposure, 1.25)
        XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
    }

    func testCloseRetainsIntentAndPreventsLatePreparedPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-close-intent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.JPG")
        try Data([1]).write(to: photo)
        let catalog = root.appendingPathComponent("catalog")
        let service = try CatalogService(directory: catalog)
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        let sidecar = CatalogService.sidecarURL(for: photo)
        let before = Data(XMPSidecar.serialize(SidecarContent()).utf8)
        try before.write(to: sidecar)
        var recipe = Recipe(); recipe.develop.tone.exposure = 1.25
        service.saveRecipe(recipe, url: photo, catalogID: id)
        _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
        var reads = 0
        var owedAtClose: [String] = []
        service.sidecarDataReader = { path in
            reads += 1
            service.sidecarDataReader = { try Data(contentsOf: $0) }
            let oldBytes = try Data(contentsOf: path)
            owedAtClose = service.close()
            return oldBytes
        }
        service.flushSidecars()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(owedAtClose, ["frame.JPG.xmp"])
        XCTAssertEqual(try Data(contentsOf: sidecar), before)
        let store = try CatalogStore(path: catalog.appendingPathComponent("lumen.db").path)
        let debt = try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey))
        XCTAssertEqual(debt.first?.photoID, id)
        XCTAssertEqual(try store.currentRecipe(photoID: id)?.develop.tone.exposure, 1.25)
        store.close()
        let reopened = try CatalogService(directory: catalog)
        defer { reopened.close() }
        _ = try await reopened.querySource(scope: .everywhere, folderPath: root.path)
        reopened.flushSidecars()
        let published = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
        XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(try XCTUnwrap(published.recipeJSON).utf8)).develop.tone.exposure, 1.25)
    }

    func testNewKeywordIntentDoesNotResurrectUnrelatedExternalRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-keyword-intent-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("frame.JPG")
        try Data([1]).write(to: photo)
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        let id = try XCTUnwrap(service.registerAndLoad(folder: root, files: [photo])[photo]?.catalogID)
        await service.addKeyword("Old", targets: [(id, photo)])
        service.flushSidecars()
        let sidecar = CatalogService.sidecarURL(for: photo)
        var external = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
        external.keywords = ["External"]
        try Data(XMPSidecar.serialize(external).utf8).write(to: sidecar)
        // Do not rescan: the catalog still contains Old. The new gesture owns New.
        await service.addKeyword("New", targets: [(id, photo)])
        service.flushSidecars()
        let published = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
        XCTAssertEqual(published.keywords, ["External", "New"])
    }

    func testKilledKeywordOnlyIntentDoesNotResurrectUnrelatedExternalRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-killed-keywords-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try await runKilledChild(root: root, mode: "keywords")
        let photo = root.appendingPathComponent("frame.JPG")
        let sidecar = CatalogService.sidecarURL(for: photo)
        var external = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
        XCTAssertEqual(Set(external.keywords ?? []), ["Old", "Private"])
        let originalRecipe = external.recipeJSON
        external.keywords = ["External"]
        try Data(XMPSidecar.serialize(external).utf8).write(to: sidecar)
        let catalog = root.appendingPathComponent("catalog")
        let store = try CatalogStore(path: catalog.appendingPathComponent("lumen.db").path)
        defer { store.close() }
        let debt = try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey))
        let owed = try XCTUnwrap(debt.first)
        XCTAssertEqual(owed.photoID, id)
        XCTAssertEqual(owed.statedFields, [.keywords], "isolate keyword-only crash recovery")
        XCTAssertNotNil(owed.generation)
        let service = try CatalogService(directory: catalog)
        defer { service.close() }
        _ = service.registerAndLoad(folder: root, files: [photo])
        service.flushSidecars()
        let published = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: sidecar)))
        XCTAssertEqual(published.keywords, ["External", "Kept"])
        XCTAssertEqual(published.recipeJSON, originalRecipe, "the oracle changes no recipe")
        XCTAssertEqual(try store.currentRecipe(photoID: id)?.develop.tone.exposure, 0.5)
        XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
    }

}
#endif
