# RAW memory-retention contrasts at d55d685

Source: d55d685334d098effefe3ff6a329ab03845fbb36.
[Executed workflow39183832537/job117841996018](https://github.com/benedek-art/lumen/actions/runs/39183832537/job/117841996018).
macOS15.7.9 build24G830, arm64, Xcode16.4, Swift6.1.2.

The optimized test compiled and ALL nine independent test processes executed. The job correctly remains RED: five loaded processes stopped at failed native materialization. Subsequent green outcomes do not erase incomplete processes.

| Arm | Process | Renders | Exact completed pairs | AI0 center-ROI checks | File-passes | Result |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| baseline | serial |190|105|10|10|PASS|
| baseline | loaded primary |38|18|2|2|OOM/incomplete|
| baseline | loaded peer |103|48|6|5|OOM/incomplete|
| release-before-request | serial |190|105|10|10|PASS|
| release-before-request | loaded primary |38|18|2|2|OOM/incomplete|
| release-before-request | loaded peer |190|105|10|10|PASS|
| first-Off-only | serial |30|15|0|10|PASS|
| first-Off-only | loaded primary |9|0|0|3|OOM/incomplete|
| first-Off-only | loaded peer |12|0|0|4|OOM/incomplete|

Total800render records and414completed scene/display comparison pairs, all completed pairs exact. Forty completed explicit AI0 center-ROI comparisons are exact; this is not120ROI checks. Full-arm strict Off-return/rebuild/fresh-source checks remain independent. The first-Off-only arm has no AI0/Off-return history and cannot qualify it.

Release intervention executed243request-entry releases across its three processes (110/23/110). All reported source-owned nominal cache bytes zero after release and matched returned nominal release counts. This does not measure actual GPU reclamation, RAW intermediate memory or backend/driver residency. Independent PIDs/wrapper load are known; actual body overlap is unknown because each loaded arm has at least one process without a summary. GPU concurrency is not inferred from process lifetime.

## Five materialization failures

All pass CV buffer allocation and task submission, then fail waitUntilCompleted with untruncated chain CIRenderTaskWaitUntilCompleted/code1 → MTLCommandBufferErrorDomain/code8, Insufficient Memory/kIOGPUCommandBufferCallbackErrorOutOfMemory → IOGPUCommandQueueErrorDomain/code8.

- baseline primary: public2607, pass0 first-Off/region0, held0; nominal new3680×2760×8bytes.
- baseline peer: public5812, pass1 AI50/region0, held165347328; nominal new3712×5568×8bytes.
- release primary: public2607, pass0 first-Off/region0, held0.
- cold-Off primary: public4671, pass0 first-Off/region0, held0.
- cold-Off peer: public5812, pass0 first-Off/region0, held0.

Recorded failure wrapper elapsed milliseconds:865.776375,218.201,1450.733292,2015.82625,3192.455417 respectively. These include admission/allocation/task waiting and synchronous diagnostic observer/logging overhead; they are not isolated GPU completion latency. allocatedBytes0 on nil denotes no returned successful plane, not CV allocation refusal.

## Decision and limits

Simple prior-plane eviction is NOT sufficient on this hosted configuration. Cold-Off-only failures establish that denoise-mode history is not necessary for this stress failure. One surviving release peer does not establish a production policy improvement: order/timing/backend residency differ. No cap/precision/format/default change or silent retry is justified.

This is a direct pipeline diagnostic with independent loaded processes. It bypasses the shipped RenderCoordinator, which already serializes its own synchronous actor work and trims aggregate source-cache ownership before use and on operation exit. Its budget counts nominal retained planes, not peak working GPU memory. An app cannot guarantee success against arbitrary peer allocation. This run neither demonstrates failure of that coordinator budget nor guarantees single-app memory/cancellation/refusal/recovery acceptance.

Eligible materialization still fails closed, without caching/displaying a failed destination. The existing public canonical-refusal/recovery test proves a later explicit request may succeed and then reuse exactly its canonical image; it is not a silent in-operation retry. Native single-app peak/responsiveness and cancellation/recovery remain gates. The historical private one-code Off-return finding is not attributed to this OOM.

The next controlled TEST-ONLY question is task partitioning into the same full RGBAh destination using the same production pipeline CIContext, with exact synthetic coordinate/partial-edge controls and public sampled cross-arm identities before any production proposal. Tiling may fail, cost repeated RAW work or change pixels; it is an experiment, not an accepted remedy. RAW9 must not lose its independent evaluation boundary.

## Evidence and reproduction

The full public job transcript and parsed summary are archived beside this report. Original artifact12157945352 has GitHub-provided digest sha256:e672e65ca15f825267979fdfc7408e461e9ceb5de93b120bc125e88a8b595d33 and includes per-process logs/JSON/status/diagnostic records (expires2026-11-02). Binary artifact extraction was unavailable in the disconnected cloud executor; no claim is made that all21/other expected archive files were downloaded/hashed locally. Parsed evidence here comes from the actual completed workflow log.

Build: swift test -c release --list-tests
Serial selector:
LUMEN_DECODE_RECONSTRUCTION=1 LUMEN_AUDIT_RAW_DIR=/verified/CC0/corpus LUMEN_DECODE_RECONSTRUCTION_ARM=baseline swift test -c release --filter DecodeReconstructionContinuityTests/testOrderedNativeOffReturnAndExplicitReconstructionRemainIdentical

Use release-before-request or first-off-only for the other arms; the pinned workflow launches serial and two fresh xcrun xctest processes per arm and validates all nine outcomes. Corpus bytes/SHA/license checks and public-error opt-in remain in that workflow. Private assets are not used or uploaded. Unchanged synthetic constant checks were intentionally skipped, not counted as new passes.
