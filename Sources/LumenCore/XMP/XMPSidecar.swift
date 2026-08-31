// XMPSidecar.swift
// XMP sidecar read/write (docs/15 §15.5): standard interoperable fields plus the
// lumen: namespace carrying the full recipe. Written atomically, debounced, always
// off the input path — the writer here only produces/consumes the bytes.
//
// Interop contract:
//  - xmp:Rating and xmp:Label are standard; LR/C1/exiftool read them.
//  - lumen:recipe holds canonical sparse recipe JSON (docs/15 refuses crs:* on purpose).
//  - Writing is string-templated (deterministic output); reading uses XMLParser,
//    which exists on both macOS (Foundation) and Linux (FoundationXML).

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Pick / reject, as the sidecar carries it.
///
/// Written as `lumen:flag` rather than by overloading `xmp:Rating = -1`, which is
/// Lightroom's convention. Lumen keeps flag and rating as separate axes — a photo can
/// be four stars AND rejected — so writing −1 into the rating would destroy one of
/// them on the way out and on the way back.
public enum SidecarFlag: String, Equatable, Sendable {
    case none, pick, reject
}

public struct SidecarContent: Equatable, Sendable {
    public var rating: Int          // 0…5
    /// The culling decision. Without this in the sidecar, a folder's picks and
    /// rejects existed ONLY in the catalog — so "losing the catalog costs speed,
    /// never work" was false for the one decision the app is built around.
    public var flag: SidecarFlag
    public var label: String?       // color label name
    public var pipelineVersion: Int
    public var recipeFingerprint: String?
    public var recipeJSON: String?  // canonical sparse recipe JSON
    /// Base64 of `ref → BrushStrokeSet`, so brush masks survive the catalog.
    ///
    /// Without it the sidecar carried a brush component's `strokesRef` and nothing the
    /// reference pointed AT, because the blob store lives in the catalog. Restore a
    /// sidecar without that store and every brush mask rasterized empty, forever, with
    /// nothing on screen saying so. See `BrushStrokeSidecar`.
    public var strokesPayload: String?
    public var catalogUUID: String?
    public var writeStamp: String?  // ISO 8601

    /// WHETHER THE WHOLE DOCUMENT PARSED, and it is a safety interlock rather than a
    /// diagnostic.
    ///
    /// `parse` salvages partial reads on purpose — a truncated sidecar that yielded a
    /// rating is better recovered than dropped. That is right for READING and dangerous
    /// for WRITING, because the writer seeds its pending content from the read and
    /// `XMPMerge` strips every Lumen-owned element before re-emitting the fields it was
    /// given. A field the parse never reached is therefore DELETED from the file.
    ///
    /// The reachable case: a `.xmp` damaged below its rating element (a crash during
    /// someone else's write, a partial sync). Press `3` on that frame during a cull and
    /// Lumen rewrites the file with the rating — and the intact `<lumen:recipe>` further
    /// down is gone. The catalog still has it, so nothing looks wrong; the RECOVERY COPY
    /// is what was destroyed, which is the only thing that copy is for.
    ///
    /// Defaults to true so a `SidecarContent` the app builds itself — which is every
    /// caller but `parse` — is writable without saying so.
    public var parsedCleanly: Bool

    public init(rating: Int = 0, flag: SidecarFlag = .none, label: String? = nil,
                pipelineVersion: Int = currentPipelineVersion,
                recipeFingerprint: String? = nil, recipeJSON: String? = nil,
                strokesPayload: String? = nil,
                catalogUUID: String? = nil, writeStamp: String? = nil,
                parsedCleanly: Bool = true) {
        self.rating = rating
        self.flag = flag
        self.label = label
        self.pipelineVersion = pipelineVersion
        self.recipeFingerprint = recipeFingerprint
        self.recipeJSON = recipeJSON
        self.strokesPayload = strokesPayload
        self.catalogUUID = catalogUUID
        self.writeStamp = writeStamp
        self.parsedCleanly = parsedCleanly
    }
}

