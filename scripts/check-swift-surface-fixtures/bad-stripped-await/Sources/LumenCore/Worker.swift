actor FixtureWorker {
    func run() {}
}

struct FixtureDriver {
    let worker = FixtureWorker()
    func go() {
        worker.run()
    }
}
