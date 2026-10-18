// Synthetic catalog rows only. No RAWs, image decoding, XMP writes or timing gates.
import Dispatch
import Foundation
import LumenCore

func timed(_ operation: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try operation()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}
let maximum = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 1000
let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-intent-scaling-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let folderPath = "/synthetic/public-fixture"
print("pending\tbare_total_ms\tper_mutation_total_ms\tsingle_batch_total_ms\tbare_last40_ms\tper_mutation_last40_ms\tsingle_batch_mean_ms\tjournal_json_bytes")
for count in [40, 200, 500, 1000].filter({ $0 <= maximum }) {
    let bare = try CatalogStore(path: root.appendingPathComponent("bare-\(count).db").path)
    let perMutation = try CatalogStore(path: root.appendingPathComponent("per-\(count).db").path)
    let batch = try CatalogStore(path: root.appendingPathComponent("batch-\(count).db").path)
    let files = (0...count).map { ScannedFile(filename: String(format: "frame%06d.ARW", $0), fileSize: 1, fileMTime: 1, ext: "arw") }
    func seed(_ store: CatalogStore) throws -> [Int64] {
        let folder = try store.registerFolder(path: folderPath)
        _ = try store.scan(folderID: folder, files: files)
        let ids = try files.map { try store.photo(folderID: folder, filename: $0.filename)!.id }
        try store.saveRecipe(Recipe(), photoID: ids[0], isCurrent: true)
        return ids
    }
    let bareIDs = try seed(bare), perIDs = try seed(perMutation), batchIDs = try seed(batch)
    var bareTimes: [Double] = [], perTimes: [Double] = []
    let recipes = (0...count).map { index -> Recipe in
        var recipe = Recipe(); recipe.develop.tone.exposure = Double(index % 31) / 20.0
        return recipe
    }
    func intent(_ index: Int, _ id: Int64) -> UnsavedSidecarRecord {
        UnsavedSidecarRecord(photoPath: folderPath + "/" + files[index].filename, photoID: id,
                            stated: [.recipe, .strokes], generation: UUID().uuidString)
    }
    for index in 1...count {
        bareTimes.append(try timed { try bare.saveRecipe(recipes[index], photoID: bareIDs[index], isCurrent: true) })
        perTimes.append(try timed {
            _ = try perMutation.withSidecarIntent {
                try perMutation.saveRecipe(recipes[index], photoID: perIDs[index], isCurrent: true)
                return ((), [intent(index, perIDs[index])])
            }
        })
    }
    let batchTime = try timed {
        _ = try batch.withSidecarIntent {
            var intents: [UnsavedSidecarRecord] = []
            for index in 1...count {
                try batch.saveRecipe(recipes[index], photoID: batchIDs[index], isCurrent: true)
                intents.append(intent(index, batchIDs[index]))
            }
            return ((), intents)
        }
    }
    let perRaw = try perMutation.metaValue(UnsavedSidecarRecord.metaKey)!
    let batchRaw = try batch.metaValue(UnsavedSidecarRecord.metaKey)!
    for (store, ids, raw) in [(perMutation, perIDs, perRaw), (batch, batchIDs, batchRaw)] {
        let records = try UnsavedSidecarRecord.decodeValidated(raw)
        precondition(records.count == count && records.allSatisfy { $0.generation != nil && $0.statedFields == [.recipe, .strokes] })
        let saved = try store.currentRecipe(photoID: ids[count])!
        precondition(saved.develop.tone.exposure == recipes[count].develop.tone.exposure)
    }
    precondition(perRaw.utf8.count == batchRaw.utf8.count)
    let bareTotal: Double = bareTimes.reduce(0.0, +), perTotal: Double = perTimes.reduce(0.0, +)
    let bareLast: Double = bareTimes.suffix(40).reduce(0.0, +), perLast: Double = perTimes.suffix(40).reduce(0.0, +)
    print(String(format: "%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%d", count,
                 bareTotal, perTotal, batchTime, bareLast, perLast, batchTime / Double(count), batchRaw.utf8.count))
    bare.close(); perMutation.close(); batch.close()
}
