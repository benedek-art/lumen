# Loaded RAW materialization failure classification — native execution pending

Baseline: `29ad3b0`. This is failure observability, **not a repair** of the underlying
loaded-runtime failure. It does not change decoder math, image formats, allocation
caps, contexts, cache policy, retries, fallback behavior, tolerances or goldens.

The parent-observed `29ad` native run (39150313448, job 117742430037) completed its
serial 190 renders / 105 exact pairs without changes. Under two independent loaded
processes, the diagnostic wrappers reported eligible `.pipeline` materialization
returning nil: corpus4671/pass1/AI25 at 3888×2592, and corpus2607/pass0/first-Off at
3680×2760. Completed comparisons did not reproduce a one-code difference. These
observations identify upstream refusal; they do not identify allocation, command
submission or GPU completion as its cause. Earlier zero-filled diagnostic bitmap
reads are separately distinguished from an actual all-black source plane.

## Shared implementation, unchanged production entry point

The original two-argument `DecodeMaterializer.materialize` signature, default
`.pipeline` argument and `Materializer` typealias remain unchanged. That function
forwards to one three-argument implementation with a nil optional failure callback.
Production logs nothing. There is no mutable global observer.

The overload reports only at the existing failure returns: unavailable RAW9 context,
admission refusal, missing working colour space, `CVPixelBufferCreate` return code,
success without a pixel buffer, or the NSError from task submission/completion.
A local phase variable distinguishes `startTask` from `waitUntilCompleted`; the
actual calls, order, dimensions, format, context selection and destination settings
are unchanged. Failures still return nil once; no retry or alternate image is added.

Only the existing reconstruction test supplies a callback. It uses this shared
production implementation and emits public-fixture metadata plus reason/CVReturn or
NSError domain and code under the separate
`DECODE-RECONSTRUCTION-DIAGNOSTIC` prefix. Error descriptions are withheld by default
because framework text can contain original paths. The public SHA-verified CI lane
may explicitly set `LUMEN_DECODE_RECONSTRUCTION_PUBLIC_ERRORS=1` to include them;
private/local fixtures need not expose that text. The 306 completed-run coverage records and
all strict scene/display comparisons remain unchanged. Incomplete processes must
still be reported as incomplete; peers must be parsed independently.

One deterministic control supplies an invalid infinite extent. It requires one
admission report and nil, then invokes the original signature through the unchanged
function typealias and requires the same nil refusal. It does not force an actual
allocation or GPU failure.

## Validation and remaining gate

Executed locally: frontend Swift syntax parsing and `git diff --check` pass. This is
not Apple SDK typechecking or GPU execution. Native whole-default-suite verification
is required because a production source file now carries the optional observation
path. The targeted loaded reconstruction must then classify the actual failure;
no underlying failure reason or successful fix is claimed before that run.

Initial source-roster scan rejected the newly spelled `CVReturn` alias because its
platform list lacked that SDK spelling. The observer stores the identical signed
32-bit status as `Int32` instead; Core Video documents `CVReturn` as
[`int32_t`](https://developer.apple.com/documentation/corevideo/cvreturn?language=objc).
No checker exemption or policy change was added. The initial scan is retained;
the corrected source must pass a new complete scan and native SDK compilation.

```sh
swift test -c release
swift test -c release --filter DecodeReconstructionContinuityTests.testMaterializerFailureReporterPreservesOriginalWrapperRefusal
```

The existing hosted reconstruction workflow owns the bounded public fixture fetch,
serial/overlapping native execution, exact statuses and artifact collection. No
private assets are needed or uploaded.
