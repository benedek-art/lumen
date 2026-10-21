// ContactSheet.swift — tiles in a grid on a mid-grey ground, each labelled with its value
// in a built-in 5×7 bitmap font, and a header naming the key. Drawn directly in encoded
// RGB8, so the tiles are byte-identical to the single renders.

import Foundation

enum ContactSheet {

    struct Tile {
        let image: EncodedImage
        let label: String
        let highlighted: Bool
    }

    static let gap = 8
    static let glyphScale = 2

    static func compose(_ tiles: [Tile], columns: Int, header: String) -> (Int, Int, [UInt8]) {
        precondition(!tiles.isEmpty)
        let cols = Swift.max(1, Swift.min(columns, tiles.count))
        let rows = (tiles.count + cols - 1) / cols
        let tileW = tiles.map(\.image.width).max()!
        let tileH = tiles.map(\.image.height).max()!
        let glyphH = 7 * glyphScale
        let labelH = glyphH + 10
        let headerH = glyphH + 14
        let width = gap + cols * (tileW + gap)
        let height = headerH + rows * (tileH + labelH + gap) + gap
        var px = [UInt8](repeating: 119, count: width * height * 3)   // ≈ sRGB 18% grey

        func fill(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ v: (UInt8, UInt8, UInt8)) {
            for y in Swift.max(0, y0)..<Swift.min(height, y0 + h) {
                for x in Swift.max(0, x0)..<Swift.min(width, x0 + w) {
                    let i = (y * width + x) * 3
                    px[i] = v.0; px[i + 1] = v.1; px[i + 2] = v.2
                }
            }
        }
        func text(_ s: String, centreX: Int, top: Int, colour: (UInt8, UInt8, UInt8)) {
            let advance = 6 * glyphScale
            let total = s.count * advance - glyphScale
            var x = centreX - total / 2
            for ch in s.uppercased() {
                let rowsBits = Font.glyph(ch)
                for (ry, bits) in rowsBits.enumerated() {
                    for cx in 0..<5 where bits & (1 << (4 - cx)) != 0 {
                        fill(x + cx * glyphScale, top + ry * glyphScale, glyphScale,
                             glyphScale, colour)
                    }
                }
                x += advance
            }
        }

        text(header, centreX: width / 2, top: 7, colour: (240, 240, 240))
        for (k, tile) in tiles.enumerated() {
            let c = k % cols, r = k / cols
            let ox = gap + c * (tileW + gap)
            let oy = headerH + r * (tileH + labelH + gap)
            let img = tile.image
            let dx = ox + (tileW - img.width) / 2
            if tile.highlighted {
                fill(dx - 3, oy - 3, img.width + 6, img.height + 6, (230, 200, 40))
            }
            for y in 0..<img.height {
                let src = y * img.width * 3
                let dst = ((oy + y) * width + dx) * 3
                px.replaceSubrange(dst..<(dst + img.width * 3),
                                   with: img.bytes[src..<(src + img.width * 3)])
            }
            text(tile.label, centreX: ox + tileW / 2, top: oy + tileH + 6,
                 colour: tile.highlighted ? (250, 220, 60) : (245, 245, 245))
        }
        return (width, height, px)
    }
}

/// A 5×7 bitmap font: uppercase, digits and the punctuation a key path and a number need.
/// Each glyph is seven rows of five bits, most significant bit leftmost.
enum Font {
    static func glyph(_ c: Character) -> [UInt8] {
        if let g = table[c] { return g }
        return table["?"]!
    }

    private static func g(_ rows: String...) -> [UInt8] {
        rows.map { row in
            var v: UInt8 = 0
            for ch in row { v = (v << 1) | (ch == "#" ? 1 : 0) }
            return v
        }
    }

