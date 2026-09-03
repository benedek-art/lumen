import SwiftUI

struct FixturePanel: View {
    @Binding var amount: Double
    var body: some View {
        FixtureSlider(title: "Amount", value: $amount, range: 0...100,
                      bipolar: false, indented: true, help: "In order.")
    }
}
