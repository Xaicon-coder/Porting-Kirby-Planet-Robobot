// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// The render surface: a CAMetalLayer-backed UIView handed to the core (MoltenVK presents into it).
// It also forwards single-finger touches to the emulated touch screen in drawable pixels.

import SwiftUI
import UIKit
import QuartzCore
import PlanetCore

/// SwiftUI wrapper around `MetalHostView`. The hosted view (and therefore its layer) must keep its
/// identity for the whole emulation session, so callers place it at a stable position in the tree.
struct MetalScreenView: UIViewRepresentable {
    /// Called once, the first time the layer has a non-zero size inside a window:
    /// (layer, drawable size in pixels, portrait).
    var onReady: @MainActor (CAMetalLayer, CGSize, Bool) -> Void

    func makeUIView(context: Context) -> MetalHostView {
        let view = MetalHostView(frame: .zero)
        view.onReady = onReady
        return view
    }

    func updateUIView(_ uiView: MetalHostView, context: Context) {
        uiView.onReady = onReady
    }

    static func dismantleUIView(_ uiView: MetalHostView, coordinator: ()) {
        uiView.endActiveTouch()
    }
}

/// UIView whose backing layer is the CAMetalLayer used by the emulator.
final class MetalHostView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    /// The render view currently in a window. In landscape the control overlay sits on top of it
    /// and forwards the touches that are not on a control (see GamepadOverlayUIView), so the
    /// touch screen works without relying on SwiftUI passing touches between representables.
    static weak var current: MetalHostView?

    var onReady: (@MainActor (CAMetalLayer, CGSize, Bool) -> Void)?

    // swiftlint:disable:next force_cast
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private var didReportReady = false
    private var lastDrawableSize: CGSize = .zero
    private var lastPortrait = false

    /// The finger currently driving the emulated stylus.
    private var activeTouch: UITouch?
    /// Whether the core accepted the touch (it started inside the bottom screen).
    private var touchAccepted = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        isOpaque = true
        isMultipleTouchEnabled = false
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        applyContentScale()
    }

    // MARK: Layout

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            endActiveTouch()
            if MetalHostView.current === self {
                MetalHostView.current = nil
            }
        } else {
            MetalHostView.current = self
            applyContentScale()
            setNeedsLayout()
        }
    }

    private func applyContentScale() {
        let scale = window?.windowScene?.screen.nativeScale ?? max(traitCollection.displayScale, 1)
        if contentScaleFactor != scale {
            contentScaleFactor = scale
        }
        layer.contentsScale = scale
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = layer.contentsScale
        let pixelSize = CGSize(
            width: (bounds.width * scale).rounded(),
            height: (bounds.height * scale).rounded()
        )
        guard pixelSize.width > 0, pixelSize.height > 0 else { return }
        let portrait = bounds.height > bounds.width

        if metalLayer.drawableSize != pixelSize {
            metalLayer.drawableSize = pixelSize
        }

        if !didReportReady {
            // Only start once the layer is attached to a window (MoltenVK needs a live surface).
            guard window != nil else { return }
            didReportReady = true
            lastDrawableSize = pixelSize
            lastPortrait = portrait
            onReady?(metalLayer, pixelSize, portrait)
        } else if pixelSize != lastDrawableSize || portrait != lastPortrait {
            lastDrawableSize = pixelSize
            lastPortrait = portrait
            EmulatorController.shared.updateDrawable(size: pixelSize, portrait: portrait)
        }
    }

    // MARK: Touch screen

    private func pixelPoint(for touch: UITouch) -> CGPoint {
        let location = touch.location(in: self)
        let scale = layer.contentsScale
        return CGPoint(x: location.x * scale, y: location.y * scale)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        forwardTouchBegan(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        forwardTouchMoved(touch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        forwardTouchEnded(touch)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        forwardTouchEnded(touch)
    }

    // MARK: Touches received by another view (the landscape control overlay)

    /// Starts driving the stylus with `touch` (its location is converted to this view).
    func forwardTouchBegan(_ touch: UITouch) {
        guard activeTouch == nil else { return }
        activeTouch = touch
        touchAccepted = EmulatorController.shared.touchBegan(at: pixelPoint(for: touch))
    }

    func forwardTouchMoved(_ touch: UITouch) {
        guard activeTouch === touch else { return }
        let point = pixelPoint(for: touch)
        if touchAccepted {
            EmulatorController.shared.touchMoved(to: point)
        } else {
            // A drag that started outside the bottom screen begins touching once it slides in.
            touchAccepted = EmulatorController.shared.touchBegan(at: point)
        }
    }

    func forwardTouchEnded(_ touch: UITouch) {
        guard activeTouch === touch else { return }
        endActiveTouch()
    }

    /// Lifts the emulated stylus if a finger is down.
    func endActiveTouch() {
        guard activeTouch != nil else { return }
        activeTouch = nil
        if touchAccepted {
            EmulatorController.shared.touchEnded()
        }
        touchAccepted = false
    }
}