/// Reconciling what the catalog knows with what the sidecar says.
///
/// The promise this exists to keep is "losing the catalog costs speed, never work"
/// (docs/15 §15.5): every recipe, rating, flag and label lands in both places, so a
/// photo that arrives from another machine, or a catalog restored from an older
/// backup, comes back with its work attached.
///
/// Separated from `CatalogService` — which owns the file read, the serial queue and the
/// debounce — because the RULE is pure, and `LumenApp` has no test target.
///
/// The rule used to be one sentence: the sidecar fills in where the catalog is silent,
/// and never overwrites it. That is docs/15 §15.5's rule 1, mistaken for the whole
/// policy, and it is wrong in exactly one direction — the one that loses work. Edit a
/// frame on a second Mac, or restore a sidecar from Time Machine, and the newer recipe
/// was ignored because this machine's catalog held an older one; the next edit here then
/// flushed the STALE recipe back over the sidecar. The one copy that exists to survive
/// losing the catalog was overwritten by the catalog.
///
/// The three rules, evaluated against `photo.sidecar_mtime` — the sidecar's mtime as of
/// our last write of it or our last read of it:
///
/// 1. Sidecar unchanged since we last touched it → catalog wins, filling in where it is
///    silent. The normal case, and the right way round: the catalog is what the running
///    app just edited, while the sidecar may be seconds stale behind its debounce.
/// 2. Sidecar newer than our last write AND its recipe fingerprint differs → the sidecar
///    wins. This is what makes restore-from-Time-Machine and edit-on-another-Mac work.
/// 3. Both changed — the catalog has edits that have not reached the sidecar yet, and
///    the sidecar moved underneath us → catalog wins, and the spec preserves the
///    sidecar's state as a snapshot named "Imported from sidecar <date>".
///
/// **Rule 3's snapshot is NOT implemented, and this type says so rather than pretending
/// otherwise.** Snapshots do not exist anywhere yet (LIB-06: `saveRecipe` only ever
/// writes `kind = .working`), so the sidecar's divergent state is reported back in
/// `Resolution.unpreservedSidecar` and nothing stores it. §15.5's "nothing is ever
/// silently discarded" does not hold for that case today; what this type can guarantee
/// is that the discard is not SILENT.
///
/// Two boundaries worth naming, because a value that crosses one without its unit is how
/// this codebase has been bitten before:
///
///  - `sidecarMTime` on both sides is whole seconds since the epoch, the same
///    denomination `photo.file_mtime` uses and the same one `FileManager` yields.
///  - Both fingerprints are `RecipeFingerprint.fingerprint` — the RENDER IDENTITY digest.
///    `edit.recipe_fp` is written from it and so is `lumen:recipeFingerprint`, so the
///    comparison is like for like. A literal fingerprint would make a mask rename look
///    like a different picture and hand rule 2 a conflict that is not one.
public enum SidecarMerge {

    public struct State: Equatable, Sendable {
        public var rating: Int
        public var flag: SidecarFlag
        public var label: String?
        public var recipe: Recipe?
        /// `edit.recipe_fp` for `recipe`, when the caller already holds it. Left nil it
        /// is computed from `recipe`, which costs a canonical encode — worth passing.
        public var recipeFingerprint: String?
        /// `photo.sidecar_mtime`: the sidecar's mtime as of our last write or read of
        /// it. Nil means we have never recorded one, which is the ONLY honest answer to
        /// "has it changed since?" — see `resolve`.
        public var sidecarMTime: Int64?
        /// The catalog holds edits that have not been flushed to the sidecar yet. Rule
        /// 3's first half; the debounced writer knows it and nothing else does.
        public var hasUnflushedEdits: Bool

        public init(rating: Int = 0, flag: SidecarFlag = .none,
                    label: String? = nil, recipe: Recipe? = nil,
                    recipeFingerprint: String? = nil, sidecarMTime: Int64? = nil,
                    hasUnflushedEdits: Bool = false) {
            self.rating = rating
            self.flag = flag
            self.label = label
            self.recipe = recipe
            self.recipeFingerprint = recipeFingerprint
            self.sidecarMTime = sidecarMTime
            self.hasUnflushedEdits = hasUnflushedEdits
        }
    }

    /// Which of §15.5's rules fired. Returned rather than inferred so the caller can
    /// persist a rule-2 recovery, log a rule-3 conflict, and so a test can pin WHICH
    /// rule produced an answer instead of only the answer.
    public enum Decision: String, Equatable, Sendable {
        case noSidecar
        case catalogWins
        case sidecarWins
        case conflictCatalogWins
    }

    public struct Resolution: Equatable, Sendable {
        public var state: State
        public var decision: Decision
        /// Under rule 3 the spec keeps the sidecar as a snapshot. There is no snapshot
        /// machinery, so this is what was NOT kept — non-nil exactly when
        /// `decision == .conflictCatalogWins`.
        public var unpreservedSidecar: SidecarContent?

        public init(state: State, decision: Decision,
                    unpreservedSidecar: SidecarContent? = nil) {
            self.state = state
            self.decision = decision
            self.unpreservedSidecar = unpreservedSidecar
        }
    }

