# TEST-ONLY task partition experiment

Production source is exactly d55d685 /84c8e15, unchanged. This follows the executed memory-contrasts-d55d685 result: simple cache release did not prevent loaded OOM, and Off-only history-free work still failed. Independent-process stress is not the shipped actor/coordinator; existing nominal retained-cache trimming and explicit refusal remain separate single-app guarantees/gates.

This isolated test compares original whole production materialization with1024/2048tile tasks into the SAME full RGBAh CV destination, using the EXACT shared DecodeMaterializer.context, named working space, unclamped destination and origin restoration. These sizes are experimental arms, not a recommended production cap or accepted remedy. No retry or failure substitution is added. RAW9 is explicitly refused by the experimental helper because its private, distinct evaluation context cannot be reused; it is not tested by silently changing color spaces.

Every process first compares both partition sizes with the whole production path on EVERY8,466,572Float component of a2053×1031 signed/HDR2Dpattern translated to(13,-7), including partial tile edges. This qualifies partition coordinates against the production baseline, not absolute orientation against the original bitmap. Synthetic resources leave their autorelease scope before RAW work; backend reclamation is not asserted.

Five verified CC0 RAWs are rendered Off-only in forward/reverse order. Each process requires126sample records and63actual-Data cross-order identities, with3displayROIs perfile-pass plus64×64center/seam windows. Workflow compares SHA256+bytecount+dimensions/bounds across all arms/processes against the whole-serial reference. Display digest scope is explicitly an8bpc sRGB redraw, with original delivery bit depths logged; it does not certify arbitrary higher-precision/wide-gamut CGImage provider bytes. Scene and seam proof is sampled, not whole-sensor identity. The local worker's full displayed-footprint diagnostic remains a separate gate.

Each arm runs serial and two fresh peers. All nine outcomes and partial failures are classified before assertions; nonfinite/unwritten checked readbacks fail. The workflow requires positive test-body, RAW-workload and completed RAW materializer-wrapper overlap for complete loaded runs. These are measured CPU intervals, not proof of simultaneous GPU execution. Synthetic setup is identical between arms and warms the shared context; this is not a cold-process/filesystem decode benchmark.

Actual CV row/data allocation metadata (where exposed), nominal bytes, per-task elapsed costs and bounded nested errors are recorded. No peak total-GPU/RSS metric or actual reclamation is claimed. Source allocation metadata can be unavailable for a transformed CIImage; no zero-byte inference is made.

The workflow also downloads the earlier PUBLIC d55d685 artifact using read-only Actions access, prints individual text-file hashes and actual process/body/completed-render costs, and does not rerun the previous question for timing. Only public logs/JSON are accepted; no images or owner assets are used. New synthetic/RAW outcomes remain unexecuted until hosted native CI finishes.

Reproduce after building optimized discovery with swift test -c release --list-tests:
LUMEN_MATERIALIZATION_PARTITION=1 LUMEN_AUDIT_RAW_DIR=/verified/CC0/corpus LUMEN_MATERIALIZATION_PARTITION_ARM=whole swift test -c release --filter NativeMaterializationPartitionTests/testSharedContextTaskPartitionPreservesSampledNativeOff

Use tile1024/tile2048 for alternate TEST-ONLY arms. A green partition arm would still require preserved failure/precision, actual single-app cancellation/recovery, RAW9 coverage, performance and private/native acceptance before any production proposal. No shipping change is included.
