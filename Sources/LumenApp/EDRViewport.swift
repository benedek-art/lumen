// EDRViewport.swift
// The HDR preview's two AppKit pieces: what the display can show above SDR white
// (`EDRDisplay`), and the layer that shows it (`EDRImageView`). The arithmetic between
// them — which white target to render, what the badge says, where the plate sits — is
// `EDRPreview` in LumenCore, where it is tested.
//
// docs/11 §"The EDR editing viewport" and docs/14 §7 are the spec: a `CAMetalLayer`
// with `wantsExtendedDynamicRangeContent`, fp16 extended-linear, headroom from
// `NSScreen.maximumExtendedDynamicRangeColorComponentValue`, re-read on
// `NSApplication.didChangeScreenParametersNotification`. This is the first slice of it:
//
//   · OPT-IN, from View ▸ HDR Preview. The spec's end state is "no mode switch"; until
//     the viewport has been looked at on real panels, the SDR loupe every proof record
//     and every instrument was built against stays the default, untouched.
//   · DISPLAY-ONLY. The SDR frame is still rendered for every request and is still
//     what `model.image` holds, so scopes, readout, clipping, peaking, the developed
//     preview cache and the before plates see exactly what they saw before. The EDR
//     frame replaces the SDR plate on screen and nowhere else.
//   · NO SLEW. docs/14 asks for the white target to glide over ~200 ms when headroom
//     changes; here a change of an eighth of a stop or more re-renders once.
//
// WHY THE LAYER SPANS THE CONTAINER. The SDR plate is a SwiftUI `Image` inside a stack
// that is scaled (`ZoomLayoutHold`'s pinch stretch), offset (the pan) and clipped by
// SwiftUI. A hosted AppKit view is not reliably transformed or clipped by those
// modifiers, so this view never asks to be: it is laid out at the container's size,
// draws the frame at the rectangle `EDRPreview.plateRect` computes from the same
// three numbers, and leaves everything outside it transparent.

#if os(macOS)

import AppKit
import CoreImage
import Foundation
import LumenCore
import LumenPipeline
import Metal
import QuartzCore
import SwiftUI

// MARK: - The display's headroom

/// The key screen's EDR headroom, published only when it moves by enough to change
/// what the viewport renders (`EDRPreview.quantizedStops`), so an ambient-light wobble
/// does not invalidate the loupe.
///
/// Not `@MainActor`, for `LoupeViewport`'s reason: `shared` is read from a view's
/// property initializer. The members that touch AppKit are.
final class EDRDisplay: ObservableObject {

    static let shared = EDRDisplay()

    /// `NSScreen.maximumExtendedDynamicRangeColorComponentValue` — what the screen can
    /// show RIGHT NOW. On most panels this is 1.0 until EDR content is on screen.
    @Published private(set) var current: Double = 1
    /// `maximumPotentialExtendedDynamicRangeColorComponentValue` — what it could show.
    /// 1.0 is an SDR display, where the preview falls back to the SDR frame.
    @Published private(set) var potential: Double = 1

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    /// Start or stop watching. Watching is a notification observer pair plus a
    /// one-second poll: AppKit posts `didChangeScreenParametersNotification` for a
    /// display change, but the headroom also rises on its own once an EDR layer is on
    /// screen (and falls with brightness and ambient light), and the poll is what
    /// catches that. Nothing runs while the preview is off.
    @MainActor
    func setActive(_ on: Bool) {
        guard on else {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            timer?.invalidate()
            timer = nil
            return
        }
        if observers.isEmpty {
            let center = NotificationCenter.default
            for name in [NSApplication.didChangeScreenParametersNotification,
                         NSWindow.didChangeScreenNotification] {
                observers.append(center.addObserver(forName: name, object: nil,
                                                    queue: .main) { [weak self] _ in
                    guard let self else { return }
                    MainActor.assumeIsolated { self.refresh() }
                })
            }
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated { self.refresh() }
            }
        }
        refresh()
    }

    /// Re-read the key window's screen. `NSScreen.main` is the screen holding the
    /// window with keyboard focus — the loupe's, whenever anyone is looking at it.
    @MainActor
    func refresh() {
        let screen = NSScreen.main
        let now = Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        let could = Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1)
        if EDRPreview.quantizedStops(EDRPreview.stops(componentValue: now))
            != EDRPreview.quantizedStops(EDRPreview.stops(componentValue: current)) {
            current = now
        }
        if EDRPreview.displayCanShowHDR(potentialComponentValue: could)
            != EDRPreview.displayCanShowHDR(potentialComponentValue: potential) {
            potential = could
        }
    }
}

// MARK: - The layer

