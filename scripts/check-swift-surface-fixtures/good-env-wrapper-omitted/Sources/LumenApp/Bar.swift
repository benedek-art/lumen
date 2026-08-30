import SwiftUI

final class FixtureState: ObservableObject {
    @Published var count = 0
}

struct FixtureBar: View {
    @EnvironmentObject var state: FixtureState
    var body: some View { Text("hello") }
}

struct FixtureHost: View {
    var body: some View { FixtureBar() }
}
