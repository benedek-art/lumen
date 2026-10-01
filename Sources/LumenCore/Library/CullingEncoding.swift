// CullingEncoding.swift
// The two culling vocabularies' ON-DISK spellings, in the one module that can test them.
//
// There is one `PhotoFlag` and one `ColorLabel` now (both in `CatalogStore.swift`).
// LumenApp used to declare a second pair — `rejected`/`none`/`picked` over the same Int
// raw values, and a six-case `ColorLabel: Int` whose `.none = 0` meant "unlabelled" — and
// `CatalogService.coreFlag`/`appFlag`/`coreLabel`/`appLabel` translated between them on
// every read and write. Those were identity functions with somewhere to go wrong, and
// they lived behind `#if os(macOS)` where no test on this lane could reach them.
//
// What is left is not a synonym table but two genuine encodings, and they are the
// contract with every catalog and sidecar already on disk:
//
//   · catalog `photo.flag`   — `PhotoFlag.rawValue`: -1 reject, 0 unflagged, 1 pick.
//   · catalog `photo.label`  — `ColorLabel.rawValue` ("red" … "purple"), NULL unlabelled.
//   · sidecar `lumen:flag`   — `SidecarFlag.rawValue`: "reject", "none", "pick".
//   · sidecar `xmp:Label`    — the same lowercase name as the catalog column.
//
// `CullingEncodingTests` pins every one of those spellings against literals copied from
// the code this replaced, so a rename here cannot quietly re-key a photographer's culls.

import Foundation

extension ColorLabel {
    /// Read a label name as the catalog column or an XMP sidecar spells it.
    ///
    /// Case-insensitive, because a sidecar another tool wrote may say "Green" where
    /// Lumen writes "green" — which is what the deleted `CatalogService.appLabel` did by
    /// lowercasing before it compared. Nil for no name, for an empty one, and for a name
    /// this build has no colour for ("orange", or the old app enum's own "none"): all of
    /// those are "unlabelled" to the grid, exactly as they were.
    public init?(storedName: String?) {
        guard let name = storedName?.lowercased() else { return nil }
        self.init(rawValue: name)
    }
}

extension SidecarFlag {
    /// The flag as `lumen:flag` writes it. Total in both directions: the sidecar's three
    /// words and the catalog's three integers are the same three decisions.
    public init(_ flag: PhotoFlag) {
        switch flag {
        case .pick: self = .pick
        case .reject: self = .reject
        case .unflagged: self = .none
        }
    }
}

extension PhotoFlag {
    /// The flag a sidecar's `lumen:flag` states.
    public init(_ flag: SidecarFlag) {
        switch flag {
        case .pick: self = .pick
        case .reject: self = .reject
        case .none: self = .unflagged
        }
    }
}
