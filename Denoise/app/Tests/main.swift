import Foundation

// Run both suites unconditionally so a failing engine check never hides Core failures.
let engineOK = runEngineTests()
let coreOK = runCoreTests()
exit(engineOK && coreOK ? 0 : 1)