    static let table: [Character: [UInt8]] = [
        "0": g(" ### ", "#   #", "#  ##", "# # #", "##  #", "#   #", " ### "),
        "1": g("  #  ", " ##  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "),
        "2": g(" ### ", "#   #", "    #", "   # ", "  #  ", " #   ", "#####"),
        "3": g("#####", "   # ", "  #  ", "   # ", "    #", "#   #", " ### "),
        "4": g("   # ", "  ## ", " # # ", "#  # ", "#####", "   # ", "   # "),
        "5": g("#####", "#    ", "#### ", "    #", "    #", "#   #", " ### "),
        "6": g("  ## ", " #   ", "#    ", "#### ", "#   #", "#   #", " ### "),
        "7": g("#####", "    #", "   # ", "  #  ", " #   ", " #   ", " #   "),
        "8": g(" ### ", "#   #", "#   #", " ### ", "#   #", "#   #", " ### "),
        "9": g(" ### ", "#   #", "#   #", " ####", "    #", "   # ", " ##  "),
        "A": g(" ### ", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"),
        "B": g("#### ", "#   #", "#   #", "#### ", "#   #", "#   #", "#### "),
        "C": g(" ### ", "#   #", "#    ", "#    ", "#    ", "#   #", " ### "),
        "D": g("#### ", "#   #", "#   #", "#   #", "#   #", "#   #", "#### "),
        "E": g("#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#####"),
        "F": g("#####", "#    ", "#    ", "#### ", "#    ", "#    ", "#    "),
        "G": g(" ### ", "#   #", "#    ", "# ###", "#   #", "#   #", " ####"),
        "H": g("#   #", "#   #", "#   #", "#####", "#   #", "#   #", "#   #"),
        "I": g(" ### ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", " ### "),
        "J": g("  ###", "   # ", "   # ", "   # ", "   # ", "#  # ", " ##  "),
        "K": g("#   #", "#  # ", "# #  ", "##   ", "# #  ", "#  # ", "#   #"),
        "L": g("#    ", "#    ", "#    ", "#    ", "#    ", "#    ", "#####"),
        "M": g("#   #", "## ##", "# # #", "# # #", "#   #", "#   #", "#   #"),
        "N": g("#   #", "#   #", "##  #", "# # #", "#  ##", "#   #", "#   #"),
        "O": g(" ### ", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "),
        "P": g("#### ", "#   #", "#   #", "#### ", "#    ", "#    ", "#    "),
        "Q": g(" ### ", "#   #", "#   #", "#   #", "# # #", "#  # ", " ## #"),
        "R": g("#### ", "#   #", "#   #", "#### ", "# #  ", "#  # ", "#   #"),
        "S": g(" ####", "#    ", "#    ", " ### ", "    #", "    #", "#### "),
        "T": g("#####", "  #  ", "  #  ", "  #  ", "  #  ", "  #  ", "  #  "),
        "U": g("#   #", "#   #", "#   #", "#   #", "#   #", "#   #", " ### "),
        "V": g("#   #", "#   #", "#   #", "#   #", "#   #", " # # ", "  #  "),
        "W": g("#   #", "#   #", "#   #", "# # #", "# # #", "# # #", " # # "),
        "X": g("#   #", "#   #", " # # ", "  #  ", " # # ", "#   #", "#   #"),
        "Y": g("#   #", "#   #", " # # ", "  #  ", "  #  ", "  #  ", "  #  "),
        "Z": g("#####", "    #", "   # ", "  #  ", " #   ", "#    ", "#####"),
        ".": g("     ", "     ", "     ", "     ", "     ", " ##  ", " ##  "),
        "-": g("     ", "     ", "     ", "#####", "     ", "     ", "     "),
        "+": g("     ", "  #  ", "  #  ", "#####", "  #  ", "  #  ", "     "),
        "=": g("     ", "     ", "#####", "     ", "#####", "     ", "     "),
        "_": g("     ", "     ", "     ", "     ", "     ", "     ", "#####"),
        "(": g("   # ", "  #  ", " #   ", " #   ", " #   ", "  #  ", "   # "),
        ")": g(" #   ", "  #  ", "   # ", "   # ", "   # ", "  #  ", " #   "),
        ":": g("     ", " ##  ", " ##  ", "     ", " ##  ", " ##  ", "     "),
        ",": g("     ", "     ", "     ", "     ", " ##  ", "  #  ", " #   "),
        "/": g("     ", "    #", "   # ", "  #  ", " #   ", "#    ", "     "),
        "%": g("##   ", "##  #", "   # ", "  #  ", " #   ", "#  ##", "   ##"),
        "?": g(" ### ", "#   #", "    #", "   # ", "  #  ", "     ", "  #  "),
        " ": g("     ", "     ", "     ", "     ", "     ", "     ", "     "),
    ]
}
