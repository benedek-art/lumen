import SwiftUI

struct FixtureFieldRow<Content: View>: View {
    let label: String
    let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View { content }
}

struct FixtureSheet: View {
    var body: some View {
        FixtureFieldRow("Format") {
            Text("JPEG")
        }
    }
}
