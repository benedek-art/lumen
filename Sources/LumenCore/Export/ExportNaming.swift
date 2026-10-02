// ExportNaming.swift
// The export filename grammar (docs/11 §Naming), in LumenCore so it can be tested.
//
// It lived in `AppState.renderFilename`, which took a URL and a recipe name and nothing
// else, so it could not know when a photograph was taken or where it sat in the batch.
// Two findings came out of that (docs/audit-2026-09/w2/J3.md):
//
// J3-05. `{date}` was the FILE's creation date — the day the card was copied, the day an
// archive was restored, or today for a file with no readable attributes — while the
// ingest renamer's `{date}` is the capture date. One token name, two different days.
//
// J3-08. There was no sequence token, so a template without `{name}` (`{date}` for a
// client who wants dated files) gave a whole batch one base name, and the collision
// guard numbered the pile `-1`, `-2` … in whatever order the selection held.
//
// The tokens that existed render exactly as they did — `{name}`, `{recipe}`, `{ext}`,
// and `{date}` in the `yyyy-MM-dd` form the export side has always used — except that
// `{date}` now reads the capture time first. Everything else docs/11 lists is added
// with the ingest renamer's spelling where the two overlap (`{seq}` is four digits and
// `{seq:N}` is N, as `RenameTemplate` renders them), so one template means one thing in
// both homes. An unknown token is still left in the name, braces and all: a delivered
// file called `{whatever}.jpg` tells the photographer what went wrong, and an empty
// substitution would not.

import Foundation

/// Everything a template can ask about one delivered file.
public struct ExportNamingContext: Sendable, Equatable {
    /// The original file; `{name}` is its basename, `{ext}` its extension.
    public var source: URL
    public var recipeName: String
    /// The camera's wall clock when the shutter fired, as EXIF states it — components,
    /// not an instant, for the reason `RenameContext` gives: a photograph does not
    /// change the day it was taken because the laptop that exports it flew.
    public var captureDate: DateComponents?
    /// The fallback the export side always used: the file's creation date, read in the
    /// machine's zone. Only consulted when there is no capture date.
    public var fileDate: DateComponents?
    public var camera: String?
    public var lens: String?
    public var iso: Int?
    public var rating: Int?
    public var label: String?
    /// The 1-based position of this PHOTO in the batch, offset by the recipe's
    /// sequence start. Every recipe of one photo shares it, so the client JPEG and the
    /// archive TIFF of frame 12 are both `…0012`.
    public var sequence: Int

    public init(source: URL, recipeName: String, captureDate: DateComponents? = nil,
                fileDate: DateComponents? = nil, camera: String? = nil,
                lens: String? = nil, iso: Int? = nil, rating: Int? = nil,
                label: String? = nil, sequence: Int = 1) {
        self.source = source
        self.recipeName = recipeName
        self.captureDate = captureDate
        self.fileDate = fileDate
        self.camera = camera
        self.lens = lens
        self.iso = iso
        self.rating = rating
        self.label = label
        self.sequence = sequence
    }
}

public enum ExportNaming {

    /// Every token this renderer substitutes, `{seq:N}` aside.
    public static let knownTokens: Set<String> = [
        "name", "recipe", "ext",
        "date", "time", "yyyy", "mm", "dd", "year", "month", "day", "hour", "minute",
        "seq", "seq3", "seq4",
        "camera", "lens", "iso", "rating", "label",
    ]

    /// The tokens the sheet lists, in the order it lists them.
    public static let documentedTokens = [
        "{name}", "{seq}", "{seq:N}", "{date}", "{time}", "{yyyy}", "{mm}", "{dd}",
        "{camera}", "{lens}", "{iso}", "{rating}", "{label}", "{recipe}", "{ext}",
    ]

    /// Render a template to a usable basename — never empty, never `.` or `..`, never a
    /// path. The fallbacks are the ones `AppState.renderFilename` already applied (J3-02):
    /// the source's own name, then "Untitled".
    public static func render(template: String, context: ExportNamingContext) -> String {
        let name = context.source.deletingPathExtension().lastPathComponent
        let effective = template.isEmpty ? "{name}" : template
        var out = ""
        var rest = Substring(effective)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else {
                out += rest[open...]
                rest = ""
                break
            }
            let token = String(rest[afterOpen..<close])
            out += expand(token, context: context, name: name) ?? "{" + token + "}"
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        // The two filesystem-hostile characters the export side has always mapped —
        // and only those, so a template that rendered a name before renders the same
        // name now. (`RenameTemplate.sanitize` also collapses runs of spaces; doing that
        // here would rename existing deliveries.)
        let rendered = out.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return RenameTemplate.usableBasename(rendered)
            ?? RenameTemplate.usableBasename(name)
            ?? "Untitled"
    }

