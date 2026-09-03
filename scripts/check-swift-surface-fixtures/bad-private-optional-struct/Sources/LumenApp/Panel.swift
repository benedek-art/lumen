import SwiftUI

struct FixturePanel: View {
    @Binding var amount: Double
    var body: some View {
        // `indented` is declared after `bipolar`; passing it straight after `title` is
        // the mistake this fixture exists for. Swift's memberwise initializer requires
        // declaration order and rejects this.
        FixtureSlider(title: "Amount", indented: true,
                      value: $amount, range: 0...100,
                      bipolar: false, help: "Out of order.")
    }
}
