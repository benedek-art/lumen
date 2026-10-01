// SourceOpening.swift
// What a set of dropped, picked or Finder-opened URLs becomes.

import Foundation

/// The decisions behind `AppState.openSources`, kept here so they run (and are tested)
/// on every platform. The app supplies the filesystem facts — whether a URL is a
/// directory — and acts on the answer.
public enum SourceOpening {

    /// What an open request should do.
    public enum Plan: Equatable, Sendable {
        /// Nothing in the request is something Lumen can open: leave the roll that is on
        /// screen exactly as it is, remember nothing, and say so.
        case nothing
        /// One folder and nothing else: the plain folder open it has always been.
        case folder(URL)
        /// Supported photographs only: an explicit roll rooted at their common parent.
        case files(root: URL, files: Set<URL>)
        /// At least one directory among the sources. Expanding it is a recursive walk,
        /// which must happen off the main actor, and only its RESULT can say whether
        /// there is anything to open — so the roll on screen is not replaced until it
        /// has (`expansionOutcome`).
        case expand(root: URL, sources: Set<URL>)
    }

    /// - Parameters:
    ///   - extensions: lower-cased extensions Lumen can open.
    ///   - isDirectory: the filesystem's answer for a file URL.
    ///
    /// A URL that is not a file URL — a web link dropped on the window — is not a source
    /// at all (V7 D7: it used to close the open folder and open an empty roll rooted at
    /// the link's path, and remember that for the next launch). Nor is a file of a type
    /// Lumen cannot open.
    public static func plan(_ urls: [URL], extensions: Set<String>,
                            isDirectory: (URL) -> Bool) -> Plan {
        let local = urls.filter(\.isFileURL)
        let directories = local.filter(isDirectory)
        let photos = local.filter {
            !isDirectory($0) && extensions.contains($0.pathExtension.lowercased())
        }
        if directories.isEmpty && photos.isEmpty { return .nothing }
        if directories.count == 1 && photos.isEmpty { return .folder(directories[0]) }
        guard let root = commonParent(of: directories + photos, isDirectory: isDirectory)
        else { return .nothing }
        if directories.isEmpty { return .files(root: root, files: Set(photos)) }
        return .expand(root: root, sources: Set(directories + photos))
    }

    /// The deepest directory that contains every one of them. Nil only for an empty
    /// list — two paths on different volumes still share `/`.
    public static func commonParent(of urls: [URL], isDirectory: (URL) -> Bool) -> URL? {
        guard let first = urls.first else { return nil }
        var common = (isDirectory(first) ? first : first.deletingLastPathComponent())
            .standardizedFileURL.pathComponents
        for url in urls.dropFirst() {
            let parts = (isDirectory(url) ? url : url.deletingLastPathComponent())
                .standardizedFileURL.pathComponents
            var shared: [String] = []
            for (a, b) in zip(common, parts) {
                guard a == b else { break }
                shared.append(a)
            }
            common = shared
        }
        guard !common.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
    }

    /// What an `.expand` plan's walk found decides whether it opens anything at all.
    /// Nil means "Nothing there Lumen can open": the roll on screen stays.
    public static func expansionOutcome(root: URL, found: [URL]) -> Plan? {
        found.isEmpty ? nil : .files(root: root, files: Set(found))
    }

    /// What the launch reopens.
    public enum Relaunch: Equatable, Sendable {
        /// The last roll was a folder: reopen it.
        case folder
        /// The last roll was a picked set and these of its files are still there.
        case files(Set<URL>)
        /// The last roll was a picked set and NONE of it is left. Open nothing.
        case nothing
    }

    /// - Parameters:
    ///   - remembered: the paths of the last picked set, or empty when the last roll
    ///     was a plain folder.
    ///   - exists: the filesystem's answer for a path.
    ///
    /// A remembered selection whose every file is gone used to fall through to "no
    /// restriction", which opened the remembered ROOT unrestricted (V7 D6). That root is
    /// the common parent of the picked files, so for two frames from `~/Desktop` and
    /// `~/Downloads` it is the home folder, and for frames on two volumes it is `/`:
    /// a launch would recursively scan and register all of it. A selection that is gone
    /// opens nothing.
    public static func relaunch(remembered: [String], exists: (String) -> Bool) -> Relaunch {
        guard !remembered.isEmpty else { return .folder }
        let surviving = Set(remembered.filter(exists).map { URL(fileURLWithPath: $0) })
        return surviving.isEmpty ? .nothing : .files(surviving)
    }
}

/// Finder opens that arrive before there is anywhere to deliver them.
///
/// "Open With ▸ Lumen" on an app that is not running delivers `application(_:open:)`
/// during launch, before the window's `.onAppear` has handed the delegate its state.
/// The delegate used to call `state?.openSources(urls)` on nil, dropping the files
/// silently, and the launch then reopened the PREVIOUS folder instead (V7 D8). Opens
/// that arrive early are held here and handed over, in order, when the state attaches.
public struct LaunchOpenQueue: Equatable, Sendable {
    public private(set) var pending: [URL] = []
    public private(set) var isReady = false

    public init() {}

    /// An open arrived. Returns what to open NOW: the URLs when the state is attached,
    /// nothing while they are being held for it.
    public mutating func receive(_ urls: [URL]) -> [URL] {
        if isReady { return urls }
        pending.append(contentsOf: urls)
        return []
    }

    /// The state is attached. Returns everything held, once; later opens pass straight
    /// through `receive`.
    public mutating func attach() -> [URL] {
        isReady = true
        defer { pending = [] }
        return pending
    }
}
