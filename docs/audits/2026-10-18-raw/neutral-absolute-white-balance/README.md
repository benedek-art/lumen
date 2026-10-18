# Exact neutral absolute local white balance identity

Candidate code commit `c9bd2ac`, base `2b96ec49171132b7c0b1023ae01466b79afb096e`.

The absolute initializer previously copied the engine matrix but unconditionally set its identity flag false. For the exactly neutral known case 5500 K / tint 0, the actual engine matrix is exactly identity and the engine exact parameter predicate is true. GPU LocalPlan consequently allocated an unnecessary pre-LUT, exposing signed/HDR input to its finite table domain despite there being no correction. The fix changes only `self.isIdentity = false` to `self.isIdentity = engine.isIdentity`. No tolerance, matrix, amount interpolation or other math is changed.

Executed Linux evidence:

- Existing optimized baseline Core, full source comparison against candidate: only intended `Engine/ReferenceRenderer.swift` differs. The baseline objects were built at c7, not a whole-package 2b96 build; full dependency manifest comparison is archived without exemptions.
- Actual baseline controlled witness: exit 1, `matrixExactIdentity=true engineIdentity=true localIdentity=false`.
- Fresh candidate optimized Core build: exit 0, 68.03 seconds. Fresh build directory `build-neutral-kelvin-core`; full pre/post Core SHA manifests match.
- Same actual witness against candidate objects: exit 0, `matrixExactIdentity=true engineIdentity=true localIdentity=true`.
- Both new actual Core test bodies run through explicit Linux XCTMain: baseline 2 tests / 2 assertions failed, nonneutral matrix control passed; candidate 2 tests / 0 failures. The only source substitution is `@testable import` to public `import`; test bodies are unchanged. Compile and execution commands are archived. The baseline test output is JSON-encoded to preserve its original trailing spaces without adding patch whitespace errors. An earlier assertion-trap witness is retained in scratch but not counted as successful execution.

Fresh build command (workspace-specific paths):

```sh
LD_LIBRARY_PATH=/workspace/scratch/2982a056243e/swift-deps/usr/lib/x86_64-linux-gnu LIBRARY_PATH=/workspace/scratch/2982a056243e/swift-deps/usr/lib/x86_64-linux-gnu /workspace/scratch/2982a056243e/swift/usr/bin/swift build -c release --scratch-path /workspace/scratch/2982a056243e/build-neutral-kelvin-core --jobs 2 --target LumenCore -Xcc -I/workspace/scratch/2982a056243e/swift-deps/usr/include
```

Native GPU test remains unexecuted in this environment:

```sh
swift test -c release --filter NeutralAbsoluteWhiteBalanceGPUIdentityTests
swift test -c release --filter NeutralAbsoluteWhiteBalanceIdentityTests
```

It checks actual S11 local adjust passthrough, exact signed/HDR pixel identity and no pre-LUT for cubes 33/65 with nil/zero tint. A native old-assignment mutant should fail the pre-LUT and pixel assertions; native before/after qualification is owed. No camera, aesthetic, general epsilon-continuity or exhaustive white-balance acceptance follows.

Scope: the engine identity predicate uses exact target parameters. Earlier source review raised a reciprocal-roundtrip concern and named3333.3 as a possible example. A bounded actual-Core probe **did not reproduce it**, so that example is not a defect claim. All20 initializer evaluations (5500,6500,3333.3,6177.2,Double(Float(6177.2)) ×Amount1/.5 ×nil/zeroTint) returned exact identity, zero matrix error and zero signed/HDR RGB error. Compile0/singleexecution0; full129-fileCoremanifest matched currenta4bc sources before linking/execution. Exactcommand/code/status/records are roundtrip-a4bc/. Arbitrary values, other compilers and native GUI behavior remain unqualified; no tolerance or shortcut was introduced. These are actual Core results, not native GPU camera tests.

## Executed native causal qualification at a4bc

[Job117701884220](https://github.com/benedek-art/lumen/actions/runs/39136447281/job/117701884220) passed. Baseline **3tests/0fail7.626s** (2Core plus1actualGPU method); replacing only the final exact identity assignment with the oldfalse produces **3tests/10genuineassertions3.322s**. Both neutral methods fail and the nonneutral matrix/flag control passes. GPU fixture covers nil/zeroTint and33/65, exact signed/HDR fullbuffer identity and preLUT absence. No image/camera/appearance or broad Amount-continuity acceptance follows.

Source restored/cmp checked; before/after/currentSHA256 all025639fb1c05a774c32365fb3b8763550d8ef9de981282e34281c1498c3752f0. Exact mutation plus hashes, test outcomes/summaries and bounded assertion prefixes are native-causal-artifact-a4bc150.json. The job-log reader returned Transport closed on this19,637,479-byte mutant log (XCTAssertNil printed full LUT data). The public ZIP artifact was recovered instead and itsSHA256b520fe948f1a49cda11a10d31827143ce3c53cac8c8d221b86e2278969caa5e2 matched GitHub metadata. Full raw files remain in hosted artifact12139294687; no multi-megabyte LUT dump or binary is committed.
