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
    public var catalogUUID: String?
    public var writeStamp: String?  // ISO 8601

    public init(rating: Int = 0, flag: SidecarFlag = .none, label: String? = nil,
                pipelineVersion: Int = currentPipelineVersion,
                recipeFingerprint: String? = nil, recipeJSON: String? = nil,
                catalogUUID: String? = nil, writeStamp: String? = nil) {
        self.rating = rating
        self.flag = flag
        self.label = label
        self.pipelineVersion = pipelineVersion
        self.recipeFingerprint = recipeFingerprint
        self.recipeJSON = recipeJSON
        self.catalogUUID = catalogUUID
        self.writeStamp = writeStamp
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
/// debounce — because the RULE is pure, and `LumenApp` has no test target. The rule is
/// one sentence: the sidecar fills in where the catalog is silent, and never overwrites
/// it. Catalog-wins is the right way round because the catalog is what the running app
/// just edited, while the sidecar may be seconds stale behind the debounce.
public enum SidecarMerge {

    public struct State: Equatable, Sendable {
        public var rating: Int
        public var flag: SidecarFlag
        public var label: String?
        public var recipe: Recipe?

        public init(rating: Int = 0, flag: SidecarFlag = .none,
                    label: String? = nil, recipe: Recipe? = nil) {
            self.rating = rating
            self.flag = flag
            self.label = label
            self.recipe = recipe
        }
    }

    /// `catalog` as stored, `sidecar` as read from disk (nil when there is no sidecar,
    /// or it did not parse).
    public static func resolve(catalog: State, sidecar: SidecarContent?) -> State {
        var out = catalog
        guard let sidecar else { return out }

        if out.recipe == nil, let json = sidecar.recipeJSON {
            // A sidecar whose recipe will not parse leaves the catalog's nil alone
            // rather than becoming an empty recipe — "no edit recorded" and "edited
            // back to default" are different states, and only one of them is a lie.
            out.recipe = try? CanonicalJSON.decodeRecipe(from: Data(json.utf8))
        }
        if out.rating == 0, sidecar.rating > 0 { out.rating = sidecar.rating }
        if out.flag == .none { out.flag = sidecar.flag }
        if out.label == nil || out.label?.isEmpty == true,
           let name = sidecar.label, !name.isEmpty {
            out.label = name
        }
        return out
    }
}

public enum XMPSidecar {

    public static let lumenNamespace = "http://lumenapp.dev/xmp/1.0/"

    // MARK: - Write

    public static func serialize(_ content: SidecarContent) -> String {
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
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Lumen">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:lumen="\(lumenNamespace)">
        \(fields)  </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
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
        _ = parser.parse()
        // Partial salvage is deliberate: a truncated sidecar that yielded fields is
        // better recovered than dropped (docs/15 §15.5 conflict rules do the rest).
        guard delegate.sawAnyField else { return nil }
        return delegate.content
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
        "lumen:recipe", "lumen:catalogUUID", "lumen:writeStamp",
    ]

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
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
        let value = buffer
        sawAnyField = true
        switch elementName {
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
        case "lumen:recipe":
            content.recipeJSON = value
        case "lumen:catalogUUID":
            content.catalogUUID = value
        case "lumen:writeStamp":
            content.writeStamp = value
        default:
            break
        }
        currentElement = nil
        buffer = ""
    }
}
