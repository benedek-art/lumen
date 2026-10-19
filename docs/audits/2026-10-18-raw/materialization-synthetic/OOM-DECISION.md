# Observed RAW command-buffer out-of-memory; no policy repair yet

Exact diagnostic source0ad9cc4d094d223c2e52d11bcb4cec79918380dd, [run39154755689/job117755564591](https://github.com/benedek-art/lumen/actions/runs/39154755689/job/117755564591). Both loaded RAW materializations pass pixel-buffer allocation and task submission, then fail completion. Both untruncated chains are:

```
CIRenderTaskWaitUntilCompleted / 1
  MTLCommandBufferErrorDomain / 8
    Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)
    IOGPUCommandQueueErrorDomain / 8
```

This identifies command-buffer out-of-memory in THIS run. Earlier c21 only exposed generic completion code1; its missing underlying chain cannot retrospectively be manufactured. It does not establish a connection to the private one-code Off-return difference. Existing materialization fails closed without caching or displaying the failed destination.

Serial RAW105scene/display pairs are exact. Both loaded RAW processes are incomplete, with all completed18/27pairs exact. Synthetic constant graphs pass60attempts each in serial and two fresh loaded processes:180materializations with exact signed/HDR32x32sampled readback. Loaded test bodies overlap9.3997624167s, not proof of simultaneous GPU work. The constant graph is much cheaper than RAW and retains planes differently; it does not establish spare RAW GPU memory or absence of memory pressure.

## What the existing budgets actually count

Source review at the unchanged c21 production tree:

- `Sources/LumenPipeline/DecodeMaterializer.swift`: admission bounds rounded width×height×8 nominal bytes,512MiB and16384long edge. Returned byte accounting uses the same nominal value, not actual CV row/data/IOSurface allocation. The destination and RAW working graph exist before successful publication.
- `Sources/LumenPipeline/AppleRawSource.swift`: heldDecodeBytes sums retained canonical planes. Cache eviction occurs after successful insertion; the in-flight destination and RAW/demosaic/denoise intermediates are outside that retained count. Framework/driver residency and another process are outside it too.
- `Sources/LumenApp/RenderCoordinator.swift` trims aggregate source-plane residency before source use and on render/export/sample exit. `Sources/LumenCore/Interaction/DecodeResidency.swift` orders cold-source release while preserving the active source. These guards are already present; no missing trim was invented.
- The direct reconstruction test bypasses that coordinator, but explicitly calls releaseDecodes on the original source before constructing the fresh source and releases each photo's sources at scope exit. It does not retain a catalogue-wide source registry. This bounds source-cache ownership, not backend residency; bypass alone does not explain the failure. Coordinator trimming cannot reclaim a peer process's GPU work or automatically bound an active RAW graph's intermediates.

The peer's held241,864,704bytes before its failed80,621,568-byte nominal new plane does not prove a retained-cache cap violation. Nor does zero held bytes in the primary imply zero GPU memory. RSS, nominal planes and actual GPU working residency are different measurements. Error-event context uptime is captured at the operation's start; do not subtract those reused context timestamps to invent task duration.

## Next causal evidence before production changes

1. Keep exact source/materializer/context/math and both-process load. Compare the current baseline with a TEST-ONLY arm releasing prior decode planes immediately before each new mode decode, without retrying failed operations. Keep every strict zero/Off-return/rebuild comparison, held bytes before/after and failure. A green cold-plane arm would expose a cache/latency tradeoff, not automatically justify shipping pre-eviction.
2. If both arms fail, compare concurrent FIRST-Off-only cold RAW decoding against the full mode/history workload. This separates retained modes/history from unavoidable RAW graph concurrency. Keep both failing and successful processes, not only completed pairs.
3. Record phase-specific RSS and available Metal currentAllocatedSize/recommendedMaxWorkingSetSize, actual CV row/data allocation versus nominal bytes, completion timing and nested errors. Establish exactly what each API measures; none alone is total device residency. Do not choose a new ceiling from this one hosted configuration.
4. Separately repeat the owner-photo displayed failure at the pinned stable source. For pixel attribution, compare the exact source-coordinate footprint feeding the differing displayed ROI before plans/dithering; the existing three32x32scene tiles do not cover all oriented displayed pixels. Keep actual single-instance GUI/coordinator acceptance separate from direct pipeline stress.

Do not guess a smaller/larger cap, serialize only one process and assume global admission, add a silent retry, switch precision, accept lazy first pixels, or loosen exact identity to hide this failure. A safe production memory change requires a causal contrast, preserved failure behavior/creative math, and measured latency/cancellation/recovery costs. No such repair is integrated here.