    /// `catalog` as stored, `sidecar` as read from disk (nil when there is no sidecar or
    /// it did not parse), `sidecarMTime` the mtime of that file RIGHT NOW.
    public static func resolve(catalog: State, sidecar: SidecarContent?,
                               sidecarMTime: Int64? = nil) -> Resolution {
        guard let sidecar else {
            return Resolution(state: catalog, decision: .noSidecar)
        }

        // The sidecar's own recipe, decoded once. A sidecar whose recipe will not parse
        // leaves the catalog's alone rather than becoming an empty recipe — "no edit
        // recorded" and "edited back to default" are different states, and only one of
        // them is a lie about the photographer's work. It also means an unparseable
        // sidecar can never trigger rule 2, which would otherwise replace a real recipe
        // with nothing.
        let incoming: Recipe? = sidecar.recipeJSON.flatMap {
            try? CanonicalJSON.decodeRecipe(from: Data($0.utf8))
        }

        // "Newer than our last write" needs a last write to compare against. With no
        // recorded stamp there is no evidence the sidecar moved, and acting on no
        // evidence is how a stale sidecar would overwrite a fresh catalog — the mirror
        // image of the bug being fixed. No stamp means rule 1.
        let moved: Bool = {
            guard let last = catalog.sidecarMTime, let now = sidecarMTime else {
                return false
            }
            // "Moved" means the file is not the one we last recorded — in EITHER
            // direction. `now > last` blinded rule 2 to every write that arrives
            // with an older or equal stamp: a Time-Machine restore keeps the file's
            // ORIGINAL mtime (the very case the header credits this rule with
            // handling), an rsync/Syncthing delivery carries the other machine's,
            // and a same-second write from another app truncates equal. All were
            // read as "nothing happened" and overwritten at the next flush.
            return now != last
        }()

        if moved, recipeDiffers(catalog: catalog, incoming: incoming, sidecar: sidecar) {
            if catalog.hasUnflushedEdits {
                return Resolution(state: fillingIn(catalog, from: sidecar,
                                                   incoming: incoming),
                                  decision: .conflictCatalogWins,
                                  unpreservedSidecar: sidecar)
            }
            return Resolution(state: taking(sidecar, over: catalog, incoming: incoming),
                              decision: .sidecarWins)
        }

        return Resolution(state: fillingIn(catalog, from: sidecar, incoming: incoming),
                          decision: .catalogWins)
    }

    // MARK: - The rules, one function each

    /// Rules 1 and 3: the catalog wins, and the sidecar fills in where it is silent.
    /// Filling in is not overwriting — it is the union, and it is what brings a photo
    /// that arrived from another machine in with its work attached.
    private static func fillingIn(_ catalog: State, from sidecar: SidecarContent,
                                  incoming: Recipe?) -> State {
        var out = catalog
        if out.recipe == nil, let incoming {
            out.recipe = incoming
            out.recipeFingerprint = sidecar.recipeFingerprint
        }
        if out.rating == 0, sidecar.rating > 0 { out.rating = sidecar.rating }
        if out.flag == .none { out.flag = sidecar.flag }
        if out.label == nil || out.label?.isEmpty == true,
           let name = sidecar.label, !name.isEmpty {
            out.label = name
        }
        return out
    }

    /// Rule 2: the sidecar wins — for every field it actually STATES.
    ///
    /// That qualifier is not a weakening of the rule, it is the format being honest
    /// about itself: `xmp:Rating` absent and `xmp:Rating = 0` are the same bytes, and so
    /// are a missing `lumen:flag` and `none`. Letting silence win would delete a four-
    /// star rating because the other machine's sidecar never carried one, which is the
    /// same class of loss this whole rule exists to stop.
    private static func taking(_ sidecar: SidecarContent, over catalog: State,
                               incoming: Recipe?) -> State {
        var out = catalog
        if let incoming {
            out.recipe = incoming
            out.recipeFingerprint = sidecar.recipeFingerprint
        }
        if sidecar.rating > 0 { out.rating = sidecar.rating }
        if sidecar.flag != .none { out.flag = sidecar.flag }
        if let name = sidecar.label, !name.isEmpty { out.label = name }
        return out
    }

    /// Rule 2's second condition. True only when the sidecar states a recipe that
    /// PARSED and whose render identity is not the one the catalog holds.
    ///
    /// A sidecar with no recipe at all cannot satisfy this, so a sidecar that merely got
    /// its mtime bumped — touched, re-synced, rewritten by another tool that left the
    /// lumen: namespace alone — never takes anything from the catalog.
    private static func recipeDiffers(catalog: State, incoming: Recipe?,
                                      sidecar: SidecarContent) -> Bool {
        guard let incoming else { return false }
        guard let catalogRecipe = catalog.recipe else { return true }
        let theirs = sidecar.recipeFingerprint
            ?? (try? RecipeFingerprint.fingerprint(incoming))
        let ours = catalog.recipeFingerprint
            ?? (try? RecipeFingerprint.fingerprint(catalogRecipe))
        guard let theirs, let ours else {
            // No fingerprint to compare on either side: fall back to the recipes
            // themselves rather than guessing that they differ.
            return !catalogRecipe.rendersSameAs(incoming)
        }
        return theirs != ours
    }
}

