import Dispatch
import Foundation
import LumenCore

func nanoseconds(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    return Double(DispatchTime.now().uptimeNanoseconds - start)
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-intent-scaling-\(UUID())")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let baseline = try CatalogStore(path: root.appendingPathComponent("bare.db").path)
let journal = try CatalogStore(path: root.appendingPathComponent("intent.db").path)
defer { baseline.close(); journal.close() }
let folderPath = "/synthetic/public-fixture"
let files = (0...1000).map { i in
    ScannedFile(filename: String(format: "frame%06d.ARW", i), fileSize: 1, fileMTime: 1, ext: "arw")
}
func seed(_ store: CatalogStore) throws -> [Int64] {
    let folder = try store.registerFolder(path: folderPath)
    _ = try store.scan(folderID: folder, files: files)
    return try files.map { file in try store.photo(folderID: folder, filename: file.filename)!.id }
}
let baselineIDs = try seed(baseline)
let journalIDs = try seed(journal)
// Warm the recipe-save implementation/SQLite pages identically outside timing.
try baseline.saveRecipe(Recipe(), photoID: baselineIDs[0], isCurrent: true)
try journal.saveRecipe(Recipe(), photoID: journalIDs[0], isCurrent: true)
var baselineTimes: [Double] = [], journalTimes: [Double] = []
let overallStart = DispatchTime.now().uptimeNanoseconds
print("pending\tbare_total_ms\tintent_total_ms\tbare_last40_ms\tintent_last40_ms\tbare_last40_per_op_ms\tintent_last40_per_op_ms\tintent_json_bytes")
for index in 1...1000 {
    if index == 501 && journalTimes.reduce(0, +) / 1e9 > 20 {
        print("1000 skipped: accumulating 500 journal mutations already exceeded 20 seconds")
        break
    }
    var recipe = Recipe(); recipe.develop.tone.exposure = Double(index % 31) / 20.0
    baselineTimes.append(try nanoseconds {
        try baseline.saveRecipe(recipe, photoID: baselineIDs[index], isCurrent: true)
    })
    journalTimes.append(try nanoseconds {
        _ = try journal.withSidecarIntent {
            try journal.saveRecipe(recipe, photoID: journalIDs[index], isCurrent: true)
            return ((), [UnsavedSidecarRecord(
                photoPath: folderPath + "/" + files[index].filename, photoID: journalIDs[index],
                stated: [.recipe, .strokes], generation: UUID().uuidString)])
        }
    })
    if [40, 200, 500, 1000].contains(index) {
        let raw = try journal.metaValue(UnsavedSidecarRecord.metaKey)!
        let records = try UnsavedSidecarRecord.decodeValidated(raw)
        precondition(records.count == index)
        precondition(records.allSatisfy { $0.generation != nil && $0.statedFields == [.recipe, .strokes] })
        let saved = try journal.currentRecipe(photoID: journalIDs[index])!
        precondition(saved.develop.tone.exposure == recipe.develop.tone.exposure)
        let baselineDebt = try baseline.metaValue(UnsavedSidecarRecord.metaKey)
        precondition(baselineDebt == nil)
        let baselineTotal: Double = baselineTimes.reduce(0.0, +)
        let journalTotal: Double = journalTimes.reduce(0.0, +)
        let baselineLast: Double = baselineTimes.suffix(40).reduce(0.0, +)
        let journalLast: Double = journalTimes.suffix(40).reduce(0.0, +)
        let values = [baselineTotal, journalTotal, baselineLast, journalLast]
        let ms = values.map { $0 / 1e6 }
        print(String(format: "%d\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%d", index,
                     ms[0], ms[1], ms[2], ms[3], ms[2] / 40, ms[3] / 40, raw.utf8.count))
    }
}
print(String(format: "overall_wall_seconds=%.3f", Double(DispatchTime.now().uptimeNanoseconds - overallStart) / 1e9))
