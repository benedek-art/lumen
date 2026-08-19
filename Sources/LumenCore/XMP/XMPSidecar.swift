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

public struct SidecarContent: Equatable, Sendable {
    public var rating: Int          // 0…5
    public var label: String?       // color label name
    public var pipelineVersion: Int
    public var recipeFingerprint: String?
    public var recipeJSON: String?  // canonical sparse recipe JSON
    public var catalogUUID: String?
    public var writeStamp: String?  // ISO 8601

    public init(rating: Int = 0, label: String? = nil,
                pipelineVersion: Int = currentPipelineVersion,
                recipeFingerprint: String? = nil, recipeJSON: String? = nil,
                catalogUUID: String? = nil, writeStamp: String? = nil) {
        self.rating = rating
        self.label = label
        self.pipelineVersion = pipelineVersion
        self.recipeFingerprint = recipeFingerprint
        self.recipeJSON = recipeJSON
        self.catalogUUID = catalogUUID
        self.writeStamp = writeStamp
    }
}

public enum XMPSidecar {

    public static let lumenNamespace = "http://lumenapp.dev/xmp/1.0/"

    // MARK: - Write

    public static func serialize(_ content: SidecarContent) -> String {
        var fields = ""
        fields += "   <xmp:Rating>\(content.rating)</xmp:Rating>\n"
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
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: - Read

    public static func parse(_ data: Data) -> SidecarContent? {
        let delegate = SidecarParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() || delegate.sawAnyField else { return nil }
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
        "xmp:Rating", "xmp:Label",
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
            content.rating = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
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
