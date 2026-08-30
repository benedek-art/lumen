import SwiftUI

struct FixtureSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var step: Double = 1
    var decimals: Int = 0
    var help: String?
    var onReset: (() -> Void)?
    @State private var isDragging = false
    var body: some View { Text(title) }
}
