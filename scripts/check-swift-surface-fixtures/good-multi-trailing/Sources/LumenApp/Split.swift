import SwiftUI

struct FixtureSplit<A: View, B: View>: View {
    let count: Int
    let top: A
    let bottom: B
    init(_ count: Int, @ViewBuilder top: () -> A, @ViewBuilder bottom: () -> B) {
        self.count = count
        self.top = top()
        self.bottom = bottom()
    }
    var body: some View { top }
}

struct FixtureUser: View {
    var body: some View {
        FixtureSplit(1) {
            Text("a")
        } bottom: {
            Text("b")
        }
    }
}
