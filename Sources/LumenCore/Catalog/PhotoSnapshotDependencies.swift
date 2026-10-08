import Foundation

/// Snapshot payloads use the catalog's existing content-addressed shelf and backups.
/// Read actual disk bytes: a warm render cache must not hide a missing/corrupt blob.
public enum PhotoSnapshotDependencies {
    public static func validate(_ recipe: Recipe, blobs: BlobStore) throws {
        let json = try CanonicalJSON.canonicalRecipeJSON(recipe)
        var references = Set<String>()
        var strokes = Set<String>()
        var luts = Set<String>()
        func collect(_ value: Any) {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    if key == "strokesRef", let ref = child as? String, !ref.isEmpty {
                        references.insert(ref)
                        strokes.insert(ref)
                    } else if key == "lut", let lut = child as? [String: Any],
                              let ref = lut["ref"] as? String, ref.hasPrefix("blob:") {
                        references.insert(ref)
                        luts.insert(ref)
                    } else { collect(child) }
                }
            } else if let array = value as? [Any] { array.forEach(collect) }
        }
        collect(try JSONSerialization.jsonObject(with: Data(json.utf8)))
        for ref in references.sorted() {
            guard let url = blobs.url(for: ref), let data = try? Data(contentsOf: url),
                  BrushStrokeSet.blobRef(for: data) == ref else {
                throw CatalogError.invalid("snapshot payload is missing or damaged: \(ref)")
            }
            if luts.contains(ref), CreativeLUTImport.parse(data) == nil {
                throw CatalogError.invalid("snapshot LUT cannot be decoded: \(ref)")
            }
            if strokes.contains(ref) {
                let painting = try BrushStrokeSet.decode(data)
                guard painting.version <= BrushStrokeSet.schemaVersion else {
                    throw CatalogError.invalid("snapshot painting requires a newer build")
                }
            }
        }
    }
}
