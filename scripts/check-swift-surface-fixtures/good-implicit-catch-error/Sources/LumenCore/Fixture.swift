import Foundation
enum FixtureFailure: Error { case failed }
struct FixtureDriver {
    func fail() throws { throw FixtureFailure.failed }
    func go() {
        do { try fail() } catch { print(error.localizedDescription) }
    }
}
