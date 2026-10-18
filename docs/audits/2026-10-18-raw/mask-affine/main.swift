import Foundation
// Only dependencies used by the verbatim production helper; no model of its math.
enum Num { static func saturate(_ v: Double) -> Double { min(max(v, 0), 1) } }
func travel(width: Double, height: Double, dx: Double, dy: Double, strength: Double) -> (Double, Double, Double, Double) {
    var helper = BrushStabilizer(strength: strength)
    _ = helper.next(x: 0.5, y: 0.5)
    let x = 0.5 + dx / width, y = 0.5 + dy / height
    let p = helper.next(x: x, y: y) ?? (x: 0.5, y: 0.5)
    let end = helper.finish(x: x, y: y) ?? p
    return ((p.x-0.5)*width, (p.y-0.5)*height,
            (end.x-0.5)*width, (end.y-0.5)*height)
}
let horizontal = travel(width: 1000, height: 500, dx: 30, dy: 0, strength: 100)
let vertical = travel(width: 1000, height: 500, dx: 0, dy: 30, strength: 100)
print("1000x500 30px horizontal: brush=\(horizontal.0)px final=\(horizontal.2)px; expected rope=20px")
print("1000x500 30px vertical: brush=\(vertical.1)px final=\(vertical.3)px; expected rope=20px")
let jitterH = travel(width: 1000, height: 500, dx: 15, dy: 0, strength: 100)
let jitterV = travel(width: 1000, height: 500, dx: 0, dy: 15, strength: 100)
print("15px jitter horizontal brush=\(jitterH.0)px vertical brush=\(jitterV.1)px; both inside20px rope")
let squareH = travel(width: 1000, height: 1000, dx: 30, dy: 0, strength: 100)
let squareV = travel(width: 1000, height: 1000, dx: 0, dy: 30, strength: 100)
let off = travel(width: 1000, height: 500, dx: 30, dy: 30, strength: 0)
precondition(abs(horizontal.0-10)<1e-10 && abs(vertical.1-20)<1e-10)
precondition(abs(jitterH.0)<1e-10 && abs(jitterV.1-5)<1e-10)
precondition(abs(horizontal.2-30)<1e-10 && abs(vertical.3-30)<1e-10)
precondition(abs(squareH.0-squareV.1)<1e-10)
precondition(abs(off.0-30)<1e-10 && abs(off.1-30)<1e-10)
print("Diagnostic PASS: defect reproduced; square, disabled and final endpoint controls PASS")
if CommandLine.arguments.contains("--require-isotropy") {
    // Independently defined expected physical metric: 2% of long edge =20px;
    // 30px travel must move brush10px in either direction. Exit instead of trapping.
    guard abs(horizontal.0-10)<1e-10 && abs(vertical.1-10)<1e-10 else {
        print("RED: equal physical travel does not leave equal long-edge rope length")
        exit(1)
    }
}