public enum XMPSidecar {

    public static let lumenNamespace = "http://lumenapp.dev/xmp/1.0/"

    // MARK: - What is on disk

    /// What the writer may do with the bytes at a sidecar's path.
    ///
    /// The distinction this type exists to keep is `absent` versus `unreadable`, and
    /// it used to be collapsed: the flush read the file with
    /// `String(contentsOf:encoding:.utf8)`, whose failure looks exactly like no file
    /// at all — so a UTF-16 sidecar written by another tool fell into the "no sidecar
    /// yet" branch and was REPLACED WHOLESALE by a fresh Lumen document. Every
    /// develop setting and keyword in it, gone on the first rating keystroke, which
    /// is precisely the .lrcat-era failure the merge path was built to end.
    public enum SidecarDocument: Equatable, Sendable {
        /// No file, or nothing but whitespace — authoring a fresh document is safe.
        case absent
        /// A UTF-8 text document; the writer may attempt a field splice into it.
        case document(String)
        /// Bytes exist and are not UTF-8 text. The writer must leave the file
        /// completely alone: Lumen cannot round-trip an encoding it cannot decode,
        /// and the file is someone's work. (A UTF-16 sidecar lands here on purpose —
        /// re-serializing it as UTF-8 under its original declaration would be a
        /// different way of damaging it.)
        case unreadable
    }

