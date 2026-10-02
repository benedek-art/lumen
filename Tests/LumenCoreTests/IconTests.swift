// The app had no icon at all, so macOS drew the blank white document placeholder — which
// is what the owner was looking at in the Dock, and the reason he sent artwork.
//
// An icon is TWO facts in two files, and either alone is inert: `AppIcon.icns` compiled
// into `Contents/Resources`, and `CFBundleIconFile` naming it in the plist. Ship the file
// without the key and the Dock still draws the placeholder; ship the key without the file
// and it draws the placeholder too. Both halves are asserted here, in the same shape
// `FrontDoorTests` uses for the Finder-open pair.
//
// The artwork is GEOMETRY, not an exported bitmap: `scripts/make-appicon.py` renders every
// size from fourteen numbers, so the 16 px icon is the same shape as the 1024 px one
// rather than a resample of it. That also makes it correctable — the day the mark wants to
// be a hair larger, it is a constant rather than a paint program.
import XCTest
@testable import LumenCore

final class IconTests: XCTestCase {

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.packageRoot.appendingPathComponent(path),
                   encoding: .utf8)
    }

    /// macOS wants all ten entries. A missing size is not a build error — `iconutil`
    /// compiles what it is given — it is a blurry icon at exactly the size somebody
    /// notices later.
    func testTheIconsetHasEverySizeMacOSAsksFor() {
        let set = Self.packageRoot.appendingPathComponent("resources/Lumen.iconset")
        let expected = [
            "icon_16x16.png", "icon_16x16@2x.png",
            "icon_32x32.png", "icon_32x32@2x.png",
            "icon_128x128.png", "icon_128x128@2x.png",
            "icon_256x256.png", "icon_256x256@2x.png",
            "icon_512x512.png", "icon_512x512@2x.png",
        ]
        for name in expected {
            let url = set.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "resources/Lumen.iconset/\(name) is missing — run "
                              + "python3 scripts/make-appicon.py")
        }
    }

    /// And they are real PNGs of the size their name claims, read out of the IHDR rather
    /// than trusted. A 16 px file called `icon_512x512.png` compiles without complaint.
    func testEachIconIsAPNGOfTheSizeItsNameClaims() throws {
        let set = Self.packageRoot.appendingPathComponent("resources/Lumen.iconset")
        let expected: [(String, Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
        ]
        for (name, size) in expected {
            let url = set.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), data.count > 24 else {
                XCTFail("\(name) is unreadable")
                continue
            }
            let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            XCTAssertEqual(Array(data.prefix(8)), signature, "\(name) is not a PNG")
            // IHDR width and height are big-endian 32-bit at byte 16.
            func be32(_ offset: Int) -> Int {
                var v = 0
                for i in 0..<4 { v = v << 8 | Int(data[offset + i]) }
                return v
            }
            XCTAssertEqual(be32(16), size, "\(name) is \(be32(16)) px wide")
            XCTAssertEqual(be32(20), size, "\(name) is \(be32(20)) px tall")
        }
    }

    /// The bundle compiles the iconset and names the result. Both halves, because either
    /// alone leaves the placeholder on screen.
    func testTheBundleCompilesTheIconAndNamesIt() throws {
        let script = try text("scripts/build-app.sh")
        XCTAssertTrue(script.contains("iconutil -c icns"),
                      "nothing compiles the iconset into an .icns")
        XCTAssertTrue(script.contains("Contents/Resources/AppIcon.icns"),
                      "the compiled icon does not land where the plist points")
        XCTAssertTrue(script.contains("<key>CFBundleIconFile</key>"),
                      "the plist does not name an icon, so the Dock draws the "
                          + "placeholder however good the artwork is")
        XCTAssertTrue(script.contains("mkdir -p \"$APP/Contents/MacOS\" \"$APP/Contents/Resources\""),
                      "Contents/Resources is not created, so iconutil has nowhere to write")
    }

    /// The generator is committed, so the icon can be corrected rather than replaced.
    func testTheArtworkIsGeometryAndNotAnExportedBitmap() throws {
        let gen = try text("scripts/make-appicon.py")
        for constant in ["MARK_SLANT", "CROSS_STEM_W", "GROUND_RADIUS"] {
            XCTAssertTrue(gen.contains(constant),
                          "\(constant) is gone — the icon has stopped being editable "
                              + "geometry and become a picture somebody has to redraw")
        }
    }
}
