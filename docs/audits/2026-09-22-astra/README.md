# Lumen independent Astra audit — 22 September 2026

Start with [the build-context handoff](START-HERE.md), then [the full written audit and finding index](Lumen-Audit.md).

This documentation preserves the owner's product goals, branch uncertainty, findings, reproduction evidence, actual coverage limits and proposed repair order for future development. **It does not implement fixes or certify the app as ready to replace Lightroom.**

## Contents

- [START-HERE.md](START-HERE.md): context, limitations, priorities and a resume prompt for the next developer/agent.
- [Lumen-Audit.md](Lumen-Audit.md): assessment and all 47 prioritized findings.
- [Lumen-Audit.html](Lumen-Audit.html): downloadable interactive text-only dashboard. GitHub displays HTML as source; download the audit folder and open this file locally to use its filters.
- [findings.json](findings.json): structured finding IDs, evidence scope, locations and branch applicability.
- [control-inventory.json](control-inventory.json): 327 recorded roles, including overlap and explicitly marked unavailable fields—not 327 visually certified sliders.
- [Detailed reports](details/overview.md): [colour/RAW](details/colour-raw.md), [masks/detail/creative](details/masks-spatial.md), [reliability/performance](details/reliability.md), [UI](details/ui-inspection.md) and [test results](details/test-results.md).
- [Evidence guide](evidence/README.md): probe source, measured results and executed test logs.
- [Publication manifest](PUBLICATION-MANIFEST.json): public file hashes and excluded image directories. This README and the manifest itself are packaging additions.

## Coverage and branch warning

This was a broad whole-app engineering audit with deep investigation of selected areas, **not an exhaustive top-to-bottom verification**. No percentage of the app audited was measured. Distinguish source-traced controls from actual pixel probes and native UI tests. No calibrated Lightroom comparison or broad multi-camera certification was performed.

The two audited revisions were main `99c37272b42c211a04262ceb98cfb39355d1ab99` and Claude branch `a6e694103a3676e059847ac48b82c0031281ea53`. The installed build's branch is unknown. Three findings are already fixed on the newer branch; two catalog findings are new there. Re-check the current code before beginning repairs.

## Public edition and historical record

This repository is public. Personal RAWs, XMP sidecars, image comparisons, thumbnails, all application screenshots, catalogs, executable binaries and compiler caches were **not uploaded**. The dashboard uses explicit placeholders where private image evidence was displayed. Numerical photo-probe results and fixture filenames remain so the findings can be understood and correlated with the owner's private fixtures. Identifying local usernames and temporary FileProvider paths were sanitized.

The owner's complete visual edition remains in the local task's `outputs` folder. References to PNG evidence in reports identify those private artifacts; their absence from GitHub is intentional. Public HTML/Markdown copies retain original historical statements about the audit being local and about no commits being made during the audit. This later documentation publication does not change that historical scope. It does not upload the private images.

Probe sources have machine-specific paths, now partly sanitized. They are evidence harnesses, not a portable one-command test package. Adapt paths to an isolated library when reproducing. Never run failure-injection probes against a real user catalog or originals.

No application source, workflow, release configuration or dependency is changed by this documentation bundle. Uploading the audit is not authorization to implement its recommendations, merge the newer application branch or publish a new app build.
