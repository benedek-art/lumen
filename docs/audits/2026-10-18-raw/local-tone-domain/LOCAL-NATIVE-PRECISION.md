# Native contrast-delta precision correction

This is a scoped correction to isolated candidate `a6eb274a94fb71272dd47d4d11ade182c2e58405`, not closure of the wheel Amount or RAW-memory gates. No private photographs or measurements are included here.

## Reproduced synthetic failure

The original candidate passed its hosted native workflows, including [local tone boundary](https://github.com/benedek-art/lumen/actions/runs/39184651640). On the owner's ARM64 macOS 27.0.1 (26A434), Xcode 27.1 (27A9275), Apple Swift 6.4, the unchanged six-method `ExactLocalToneBoundaryTests` instead produced **16 genuine assertions in one method**. The other five methods passed.

All failures were the generated opposing-tone fixture, mask/group Amount 100 or 200, table sizes 33/65, against both the independent equation and unchanged CPU reference. Maximum error was **0.001953125**, exceeding the unchanged **0.001** absolute gate. All 224 tone configurations, 80 alpha/order configurations and 12 completed-cost records executed. This is synthetic numerical evidence, not a photograph or camera-calibration result. Different runtime/hardware/toolchain variables prevent an OS-only explanation.

## Algebraic correction

Let `d = t - pivot`, `s = slope`, and `h = shoulder`. The contrast contribution is:

```
mapped(t) - t
= pivot + d * (s + (1 - s) * h) - t
= d * (s - 1) * (1 - h)
```

The new expression computes the contribution directly, avoiding cancellation of large EV values. It retains exact zero when the shoulder is saturated, without an Amount cutoff, new domain bound, changed anchor or changed tone operator. Both the GPU source and its Float twin use the same factored expression. The Double reference and tests are unchanged. No claim about a particular compiler instruction/fusion mechanism is needed for this before/after result.

After the correction, all six native methods passed: **224** tone configurations, maximum CPU/equation error **0.0001220703125**; **80** alpha/order configurations, maximum CPU error **0.000396728515625**; **12** completed-cost records. Neutral, nonopaque and former-table controls also passed. The existing 70-method `KernelGoldenTests` passed without golden changes. The separate strict wheel diagnostic still failed one parity assertion, with its original 286.719970703125 epsilon-domain gap; it was not weakened or relabelled as accepted.

This report records the local before/after execution. The later exact committed source is recompiled and rechecked before photo acceptance. No release, main merge or installed-app replacement is authorized by this result.

## Public RAW memory contrast, separately

Before this tone candidate was built, frozen production Sources tree `06525f4828a15099f4cee51daee22589832f3820` and test head `41e4494a1812080d34584f313ef91e972b1269c0` completed the cloud workflow's same five SHA/length-verified CC0 fixtures (1346, 2349, 2607, 4671, 5812) locally. Each baseline, release-before-request and first-Off-only arm ran serially and with two peer processes: **9 process runs, 1230 renders, 675 exact scene/display pair records**, all expected counts complete and no failures. Local physical memory was 16 GiB; per-process `time -l` maximum RSS ranged 276611072–436338688 bytes. RSS is not total GPU working allocation. Body overlap is not proof of simultaneous GPU execution.

The hosted OOM remains valid and unresolved. The matched corpus narrows the input difference, but hardware/runtime/toolchain and concurrent system usage still differ. This is no proof of an OS-only cause or justification for a guessed cache cap, precision fallback or production memory repair. Private-photo runs and their evidence remain local.
