import SwiftUI

struct FixturePanel: View {
    @Binding var amount: Double
    var isRaw = true
    var body: some View {
        FixtureSlider(title: "Amount",
                      value: $amount,
                      range: 0...100,
                      help: isRaw
                          ? "The strength of the deconvolution, matched "
                            + "to the blur measured from the file."
                          : nil,
                      step: 5,
                      decimals: 1)
    }
}
