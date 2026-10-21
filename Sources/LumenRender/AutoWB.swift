// AutoWB.swift — `lumen-render autowb`: Auto white balance, headless (WS-03, SPEC line 12).
//
//   lumen-render autowb --input in.lfi --as-shot-kelvin K --as-shot-tint T
//                       [--exclude x,y,w,h ...]
//
// Runs `AutoWhiteBalance.estimate` on the input at its own size (the scene-linear
// Rec.2020 decode at camera-reference white balance, as every lumen-render input is)
// and prints ONE line of JSON:
//
//   {"confidence":…,"kelvin":…,"seconds":…,"tint":…}
//
// kelvin/tint are in the slider's convention (Adobe/DNG, `ColorTemperature`), ready for
// `--set develop.raw.temp=… --set develop.raw.tint=…`. `seconds` is the time spent
// inside `AutoWhiteBalance` only; reading the file is excluded. `--exclude` takes
// rectangles in input pixels, top-left origin: four numbers per rectangle, repeated or
// comma-joined (x,y,w,h,x,y,w,h…).

import Foundation
import LumenCore

extension LumenRenderCLI {

    struct AutoWBReport: Encodable {
        let kelvin: Double
        let tint: Double
        let confidence: Double
        let seconds: Double
    }

    static func autowb(_ args: Args) throws {
        let input = try args.require("input")
        let settings = try args.settings()
        var numbers: [Int] = []
        for list in args.all("exclude") {
            for part in list.split(separator: ",") {
                guard let v = Int(part.trimmingCharacters(in: .whitespaces)) else {
                    throw InputError.message("--exclude expects integers x,y,w,h, got '\(list)'")
                }
                numbers.append(v)
            }
        }
        guard numbers.count % 4 == 0 else {
            throw InputError.message("--exclude needs four numbers per rectangle (x,y,w,h)")
        }
        let regions = stride(from: 0, to: numbers.count, by: 4).map {
            AutoWhiteBalance.Region(x: numbers[$0], y: numbers[$0 + 1],
                                    width: numbers[$0 + 2], height: numbers[$0 + 3])
        }
        let image = try InputImage.load(path: input)
        let start = Date()
        let estimate = AutoWhiteBalance.estimate(
            image,
            asShot: WhiteBalanceEngine.Neutral(kelvin: settings.asShotKelvin,
                                               tint: settings.asShotTint),
            excluding: regions)
        let seconds = Date().timeIntervalSince(start)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let report = AutoWBReport(kelvin: estimate.kelvin, tint: estimate.tint,
                                  confidence: estimate.confidence, seconds: seconds)
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