    /// Tokens the template uses that this renderer does not know — what the sheet
    /// shows beside the preview so a typo is caught before the run, not after.
    public static func unknownTokens(in template: String) -> [String] {
        RenameTemplate.tokens(in: template).filter { token in
            !knownTokens.contains(token) && seqWidth(token) == nil
        }
    }

    /// Whether the template, on its own, gives every photo of a batch its own name.
    ///
    /// `{name}` does (two frames that share a basename are the collision guard's job,
    /// and it is a rare one); a sequence token does by construction. Anything else —
    /// a date, a camera, a recipe name — is shared by every frame shot that day on that
    /// body, and the batch is then told apart only by `-1`, `-2` … suffixes in no
    /// meaningful order. The sheet warns on this before the run (J3-08).
    public static func identifiesEachPhoto(_ template: String) -> Bool {
        let tokens = RenameTemplate.tokens(in: template.isEmpty ? "{name}" : template)
        return tokens.contains { $0 == "name" || isSequence($0) }
    }

    /// Whether the template reads the sequence at all — when the sheet shows Start at.
    public static func usesSequence(_ template: String) -> Bool {
        RenameTemplate.tokens(in: template).contains(where: isSequence)
    }

    /// How many distinct base names `contexts` produce — the measured form of
    /// `identifiesEachPhoto`, for a selection the caller can describe.
    public static func distinctNames(template: String,
                                     contexts: [ExportNamingContext]) -> Int {
        Set(contexts.map { render(template: template, context: $0) }).count
    }

    // MARK: - internals

    static func isSequence(_ token: String) -> Bool {
        token == "seq" || token == "seq3" || token == "seq4" || seqWidth(token) != nil
    }

    /// `{seq:N}`, N in 1…9 — `RenameTemplate`'s rule, so the two homes agree.
    static func seqWidth(_ token: String) -> Int? {
        guard let width = RenameTemplate.seqWidth(of: token), (1...9).contains(width)
        else { return nil }
        return width
    }

    static func expand(_ token: String, context: ExportNamingContext,
                       name: String) -> String? {
        let date = context.captureDate ?? context.fileDate
        func pad(_ value: Int?, _ width: Int) -> String? {
            guard let value else { return nil }
            return String(format: "%0\(width)d", value)
        }
        func sequence(_ width: Int) -> String {
            String(format: "%0\(width)d", Swift.max(context.sequence, 0))
        }
        func text(_ value: String?) -> String {
            value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        switch token {
        case "name": return name
        case "recipe": return context.recipeName
        case "ext": return context.source.pathExtension
        case "date":
            guard let y = pad(date?.year, 4), let m = pad(date?.month, 2),
                  let d = pad(date?.day, 2) else { return "" }
            return y + "-" + m + "-" + d
        case "time":
            guard let h = pad(date?.hour, 2), let m = pad(date?.minute, 2) else { return "" }
            return h + m + (pad(date?.second, 2) ?? "00")
        case "yyyy", "year": return pad(date?.year, 4) ?? ""
        case "mm", "month": return pad(date?.month, 2) ?? ""
        case "dd", "day": return pad(date?.day, 2) ?? ""
        case "hour": return pad(date?.hour, 2) ?? ""
        case "minute": return pad(date?.minute, 2) ?? ""
        case "seq", "seq4": return sequence(4)
        case "seq3": return sequence(3)
        case "camera": return text(context.camera)
        case "lens": return text(context.lens)
        case "iso": return context.iso.map(String.init) ?? ""
        case "rating": return context.rating.map(String.init) ?? ""
        case "label": return text(context.label)
        default:
            if let width = seqWidth(token) { return sequence(width) }
            return nil
        }
    }
}

extension PhotoMetadata {

    /// EXIF's `2026:08:20 14:55:35` as the wall-clock components it states, with no
    /// zone applied — what a filename token wants. `parseEXIFDate` turns the same text
    /// into an instant for sorting; the two read the six fields identically.
    public static func parseEXIFDateComponents(_ text: String) -> DateComponents? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "-" })
        guard parts.count >= 6 else { return nil }
        let numbers = parts.prefix(6).compactMap { Int($0) }
        guard numbers.count == 6,
              (1900...9999).contains(numbers[0]), (1...12).contains(numbers[1]),
              (1...31).contains(numbers[2]), (0...23).contains(numbers[3]),
              (0...59).contains(numbers[4]), (0...61).contains(numbers[5])
        else { return nil }
        var components = DateComponents()
        components.year = numbers[0]
        components.month = numbers[1]
        components.day = numbers[2]
        components.hour = numbers[3]
        components.minute = numbers[4]
        components.second = numbers[5]
        return components
    }
}
