# October 7 — updater robustness (APP-05–07)

The updater previously ignored a failed replacement-app launch and terminated the current process anyway. It also hashed the downloaded archive and copied/replaced bundles synchronously on MainActor, while extracted temporary bundles were never cleaned.

- Relaunch now terminates only after NSWorkspace reports launch success. On error it keeps the current process running and says the update installed but relaunch failed, with a manual reopen action.
- Archive size/hash verification runs in detached utility work and streams 1 MiB chunks rather than loading the complete zip. Verification still completes before archive extraction.
- Copy staging and same-volume atomic bundle replacement run in detached utility work, preserving the current destination until staging succeeds. Staging cleanup remains on every exit.
- Extraction scratch lifetime now awaits cleanup after success or thrown extraction/signature/replacement errors. File-heavy cleanup also runs away from the UI actor.

Validation: native macOS compile and 15 focused tests passed, zero failures (`UpdateFileWork|UpdateDecision|UpdaterMainActor`). Six new behavioral tests cover failed launch without termination; launch-before-termination ordering; scratch cleanup on success/failure; streamed verification over multiple chunks plus size/hash refusals; real successful replacement of disposable bundle directories; staging failure preserving old contents and removing staging residue. Existing atomic-replacement source scan moved with file-work implementation. `git diff --check` passed.

Log: `/private/tmp/lumen-oct07-updater-final.log`. No actual application install, release publishing or process launch performed. Real installation on a mounted/read-only/slow volume and NSWorkspace relaunch remain manual packaging gates. Existing process completion handling remains asynchronous; timeout/cancel controls are a future enhancement.
