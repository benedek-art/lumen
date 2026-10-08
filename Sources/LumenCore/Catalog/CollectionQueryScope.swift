import Foundation

/// The photo universe of a saved query. Nil database scope retains the original
/// current-folder behavior; malformed or unavailable explicit scopes never widen.
public enum CollectionQueryScope: Equatable, Sendable {
    case currentFolder
    case everywhere
    case folderSubtree(Int64)
    case album(Int64)
    case deletedAlbum(Int64)

    public init(stored: String?, id: Int64?) throws {
        switch (stored, id) {
        case (nil, nil), ("current-folder"?, nil): self = .currentFolder
        case ("everywhere"?, nil): self = .everywhere
        case ("folder-subtree"?, let id?) where id > 0: self = .folderSubtree(id)
        case ("album"?, let id?) where id > 0: self = .album(id)
        case ("deleted-album"?, let id?) where id > 0: self = .deletedAlbum(id)
        default: throw CatalogError.invalid("unsupported smart album scope")
        }
    }
    public var storedName: String? {
        switch self {
        case .currentFolder: return nil
        case .everywhere: return "everywhere"
        case .folderSubtree: return "folder-subtree"
        case .album: return "album"
        case .deletedAlbum: return "deleted-album"
        }
    }
    public var storedID: Int64? {
        switch self { case .folderSubtree(let id), .album(let id), .deletedAlbum(let id): return id; default: return nil }
    }
    public var label: String {
        switch self {
        case .currentFolder: return "Current folder"
        case .everywhere: return "Entire catalog"
        case .folderSubtree: return "Folder and subfolders"
        case .album: return "Manual album"
        case .deletedAlbum: return "Deleted manual album"
        }
    }
}
