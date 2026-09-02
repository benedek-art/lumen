import SwiftUI

// A view holding a PRIVATE OPTIONAL stored property with no written default.
//
// `@State private var closer: Task<Void, Never>?` has an implicit `nil`, so it is not a
// memberwise parameter — but the synthesizer used to read "private, no default" and veto
// the whole struct. A vetoed struct is not partly checked: every one of its call sites
// becomes silently exempt, which is how a real reordered call reached CI.
struct FixtureSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var bipolar: Bool = true
    var indented: Bool = false
    var help: String?

    @State private var closer: Task<Void, Never>?
    @State private var dragging = false
    private var doubled: Double { value * 2 }

    var body: some View { Text(title) }
}
