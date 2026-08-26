// AppUpdater.swift
// The ship-to-self loop's last mile (docs/23 standing loop 5): every green push
// publishes a rolling `dev-latest` release, and an installed Lumen replaces itself
// from it — the owner opens the app, not a terminal.
//
// Two halves, deliberately split: `UpdateDecision` is pure logic LumenAppTests can
// pin (what counts as newer, what a malformed release means); `AppUpdater` is the
// plumbing (fetch, download, verify, swap, relaunch), each step defensive because a
// failed update must degrade to "still running the old build", never to a broken
// bundle. The release asset needs NO auth — that is why this reads a release and not
// an Actions artifact — and the download is performed by the app itself, so macOS
// attaches no quarantine and Gatekeeper stays out of the update path; only the very
// first install (which travels through a browser or scp) needs the one-time xattr.

#if os(macOS)

import AppKit
import Foundation

// MARK: - The decision, as data

enum UpdateDecision: Equatable {
    /// The installed build IS the released one.
    case upToDate
    /// A different, newer build is available.
    case update
    /// The release is OLDER than this build — a locally built app ahead of CI, or
    /// CI still baking. Never downgrade silently.
    case ownIsNewer
    /// This build carries no stamp (swift run, a hand-rolled bundle) or the release
    /// is malformed. The updater does nothing, quietly.
    case unknown

    static func decide(ownCommit: String?, ownBuildDate: Date?,
                       remoteCommit: String?, remotePublishedAt: Date?) -> UpdateDecision {
        guard let own = ownCommit?.lowercased(), own.count >= 7,
              let remote = remoteCommit?.lowercased(), remote.count >= 7 else {
            return .unknown
        }
        if own.hasPrefix(remote) || remote.hasPrefix(own) { return .upToDate }
        if let ownDate = ownBuildDate, let remoteDate = remotePublishedAt,
           remoteDate <= ownDate {
            return .ownIsNewer
        }
        return .update
    }

    /// The release body's contract: a line reading `commit: <hex>`. Anything else in
    /// the body is prose for humans.
    static func commit(inReleaseBody body: String) -> String? {
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("commit:") else { continue }
            let value = trimmed.dropFirst("commit:".count)
                .trimmingCharacters(in: .whitespaces)
            let isHex = !value.isEmpty && value.allSatisfy(\.isHexDigit)
            return isHex ? value : nil
        }
        return nil
    }
}

// MARK: - The plumbing

@MainActor
final class AppUpdater {

    static let shared = AppUpdater()
    private init() {}

    private static let releaseAPI = URL(string:
        "https://api.github.com/repos/benedek-art/lumen/releases/tags/dev-latest")!

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
        }
        let body: String?
        let published_at: String?
        let assets: [Asset]
    }

    private var busy = false

    /// The stamps `scripts/build-app.sh` seals into Info.plist.
    private var ownCommit: String? {
        Bundle.main.object(forInfoDictionaryKey: "LumenBuildCommit") as? String
    }
    private var ownBuildDate: Date? {
        (Bundle.main.object(forInfoDictionaryKey: "LumenBuildDate") as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    /// Launch-time check: silent unless there is genuinely something to do.
    func checkQuietly() async {
        await check(interactive: false)
    }

    /// Menu-driven check: reports every outcome, including "you're current".
    func check(interactive: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        guard ownCommit != nil else {
            if interactive {
                inform("This build carries no update stamp",
                       "Development builds (swift run, hand-rolled bundles) don't "
                           + "self-update. Installed CI builds do.")
            }
            return
        }

        let release: Release
        do {
            var request = URLRequest(url: Self.releaseAPI)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            if interactive {
                inform("Couldn't reach the release feed",
                       "\(error.localizedDescription)")
            }
            return
        }

        let remoteCommit = release.body.flatMap(UpdateDecision.commit(inReleaseBody:))
        let publishedAt = release.published_at
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        let decision = UpdateDecision.decide(ownCommit: ownCommit,
                                             ownBuildDate: ownBuildDate,
                                             remoteCommit: remoteCommit,
                                             remotePublishedAt: publishedAt)
        switch decision {
        case .upToDate:
            if interactive { inform("Lumen is up to date", "You're on the newest build.") }
        case .ownIsNewer:
            if interactive {
                inform("This build is newer than the release",
                       "You're ahead of CI — probably a local build. Nothing to do.")
            }
        case .unknown:
            if interactive {
                inform("The release feed didn't say which commit it is",
                       "The dev-latest release body is missing its `commit:` line.")
            }
        case .update:
            guard let asset = release.assets.first(where: { $0.name == "Lumen.app.zip" })
            else {
                if interactive {
                    inform("The release has no app in it",
                           "dev-latest exists but carries no Lumen.app.zip.")
                }
                return
            }
            await install(asset: asset, commit: remoteCommit ?? "?")
        }
    }

    /// Download → verify → extract → verify → swap → offer relaunch. Every failure
    /// leaves the running app untouched.
    private func install(asset: Release.Asset, commit: String) async {
        do {
            let (tempFile, _) = try await URLSession.shared
                .download(from: asset.browser_download_url)
            let attrs = try FileManager.default.attributesOfItem(atPath: tempFile.path)
            guard (attrs[.size] as? Int) == asset.size else {
                throw UpdateError("the download's size doesn't match the release's")
            }

            let work = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lumen-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work,
                                                    withIntermediateDirectories: true)
            // Ditto for the same reason CI zips with it: it preserves the signature.
            try run("/usr/bin/ditto", "-x", "-k", tempFile.path, work.path)
            let newApp = work.appendingPathComponent("Lumen.app")
            guard FileManager.default.fileExists(
                atPath: newApp.appendingPathComponent("Contents/MacOS/Lumen").path)
            else { throw UpdateError("the archive doesn't contain a runnable Lumen.app") }
            try run("/usr/bin/codesign", "--verify", "--deep", "--strict", newApp.path)

            let current = Bundle.main.bundleURL
            let backup = work.appendingPathComponent("Lumen-previous.app")
            try FileManager.default.moveItem(at: current, to: backup)
            do {
                try FileManager.default.moveItem(at: newApp, to: current)
            } catch {
                // Roll the old bundle back before surfacing anything.
                try? FileManager.default.moveItem(at: backup, to: current)
                throw error
            }

            let alert = NSAlert()
            alert.messageText = "Updated to build \(String(commit.prefix(12)))"
            alert.informativeText = "The new build takes over when Lumen relaunches."
            alert.addButton(withTitle: "Relaunch Now")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                try? await NSWorkspace.shared.openApplication(at: current,
                                                              configuration: config)
                NSApp.terminate(nil)
            }
        } catch {
            inform("The update didn't install",
                   "\(error.localizedDescription)\n\nThe running build is untouched; "
                       + "you can update manually with git pull + scripts/build-app.sh.")
        }
    }

    private struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed "
                + "(exit \(process.terminationStatus))")
        }
    }

    private func inform(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

#endif