/// One Metal device, queue and Core Image context for every EDR view — the loupe has
/// one, and a context per view would be a second set of GPU caches for nothing.
enum EDRMetal {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static let queue: MTLCommandQueue? = device?.makeCommandQueue()
    static let context: CIContext? = {
        guard let device else { return nil }
        var options: [CIContextOption: Any] = [
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ]
        if let space = PipelineRenderer.edrColorSpace {
            options[.workingColorSpace] = space
        }
        return CIContext(mtlDevice: device, options: options)
    }()
}

/// Draws one half-float, extended-linear frame into an EDR `CAMetalLayer` at a given
/// rectangle of the view. See the file header for why the view spans the container.
struct EDRImageView: NSViewRepresentable {
    /// The frame — `RenderResult.edrImage`, tagged `PipelineRenderer.edrColorSpace`.
    let image: CGImage
    /// Where it goes, in this view's points, top-left origin (`EDRPreview.plateRect`).
    let placement: CGRect
    /// `ProxyResampling.none`: magnified pixels stay square, as the SDR plate's do.
    let nearest: Bool
    /// The `[`/`]` inspection gain (`InspectionHolds.ev`), applied in linear light as
    /// `InspectionGain` applies it to the SDR plate. 0 with no hold down.
    let exposureEV: Double

    /// Whether this Mac can draw the EDR frame at all. Without a Metal device the
    /// loupe never asks for one, and the SDR plate is all there is.
    static var isSupported: Bool { EDRMetal.device != nil && EDRMetal.context != nil }

    func makeNSView(context: Context) -> EDRLayerView {
        let view = EDRLayerView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: EDRLayerView, context: Context) {
        view.show(image, at: placement, nearest: nearest, exposureEV: exposureEV)
    }
}

final class EDRLayerView: NSView {

    private var image: CGImage?
    private var placement: CGRect = .zero
    private var nearest: Bool = false
    private var exposureEV: Double = 0

    /// The layer this view is backed by. AppKit calls this when `wantsLayer` goes true.
    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = EDRMetal.device
        // Half-float, extended-linear sRGB, EDR on: values above 1.0 are light above
        // SDR white, up to whatever the screen's current headroom is. The layer does
        // NOT tone-map — anything above the headroom clips — which is why the white
        // target the frame was rendered at never exceeds it (`EDRPreview.whiteTarget`).
        layer.pixelFormat = .rgba16Float
        layer.colorspace = PipelineRenderer.edrColorSpace
        layer.wantsExtendedDynamicRangeContent = true
        // Core Image writes the drawable from compute; a framebuffer-only texture
        // cannot be a compute target.
        layer.framebufferOnly = false
        layer.isOpaque = false
        return layer
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        render()
    }

    /// Never a hit: the loupe's gestures belong to the SwiftUI canvas above and
    /// beside this view, and a layer that ate a click would take the pan with it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    func show(_ image: CGImage, at placement: CGRect, nearest: Bool, exposureEV: Double) {
        let changed = self.image !== image || self.placement != placement
            || self.nearest != nearest || self.exposureEV != exposureEV
        self.image = image
        self.placement = placement
        self.nearest = nearest
        self.exposureEV = exposureEV
        if changed { render() }
    }

    private func render() {
        guard let metal = layer as? CAMetalLayer,
              let image,
              let queue = EDRMetal.queue,
              let context = EDRMetal.context,
              let space = PipelineRenderer.edrColorSpace else { return }
        let scale: CGFloat = self.window?.backingScaleFactor ?? 2
        let size = CGSize(width: (bounds.width * scale).rounded(),
                          height: (bounds.height * scale).rounded())
        guard size.width >= 1, size.height >= 1,
              image.width > 0, image.height > 0 else { return }
        metal.contentsScale = scale
        if metal.drawableSize != size { metal.drawableSize = size }

        let target = EDRPreview.coreImageRect(placement, containerHeight: bounds.height,
                                              scale: scale)
        var picture = CIImage(cgImage: image)
        picture = nearest ? picture.samplingNearest() : picture.samplingLinear()
        if exposureEV != 0 {
            picture = picture.applyingFilter("CIExposureAdjust",
                                             parameters: [kCIInputEVKey: exposureEV])
        }
        let sx = target.width / CGFloat(image.width)
        let sy = target.height / CGFloat(image.height)
        picture = picture.transformed(by: CGAffineTransform(scaleX: sx, y: sy)
            .concatenating(CGAffineTransform(translationX: target.minX, y: target.minY)))
        let canvas = CGRect(origin: .zero, size: size)
        let composed = picture.composited(over: CIImage(color: CIColor.clear).cropped(to: canvas))

        guard let drawable = metal.nextDrawable(),
              let buffer = queue.makeCommandBuffer() else { return }
        context.render(composed, to: drawable.texture, commandBuffer: buffer,
                       bounds: canvas, colorSpace: space)
        buffer.present(drawable)
        buffer.commit()
    }
}

#endif
