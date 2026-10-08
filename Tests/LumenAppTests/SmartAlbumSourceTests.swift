#if os(macOS)
import CoreGraphics
import ImageIO
import XCTest
@testable import LumenCore
@testable import LumenApp

@MainActor
final class SmartAlbumSourceTests: XCTestCase {
    private func settle(_ state: AppState) async throws {
        let until = Date().addingTimeInterval(10)
        while (state.isScanning || !state.isLibraryQueryLive) && Date() < until {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(state.isScanning)
        XCTAssertTrue(state.isLibraryQueryLive)
    }

    private func fixture(_ body: (AppState, CatalogService, [URL], [URL], URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-smart-source-\(UUID())")
        let folders = [root.appendingPathComponent("one"), root.appendingPathComponent("one/child"), root.appendingPathComponent("two")]
        let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files"]
        let defaults = keys.map { UserDefaults.standard.object(forKey: $0) }
        var urls: [URL] = []
        for (index, folder) in folders.enumerated() {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("photo\(index).JPG")
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(CGColor(gray: CGFloat(index + 1) / 4, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let out = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
            CGImageDestinationAddImage(out, try XCTUnwrap(ctx.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(out)); urls.append(url)
        }
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") }, previewDirectory: { root.appendingPathComponent("preview") })
        defer {
            state.prepareToQuit()
            for (key, value) in zip(keys, defaults) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        state.openFolder(folders[0], restrictedTo: [urls[0]])
        try await settle(state)
        let catalog = try XCTUnwrap(state.catalog)
        for index in 1..<3 { _ = catalog.registerAndLoad(folder: folders[index], files: [urls[index]]) }
        try await body(state, catalog, folders, urls, root)
    }

    func testProductionSourceLoadsWholeCatalogSubtreeAndManualAlbumWithMatchingCounts() async throws {
        try await fixture { state, catalog, folders, _, root in
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            let rootID = try XCTUnwrap(db.folder(path: folders[0].path)?.id)
            let all = try db.photos(matching: PhotoQuery())
            let manual = try db.createCollection(name: "Chosen")
            try db.addToCollection(manual, photoIDs: [all.last!.id])
            try db.setFolderOnline(false, folderID: all.last!.folderID)
            db.close()
            for (scope, expected) in [(CollectionQueryScope.everywhere, 3), (.folderSubtree(rootID), 2), (.album(manual), 1)] {
                let created = await catalog.createSmartCollection(name: scope.label, query: LibraryFilter().savedJSON(), scope: scope)
                let id = try XCTUnwrap(created)
                let albums = await catalog.collections(folderPath: folders[0].path)
                let item = try XCTUnwrap(albums.first { $0.id == id })
                XCTAssertEqual(item.count, expected)
                state.applySmartCollection(item)
                try await self.settle(state)
                XCTAssertEqual(state.allPhotos.count, expected)
                XCTAssertEqual(state.photos.count, expected)
                let counted = await catalog.facetCounts(for: state.libraryPhotoQuery, folderPath: folders[0].path)
                XCTAssertEqual(counted.unlabeled, expected)
            }
            state.showWholeFolder()
            try await self.settle(state)
            XCTAssertNil(state.activeSmartCollection)
            XCTAssertEqual(state.photos.count, 1)
        }
    }

    func testNewerScopeWinsAndLiveRecipesCullingAreNotOverwrittenByOlderRead() async throws {
        try await fixture { state, catalog, folders, _, _ in
            let all = try await catalog.querySource(scope: .everywhere, folderPath: folders[0].path)
            var resumes: [CheckedContinuation<[CatalogService.SourceEntry], Error>] = []
            state.querySourceLoader = { _, _ in try await withCheckedThrowingContinuation { resumes.append($0) } }
            let one = CollectionItem(id: 101, name: "Older", count: 3, isTarget: false, isSmart: true, filter: LibraryFilter(), scope: .everywhere)
            let two = CollectionItem(id: 102, name: "Newer", count: 3, isTarget: false, isSmart: true, filter: LibraryFilter(), scope: .everywhere)
            state.applySmartCollection(one)
            while resumes.count < 1 { await Task.yield() }
            state.applySmartCollection(two)
            while resumes.count < 2 { await Task.yield() }
            let photo = try XCTUnwrap(state.allPhotos.first)
            state.select(photo)
            state.sliderGesture(active: true)
            state.updateRecipe { $0.develop.tone.exposure = 1.75 }
            state.setRating(5)
            resumes[1].resume(returning: all)
            try await self.settle(state)
            XCTAssertEqual(state.activeSmartCollection?.id, two.id)
            let retained = try XCTUnwrap(state.allPhotos.first { $0.catalogID == photo.catalogID })
            XCTAssertEqual(state.recipe(for: retained).develop.tone.exposure, 1.75)
            XCTAssertEqual(retained.rating, 5)
            resumes[0].resume(returning: [])
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(state.activeSmartCollection?.id, two.id)
            XCTAssertEqual(state.allPhotos.count, 3)
            _ = try await catalog.exportKeywords(photoID: try XCTUnwrap(photo.catalogID)) // drains deferred writes
        }
    }

    func testNewerFolderWinsAndFailedScopeKeepsCurrentRollAndEdits() async throws {
        try await fixture { state, catalog, folders, urls, _ in
            let before = state.allPhotos.map(\.id)
            var resume: CheckedContinuation<[CatalogService.SourceEntry], Error>?
            state.querySourceLoader = { _, _ in try await withCheckedThrowingContinuation { resume = $0 } }
            let album = CollectionItem(id: 102, name: "Slow", count: 3, isTarget: false, isSmart: true, filter: LibraryFilter(), scope: .everywhere)
            state.applySmartCollection(album)
            while resume == nil { await Task.yield() }
            resume!.resume(throwing: CatalogError.notFound("deleted scope"))
            try await self.settle(state)
            XCTAssertEqual(state.allPhotos.map(\.id), before)
            XCTAssertNil(state.activeSmartCollection)
            state.applySmartCollection(album)
            resume = nil
            while resume == nil { await Task.yield() }
            state.openFolder(folders[2], restrictedTo: [urls[2]])
            try await self.settle(state)
            resume!.resume(returning: try await catalog.querySource(scope: .everywhere, folderPath: folders[0].path))
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(state.folderURL, folders[2])
            XCTAssertEqual(state.allPhotos.map(\.id), [urls[2]])
            XCTAssertNil(state.activeSmartCollection)
        }
    }
    func testDeletingAnActiveManualScopeRetainsReferenceButClearsVisibleResults() async throws {
        try await fixture { state, catalog, folders, _, root in
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            let id = try XCTUnwrap(state.allPhotos.first?.catalogID)
            let manual = try db.createCollection(name: "Temporary source")
            try db.addToCollection(manual, photoIDs: [id])
            db.close()
            let created = await catalog.createSmartCollection(name: "Scoped", query: LibraryFilter().savedJSON(), scope: .album(manual))
            let smartID = try XCTUnwrap(created)
            let albums = await catalog.collections(folderPath: folders[0].path)
            state.refreshLibrarySections()
            let listedBy = Date().addingTimeInterval(5)
            while !state.collections.contains(where: { $0.id == manual }) && Date() < listedBy { try await Task.sleep(nanoseconds: 10_000_000) }
            state.applySmartCollection(try XCTUnwrap(albums.first { $0.id == smartID }))
            try await self.settle(state)
            XCTAssertEqual(state.photos.count, 1)
            state.deleteCollection(manual)
            let until = Date().addingTimeInterval(5)
            while state.activeSmartCollection?.unavailableReason == nil && Date() < until { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertNotNil(state.activeSmartCollection?.unavailableReason)
            XCTAssertEqual(state.activeSmartCollection?.scope, .deletedAlbum(manual))
            XCTAssertTrue(state.photos.isEmpty)
            XCTAssertTrue(state.selection.isEmpty)
            XCTAssertNil(state.primarySelection)
            let current = await catalog.collections(folderPath: folders[0].path)
            XCTAssertNotNil(current.first { $0.id == smartID }?.unavailableReason)
            XCTAssertEqual(current.first { $0.id == smartID }?.scope, .deletedAlbum(manual))
            state.showWholeFolder()
            try await self.settle(state)
            XCTAssertEqual(state.photos.count, 1)
        }
    }

    func testOverlappingRegistrationsRefuseAmbiguousURLUniverseWithoutCollapsingRows() async throws {
        try await fixture { state, catalog, folders, urls, root in
            // The same child can have a nested relative row and a child-folder row.
            _ = catalog.registerAndLoad(folder: folders[0], files: [urls[0], urls[1]], completeListing: false)
            let valid = try await catalog.querySource(scope: .everywhere, folderPath: folders[0].path)
            XCTAssertEqual(valid.count, 3, "normal registration adopts related-folder ownership")
            // Reproduce legacy/corrupt duplicate ownership without bypassing the
            // normal registration contract in production.
            let child = try XCTUnwrap(valid.first { $0.url.lastPathComponent == urls[1].lastPathComponent })
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            let childFolder = try XCTUnwrap(db.folder(path: folders[1].path)?.id)
            try db.debugExecute("INSERT INTO photo(folder_id,filename,file_size,file_mtime,flag,rating,missing,ext) SELECT \(childFolder),'photo1.JPG',file_size,file_mtime,flag,rating,missing,ext FROM photo WHERE id = \(child.state.catalogID);")
            db.close()
            do {
                _ = try await catalog.querySource(scope: .everywhere, folderPath: folders[0].path)
                XCTFail("ambiguous URL-backed UI source must be refused")
            } catch { XCTAssertTrue(String(describing: error).contains("multiple catalog rows")) }
            let previous = state.allPhotos.map(\.id)
            let created = await catalog.createSmartCollection(name: "Ambiguous", query: LibraryFilter().savedJSON(), scope: .everywhere)
            let id = try XCTUnwrap(created)
            let albums = await catalog.collections(folderPath: folders[0].path)
            state.applySmartCollection(try XCTUnwrap(albums.first { $0.id == id }))
            try await self.settle(state)
            XCTAssertEqual(state.allPhotos.map(\.id), previous)
            XCTAssertNil(state.activeSmartCollection)
            XCTAssertTrue(state.statusMessage?.contains("multiple catalog rows") == true)
        }
    }

    func testExplicitCatalogScopeOpensWithoutAnyCurrentFolder() async throws {
        try await fixture { state, catalog, _, _, root in
            let created = await catalog.createSmartCollection(name: "Catalog", query: LibraryFilter().savedJSON(), scope: .everywhere)
            let id = try XCTUnwrap(created)
            state.prepareToQuit()
            let reopened = AppState(catalogDirectory: { root.appendingPathComponent("catalog") }, previewDirectory: { root.appendingPathComponent("preview2") })
            defer { reopened.prepareToQuit() }
            XCTAssertNil(reopened.folderURL)
            let reopenedCatalog = try XCTUnwrap(reopened.catalog)
            let albums = await reopenedCatalog.collections(folderPath: nil)
            reopened.applySmartCollection(try XCTUnwrap(albums.first { $0.id == id }))
            try await self.settle(reopened)
            XCTAssertEqual(reopened.photos.count, 3)
            XCTAssertEqual(reopened.activeSmartCollection?.scope, .everywhere)
            let counted = await reopenedCatalog.facetCounts(for: reopened.libraryPhotoQuery, folderPath: nil)
            XCTAssertEqual(counted.unlabeled, 3)
        }
    }

    func testSourceSwitchFlushesGestureAndPreservesUnwritableSidecarDebt() async throws {
        try await fixture { state, catalog, folders, _, root in
            let photo = try XCTUnwrap(state.allPhotos.first)
            let id = try XCTUnwrap(photo.catalogID)
            let sidecar = photo.id.appendingPathExtension("xmp")
            try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
            state.select(photo)
            state.sliderGesture(active: true)
            state.updateRecipe { $0.develop.tone.exposure = 2.25 }
            let created = await catalog.createSmartCollection(name: "All", query: LibraryFilter().savedJSON(), scope: .everywhere)
            let smart = try XCTUnwrap(created)
            let albums = await catalog.collections(folderPath: folders[0].path)
            state.applySmartCollection(try XCTUnwrap(albums.first { $0.id == smart }))
            try await self.settle(state)
            let selected = try XCTUnwrap(state.allPhotos.first { $0.catalogID == id })
            XCTAssertEqual(state.recipe(for: selected).develop.tone.exposure, 2.25)
            catalog.flushSidecars()
            _ = try await catalog.exportKeywords(photoID: id) // drain durable failure checkpoint
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            defer { db.close() }
            XCTAssertEqual(try db.currentRecipe(photoID: id)?.develop.tone.exposure, 2.25)
            let owed = UnsavedSidecarRecord.decode(try db.metaValue(UnsavedSidecarRecord.metaKey))
            XCTAssertTrue(owed.contains { $0.photoID == id && $0.statedFields.contains(.recipe) })
            XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        }
    }

    func testSourceReadUsesCatalogRecipeWithoutImportingConflictingSidecar() async throws {
        try await fixture { state, catalog, folders, _, root in
            let photo = try XCTUnwrap(state.allPhotos.first)
            let id = try XCTUnwrap(photo.catalogID)
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            var catalogRecipe = Recipe(); catalogRecipe.develop.tone.exposure = 1.25
            try db.saveRecipe(catalogRecipe, photoID: id, isCurrent: true)
            db.close()
            var external = Recipe(); external.develop.tone.exposure = -3
            let content = SidecarContent(recipeJSON: try CanonicalJSON.canonicalRecipeJSON(external))
            let data = Data(XMPSidecar.serialize(content).utf8)
            let sidecar = photo.id.appendingPathExtension("xmp")
            try data.write(to: sidecar)
            let entries = try await catalog.querySource(scope: .everywhere, folderPath: folders[0].path)
            XCTAssertEqual(entries.first { $0.state.catalogID == id }?.state.recipe, catalogRecipe)
            XCTAssertEqual(try Data(contentsOf: sidecar), data)
        }
    }

    func testPausedScopeSourceCannotRestoreOldURLAfterActualRelink() async throws {
        try await fixture { state, catalog, folders, _, root in
            let photo = try XCTUnwrap(state.allPhotos.first)
            let id = try XCTUnwrap(photo.catalogID)
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            try db.setQuickSig(QuickSignature.compute(url: photo.id), photoID: id)
            db.close()
            let oldEntries = try await catalog.querySource(scope: .everywhere, folderPath: folders[0].path)
            let destination = root.appendingPathComponent("relinked/original.JPG")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: photo.id, to: destination)
            let prepared = try await catalog.prepareOriginalRelink(photoID: id, candidateURL: destination)
            var resume: CheckedContinuation<[CatalogService.SourceEntry], Error>?
            state.querySourceLoader = { _, _ in try await withCheckedThrowingContinuation { resume = $0 } }
            let created = await catalog.createSmartCollection(name: "Paused", query: LibraryFilter().savedJSON(), scope: .everywhere)
            let idOfAlbum = try XCTUnwrap(created)
            let albums = await catalog.collections(folderPath: folders[0].path)
            state.applySmartCollection(try XCTUnwrap(albums.first { $0.id == idOfAlbum }))
            while resume == nil { await Task.yield() }
            try await state.relinkOriginal(prepared)
            let current = try XCTUnwrap(state.allPhotos.first { $0.catalogID == id })
            XCTAssertEqual(current.id, destination.standardizedFileURL.resolvingSymlinksInPath())
            resume!.resume(returning: oldEntries)
            try await self.settle(state)
            let after = try XCTUnwrap(state.allPhotos.first { $0.catalogID == id })
            XCTAssertEqual(after.id, current.id, "source acquisition must not restore missing old URL")
            XCTAssertFalse(state.allPhotos.contains { $0.id == photo.id })
        }
    }

    func testPausedSubtreeRechecksMembershipWhenRelinkMovesOutsideItsRoot() async throws {
        try await fixture { state, catalog, folders, _, root in
            let photo = try XCTUnwrap(state.allPhotos.first)
            let id = try XCTUnwrap(photo.catalogID)
            let db = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
            let folderID = try XCTUnwrap(db.folder(path: folders[0].path)?.id)
            try db.setQuickSig(QuickSignature.compute(url: photo.id), photoID: id)
            db.close()
            let scope = CollectionQueryScope.folderSubtree(folderID)
            let oldEntries = try await catalog.querySource(scope: scope, folderPath: folders[0].path)
            let destination = root.appendingPathComponent("outside/original.JPG")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: photo.id, to: destination)
            let prepared = try await catalog.prepareOriginalRelink(photoID: id, candidateURL: destination)
            let created = await catalog.createSmartCollection(name: "Subtree", query: LibraryFilter().savedJSON(), scope: scope)
            let smartID = try XCTUnwrap(created)
            let albums = await catalog.collections(folderPath: folders[0].path)
            var resume: CheckedContinuation<[CatalogService.SourceEntry], Error>?
            state.querySourceLoader = { _, _ in try await withCheckedThrowingContinuation { resume = $0 } }
            state.applySmartCollection(try XCTUnwrap(albums.first { $0.id == smartID }))
            while resume == nil { await Task.yield() }
            try await state.relinkOriginal(prepared)
            resume!.resume(returning: oldEntries)
            try await self.settle(state)
            XCTAssertFalse(state.allPhotos.contains { $0.catalogID == id })
            XCTAssertFalse(state.photos.contains { $0.catalogID == id })
            XCTAssertEqual(state.allPhotos.count, 1)
            let current = await catalog.collections(folderPath: folders[0].path)
            XCTAssertEqual(current.first { $0.id == smartID }?.count, state.photos.count)
        }
    }

}
#endif
