actor FixtureWorker { func run() {} }
struct FixtureDriver {
    let worker = FixtureWorker()
    func go() async {
        async let result = worker.run()
        _ = await result
    }
}
