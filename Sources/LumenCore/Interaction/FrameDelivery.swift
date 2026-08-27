// FrameDelivery.swift
// The law about which rendered frames reach the screen, and the arithmetic showing
// why "never start stale work" and "never discard finished work" are different rules
// that both have to hold.
//
// Why this exists. The owner's second session reported the exposure drag "goes by
// notches … not a smooth change or transition … changes in one frame instead of
// having a quick change as like a slope". The offered reading was render speed. The
// arithmetic says otherwise: drag events arrive every 8–16 ms, a draft render costs
// tens of milliseconds, and the viewer cancelled its render task on EVERY event —
// then threw away any frame whose task had been cancelled, checking after the render
// had already run. Under continuous motion every task is superseded before its frame
// lands, so every completed frame was paid for and then discarded, and the picture
// moved only when the hand paused for longer than one render. The notches were the
// hand's own micro-pauses. No draft speed can fix that loop: a renderer of ANY speed
// delivers zero frames while events keep arriving faster than it finishes.
//
// The two rules, separated:
//
//   · STARTING work is where staleness belongs. A request that is already superseded
//     when its turn comes — a newer event has claimed a ticket, or its task is
//     already cancelled — must be dropped before it pays for a decode. This is what
//     collapses a drag's backlog to at most one render in flight, and it stays.
//
//   · FINISHED work is never stale by cancellation. A frame that has already been
//     rendered is the freshest completed picture of the user's intent that exists;
//     the only questions left are identity and order — is it the photograph the
//     viewer is showing NOW, and is it newer than what is already on screen. A
//     30 ms-old exposure under a moving hand is what "keeping up" looks like; the
//     newer frame is already rendering and will land next.
//
// With both rules in place the steady state under a drag storm is: exactly one
// render in flight at all times, every completion delivered, screen cadence equal to
// the machine's own render cadence. The simulation in FrameDeliveryTests holds that
// as arithmetic: the old rule delivers 0 frames for the storm's whole duration, the
// new one delivers duration ÷ render-cost.

import Foundation

public enum FrameDelivery {

    /// Whether a render request should be STARTED when its turn on the pipeline
    /// comes. `newestRequested` is the highest ticket any request has claimed; a
    /// request below it is already superseded, and a cancelled task's request is a
    /// backlog entry whose newer sibling is right behind it in the queue.
    public static func shouldStart(taskCancelled: Bool,
                                   generation: UInt64,
                                   newestRequested: UInt64) -> Bool {
        !taskCancelled && generation >= newestRequested
    }

    /// Whether a COMPLETED frame should be shown. Cancellation is deliberately not an
    /// input: the work is done, and dropping it buys nothing but a frozen picture.
    /// The guards are identity and order alone —
    ///   · identity: the frame depicts the photograph the viewer wants NOW
    ///     (`currentRequest`, the url of the most recent request, whatever its state);
    ///   · order: the frame is newer than the newest frame already applied, so a slow
    ///     old render can never overwrite a fast new one.
    public static func shouldShow(frameFor url: URL,
                                  currentRequest: URL?,
                                  generation: UInt64,
                                  newestShown: UInt64) -> Bool {
        url == currentRequest && generation > newestShown
    }
}