    /// Classify the raw bytes at a sidecar path. `nil` data means the read itself
    /// found no file.
    ///
    /// The NUL check is not paranoia: BOM-less UTF-16 of an ASCII document is,
    /// byte-for-byte, VALID UTF-8 — every second byte is a NUL, and NUL is a legal
    /// UTF-8 scalar. Without the check such a file decodes into a NUL-riddled string,
    /// passes for a document, and goes to the splicer; with it, the file is what it
    /// actually is here — an encoding this build cannot edit without damage.
    public static func classify(_ data: Data?) -> SidecarDocument {
        guard let data, !data.isEmpty else { return .absent }
        guard let text = String(data: data, encoding: .utf8),
              !text.contains("\0") else { return .unreadable }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .absent
        }
        return .document(text)
    }

    // MARK: - Write

    /// Update an existing sidecar's Lumen-owned fields and leave every other byte of
    /// it alone. `nil` means the document could not be edited safely — the caller must
    /// then leave the file untouched rather than replacing it (see XMPMerge.swift).
    ///
    /// `serialize` alone is only correct for a photo that has NO sidecar yet. Using it
    /// on an existing file is a whole-file replace, and that is how a folder of
    /// Lightroom-processed RAWs lost every develop setting and keyword to a single
    /// press of a rating key.
    public static func update(_ original: String, with content: SidecarContent) -> String? {
        XMPMerge.merge(into: original, fields: fieldLines(content),
                       lumenNamespace: lumenNamespace)
    }

    public static func serialize(_ content: SidecarContent) -> String {
        """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Lumen">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:lumen="\(lumenNamespace)">
        \(fieldLines(content))  </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    /// The child elements Lumen owns, one per line, escaped and ready to splice.
    /// Shared by `serialize` and `update` so a fresh document and an updated one can
    /// never disagree about what Lumen writes.
    static func fieldLines(_ content: SidecarContent) -> String {
        var fields = ""
        fields += "   <xmp:Rating>\(content.rating)</xmp:Rating>\n"
        if content.flag != .none {
            fields += "   <lumen:flag>\(content.flag.rawValue)</lumen:flag>\n"
        }
        if let label = content.label {
            fields += "   <xmp:Label>\(escapeXML(label))</xmp:Label>\n"
        }
        fields += "   <lumen:pipelineVersion>\(content.pipelineVersion)</lumen:pipelineVersion>\n"
        if let fp = content.recipeFingerprint {
            fields += "   <lumen:recipeFingerprint>\(escapeXML(fp))</lumen:recipeFingerprint>\n"
        }
        if let stamp = content.writeStamp {
            fields += "   <lumen:writeStamp>\(escapeXML(stamp))</lumen:writeStamp>\n"
        }
        if let uuid = content.catalogUUID {
            fields += "   <lumen:catalogUUID>\(escapeXML(uuid))</lumen:catalogUUID>\n"
        }
        if let recipe = content.recipeJSON {
            fields += "   <lumen:recipe>\(escapeXML(recipe))</lumen:recipe>\n"
        }
        // Last, and after the recipe: it is the largest element by far, and a reader
        // that gives up partway through a damaged file should have reached everything
        // smaller first. `parsedCleanly` is what stops such a read being written back.
        if let strokes = content.strokesPayload {
            fields += "   <lumen:strokes>\(escapeXML(strokes))</lumen:strokes>\n"
        }
        return fields
    }

    static func escapeXML(_ s: String) -> String {
        // Iterate unicode scalars, not Characters: a special char followed by a
        // combining mark forms one grapheme and would dodge a Character switch.
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            // Characters below 0x20 other than tab, newline and carriage return are
            // illegal in XML 1.0 even as numeric references, so emitting one writes a
            // sidecar no parser will read back — including this one, on the next
            // launch. A label is user-editable and a write stamp can come from
            // another tool, so this is reachable. Dropped rather than escaped,
            // because there is no legal escape for them.
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20 { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    // MARK: - Read

    public static func parse(_ data: Data) -> SidecarContent? {
        let delegate = SidecarParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        let complete = parser.parse() && parser.parserError == nil
        // Partial salvage is deliberate: a truncated sidecar that yielded fields is
        // better recovered than dropped (docs/15 §15.5 conflict rules do the rest).
        //
        // But the salvage now says it is one. The result used to be discarded entirely,
        // so a half-read document was indistinguishable from a whole one — and the writer
        // seeds itself from the read, then strips and re-emits, so every element the
        // parse never reached was deleted from the file. See `parsedCleanly`.
        guard delegate.sawAnyField else { return nil }
        var content = delegate.content
        content.parsedCleanly = complete
        return content
    }

    public static func parse(_ string: String) -> SidecarContent? {
        parse(Data(string.utf8))
    }
}

private final class SidecarParserDelegate: NSObject, XMLParserDelegate {
    var content = SidecarContent()
    var sawAnyField = false
    private var currentElement: String?
    private var buffer = ""

    private static let interesting: Set<String> = [
        "xmp:Rating", "xmp:Label", "lumen:flag",
        "lumen:pipelineVersion", "lumen:recipeFingerprint",
        "lumen:recipe", "lumen:strokes", "lumen:catalogUUID", "lumen:writeStamp",
    ]

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        // XMP carries a simple property EITHER as a child element or as an attribute
        // on rdf:Description, and the two forms are interchangeable. Lumen writes the
        // element form; Adobe writes the attribute form. Reading only elements meant
        // every sidecar from Lightroom, Bridge and Camera Raw parsed to "no fields
        // found", so `parse` returned nil, the rating and label were invisible, and the
        // caller started from a blank document — which is what made overwriting one
        // silently destructive rather than merely lossy.
        for (key, value) in attributeDict where Self.interesting.contains(key) {
            absorb(key, value)
        }
        if Self.interesting.contains(elementName) {
            currentElement = elementName
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == currentElement else { return }
        absorb(elementName, buffer)
        currentElement = nil
        buffer = ""
    }

    /// One field, from whichever form it arrived in.
    private func absorb(_ name: String, _ value: String) {
        sawAnyField = true
        switch name {
        case "xmp:Rating":
            // Clamped at the parse site: this comes from a file another application
            // wrote, and the star row downstream will be asked to draw whatever it
            // says. `CatalogStore.setRating` clamps too, but the in-memory PhotoItem
            // does not, so 999 stars would reach the grid.
            let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            content.rating = Swift.min(Swift.max(parsed, 0), 5)
        case "lumen:flag":
            content.flag = SidecarFlag(
                rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .none
        case "xmp:Label":
            content.label = value
        case "lumen:pipelineVersion":
            content.pipelineVersion =
                Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? currentPipelineVersion
        case "lumen:recipeFingerprint":
            content.recipeFingerprint = value
        case "lumen:strokes":
            // Whitespace-trimmed here rather than in the decoder: the XML writer indents
            // and a third-party rewriter may re-wrap, and an all-whitespace element is
            // "no payload", not "an empty one".
            let payload = value.trimmingCharacters(in: .whitespacesAndNewlines)
            content.strokesPayload = payload.isEmpty ? nil : payload
        case "lumen:recipe":
            content.recipeJSON = value
        case "lumen:catalogUUID":
            content.catalogUUID = value
        case "lumen:writeStamp":
            content.writeStamp = value
        default:
            break
        }
    }
}
