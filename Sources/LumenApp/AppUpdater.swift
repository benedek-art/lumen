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
import CryptoKit
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
        hexValue(of: "commit:", inReleaseBody: body)
    }

    /// THE OTHER HALF OF THE CONTRACT: `sha256: <64 hex>`, the digest of the asset.
    ///
    /// This is the only identity check available to this app's updates, and the reason
    /// is in `scripts/build-app.sh`: the bundle is signed AD HOC (`codesign --sign -`),
    /// because an unsigned binary will not launch on Apple Silicon and there is no
    /// Developer ID to sign with. `codesign --verify --deep --strict` — which the
    /// installer runs and will keep running — answers "is this signature internally
    /// consistent with these contents". An ad-hoc signature made by ANYBODY passes it,
    /// so it proves the download is not corrupt and proves nothing about who built it.
    ///
    /// The only other check on the payload was a byte count taken from the same JSON
    /// that supplied the download URL, which is not a check at all. Whatever the feed
    /// served was moved over the running app and relaunched (L-03).
    ///
    /// 64 hex characters exactly, because a short one is a truncated line rather than a
    /// weaker digest, and this is the wrong place to be generous.
    static func digest(inReleaseBody body: String) -> String? {
        guard let value = hexValue(of: "sha256:", inReleaseBody: body),
              value.count == 64 else { return nil }
        return value.lowercased()
    }

    private static func hexValue(of key: String, inReleaseBody body: String) -> String? {
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix(key) else { continue }
            let value = trimmed.dropFirst(key.count)
                .trimmingCharacters(in: .whitespaces)
            let isHex = !value.isEmpty && value.allSatisfy(\.isHexDigit)
            return isHex ? value : nil
        }
        return nil
    }
}

// MARK: - The visible identity

/// The build stamp the Lumen menu shows (owner request, session C): the CI run
/// number is the human-readable "version", the commit is the identity the updater
/// actually compares, and the date answers "is this today's build?" at a glance.
/// Pure so LumenAppTests can pin the format; `current` reads the same Info.plist
/// keys `scripts/build-app.sh` seals (plus `LumenBuildNumber`, CI's run number).
enum BuildStamp {
    static func label(number: Int?, commit: String?, date: Date?,
                      timeZone: TimeZone = .current) -> String {
        guard let commit, commit.count >= 7 else {
            return "Development build — no update stamp"
        }
        var parts: [String] = []
        if let number { parts.append("\(number)") }
        parts.append(String(commit.prefix(7)))
        if let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "MMM d, yyyy, HH:mm"
            parts.append(formatter.string(from: date))
        }
        return "Build " + parts.joined(separator: " · ")
    }

    static var current: String {
        let info = Bundle.main
        return label(
            number: (info.object(forInfoDictionaryKey: "LumenBuildNumber") as? NSNumber)?
                .intValue,
            commit: info.object(forInfoDictionaryKey: "LumenBuildCommit") as? String,
            date: (info.object(forInfoDictionaryKey: "LumenBuildDate") as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) })
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
            if interactive {
                inform("Lumen is up to date",
                       "You're on the newest build — \(BuildStamp.current).")
            }
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
            // FAILS CLOSED. A release body with no `sha256:` line cannot be installed,
            // and that is deliberate: the alternative — verify it if present — leaves an
            // attacker who can shape the feed the option of simply omitting the line.
            // CI publishes the digest on every release (`ci.yml`), so the only body
            // without one is a body this project did not write.
            guard let digest = release.body.flatMap(UpdateDecision.digest(inReleaseBody:))
            else {
                if interactive {
                    inform("The release feed didn't say what to expect",
                           "The dev-latest release body is missing its `sha256:` line, "
                           + "so there is no way to check that the download is the "
                           + "build CI made. Nothing was installed.")
                }
                return
            }
            await install(asset: asset, commit: remoteCommit ?? "?", digest: digest)
        }
    }

    /// Download → verify → extract → verify → swap → offer relaunch. Every failure
    /// leaves the running app untouched.
    private func install(asset: Release.Asset, commit: String, digest: String) async {
        do {
            let (tempFile, _) = try await URLSession.shared
                .download(from: asset.browser_download_url)
            try await UpdateFileWork.verifyDownload(tempFile, expectedSize: asset.size, digest: digest)
            let current = Bundle.main.bundleURL
            try await UpdateFileWork.withScratch { work in
                // Ditto for the same reason CI zips with it: it preserves the signature.
                try await run("/usr/bin/ditto", "-x", "-k", tempFile.path, work.path)
                let newApp = work.appendingPathComponent("Lumen.app")
                guard FileManager.default.fileExists(
                    atPath: newApp.appendingPathComponent("Contents/MacOS/Lumen").path)
                else { throw UpdateError("the archive doesn't contain a runnable Lumen.app") }
                // Kept, and worth being precise about what it is worth: this proves the
                // extracted bundle's signature is internally consistent with its contents,
                // which catches a truncated or tampered EXTRACTION. It proves nothing about
                // who signed it — these builds are ad-hoc signed, so an ad-hoc signature
                // made by anybody satisfies it. The digest above is the identity check.
                try await run("/usr/bin/codesign", "--verify", "--deep", "--strict", newApp.path)

                // THE INSTALLED BUNDLE IS NEVER MOVED OUT OF THE WAY (L-04).
                //
                // It used to be: move `current` to a backup, move the new one into its
                // place, and on failure `try?` the old one back. Three things were wrong
                // with that, and the third is the one that would have hurt.
                //
                // The backup lived in `FileManager.temporaryDirectory` while `current`
                // lives wherever the app is installed, so BOTH moves were cross-volume
                // whenever those differ — cross-volume moves are copy-then-delete, not
                // renames, and they fail for ordinary reasons like space. The rollback was
                // `try?`, so its failure was discarded. And the handler it threw into told
                // the photographer "The running build is untouched" and suggested
                // rebuilding from source — on the one path where the installed app had
                // been moved away and nothing had replaced it. An alert asserting the
                // opposite of the truth, then a Finder with no Lumen in it.
                //
                // `replaceItemAt` is the API for this and it leaves the original in place
                // when it fails, so "untouched" is now true by construction rather than by
                // assertion. It is atomic only WITHIN a volume, which is why the new bundle
                // is staged beside the installed one first: the copy is the part that can
                // fail slowly and it happens before anything is at risk.
                try await UpdateFileWork.replaceBundle(newApp, current: current)
            }

            let alert = NSAlert()
            alert.messageText = "Updated to build \(String(commit.prefix(12)))"
            alert.informativeText = "The new build takes over when Lumen relaunches."
            alert.addButton(withTitle: "Relaunch Now")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                do {
                    try await UpdateRelaunch.perform(open: {
                        _ = try await NSWorkspace.shared.openApplication(at: current,
                                                                        configuration: config)
                    }, terminate: { NSApp.terminate(nil) })
                } catch {
                    inform("The update installed, but relaunch failed",
                           "\(error.localizedDescription)\n\nLumen is still running. "
                               + "Quit and open Lumen again to use the installed update.")
                }
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

    /// Run a tool and wait for it WITHOUT blocking the main actor (K-034).
    ///
    /// This class is `@MainActor`, and the wait was `waitUntilExit()` — so `ditto` over
    /// the whole archive and a deep `codesign --verify` of every nested binary froze the
    /// window for as long as they took, with nothing bounding either. The wait is now a
    /// suspension: the process reports through `terminationHandler`, the main actor
    /// keeps drawing, and the install continues where it left off.
    private func run(_ tool: String, _ arguments: String...) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed "
                + "(exit \(status))")
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
