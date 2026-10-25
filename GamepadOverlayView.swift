// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// On-screen 3DS controls drawn with Core Animation layers and driven by raw UITouch tracking
// (multi-touch, sliding between face buttons, analog circle pad or 8-way D-pad).

import SwiftUI
import UIKit
import PlanetCore

/// SwiftUI wrapper around `GamepadOverlayUIView`.
struct GamepadOverlay: UIViewRepresentable {
    /// Portrait: the controls fill the area below the screens.
    /// Landscape: the overlay covers the whole render view; controls sit at the sides.
    var isPortrait: Bool
    var opacity: Double
    var leftStyle: LeftControlStyle

    func makeUIView(context: Context) -> GamepadOverlayUIView {
        let view = GamepadOverlayUIView(frame: .zero)
        view.configure(isPortrait: isPortrait, opacity: opacity, leftStyle: leftStyle)
        return view
    }

    func updateUIView(_ uiView: GamepadOverlayUIView, context: Context) {
        uiView.configure(isPortrait: isPortrait, opacity: opacity, leftStyle: leftStyle)
    }

    static func dismantleUIView(_ uiView: GamepadOverlayUIView, coordinator: ()) {
        uiView.releaseAll()
    }
}

/// UIKit implementation of the touch controls.
final class GamepadOverlayUIView: UIView {
    private enum TouchRole {
        case leftControl
        case faceCluster
        case single(PPButton)
    }

    // MARK: Configuration

    private var isPortraitLayout = true
    /// Landscape only: the finger that is not on a control and is forwarded to the render view
    /// underneath as an emulated touch-screen touch.
    private var screenTouch: UITouch?
    private var controlsOpacity: Double = 0.6
    private var leftStyle: LeftControlStyle = .circlePad
    private var needsRebuild = true
    private var lastLayoutSize: CGSize = .zero

    // MARK: Geometry (view coordinates, points)

    private var leftCenter: CGPoint = .zero
    private var leftRadius: CGFloat = 0
    private var faceCenter: CGPoint = .zero
    private var faceOffset: CGFloat = 0
    private var faceButtonRadius: CGFloat = 0
    private var faceCenters: [PPButton: CGPoint] = [:]
    private var singleRects: [PPButton: CGRect] = [:]

    // MARK: Layers

    private let controlsLayer = CALayer()
    private var buttonLayers: [PPButton: CAShapeLayer] = [:]
    private var dpadArmLayers: [PPButton: CAShapeLayer] = [:]
    private var stickKnobLayer: CAShapeLayer?

    private let normalFill = UIColor(white: 1, alpha: 0.16).cgColor
    private let baseFill = UIColor(white: 1, alpha: 0.08).cgColor
    private let knobFill = UIColor(white: 1, alpha: 0.38).cgColor
    private let pressedFill = PortTheme.accentUIColor.withAlphaComponent(0.8).cgColor
    private let strokeColor = UIColor(white: 1, alpha: 0.7).cgColor
    private let labelColor = UIColor(white: 1, alpha: 0.92).cgColor
    private let arrowColor = UIColor(white: 1, alpha: 0.85).cgColor

    // MARK: Touch state

    private var touchRoles: [UITouch: TouchRole] = [:]
    private var touchButtons: [UITouch: Set<PPButton>] = [:]
    private var pressedButtons: Set<PPButton> = []
    private var stickTouch: UITouch?
    private var stickVector: CGVector = .zero

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = true
        controlsLayer.opacity = Float(controlsOpacity)
        layer.addSublayer(controlsLayer)
    }

    /// Applies the SwiftUI-side configuration. Cheap when nothing changed.
    func configure(isPortrait: Bool, opacity: Double, leftStyle: LeftControlStyle) {
        let clampedOpacity = min(max(opacity, 0.15), 1)
        if clampedOpacity != controlsOpacity {
            controlsOpacity = clampedOpacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            controlsLayer.opacity = Float(clampedOpacity)
            CATransaction.commit()
        }
        if isPortrait != isPortraitLayout || leftStyle != self.leftStyle {
            releaseAll()
            isPortraitLayout = isPortrait
            self.leftStyle = leftStyle
            needsRebuild = true
            setNeedsLayout()
        }
    }

    // MARK: View lifecycle

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            releaseAll()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            // Text layers depend on the screen scale.
            needsRebuild = true
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        controlsLayer.frame = bounds
        CATransaction.commit()

        guard needsRebuild || bounds.size != lastLayoutSize else { return }
        if bounds.size != lastLayoutSize {
            // Geometry changes under the fingers: start from a clean state.
            releaseAll()
        }
        lastLayoutSize = bounds.size
        needsRebuild = false
        computeGeometry()
        rebuildLayers()
    }

    // MARK: Geometry

    private func computeGeometry() {
        let width = bounds.width
        let height = bounds.height
        faceCenters = [:]
        singleRects = [:]
        guard width > 60, height > 60 else {
            leftRadius = 0
            faceOffset = 0
            faceButtonRadius = 0
            return
        }

        let margin: CGFloat = 12
        let shoulderHeight: CGFloat = 34
        let smallHeight: CGFloat = 28
        let pillSize = CGSize(width: 66, height: 26)

        if isPortraitLayout {
            leftRadius = min(max(min(width * 0.17, height * 0.27), 34), 92)
            faceOffset = min(max(min(width * 0.105, height * 0.165), 24), 62)
            faceButtonRadius = faceOffset * 0.56
            let midY = (height * 0.54).rounded()
            leftCenter = CGPoint(x: margin + leftRadius + 8, y: midY)
            faceCenter = CGPoint(x: width - margin - faceOffset - faceButtonRadius - 8, y: midY)

            layoutShoulders(
                width: width,
                top: margin,
                margin: margin,
                shoulderSize: CGSize(width: min(width * 0.22, 130), height: shoulderHeight),
                smallSize: CGSize(width: min(width * 0.13, 76), height: smallHeight)
            )

            let pillY = height - margin - pillSize.height
            singleRects[.select] = CGRect(
                x: width / 2 - 8 - pillSize.width, y: pillY,
                width: pillSize.width, height: pillSize.height
            )
            singleRects[.start] = CGRect(
                x: width / 2 + 8, y: pillY,
                width: pillSize.width, height: pillSize.height
            )
        } else {
            leftRadius = min(max(min(height * 0.16, width * 0.085), 34), 92)
            faceOffset = min(max(min(height * 0.105, width * 0.055), 24), 62)
            faceButtonRadius = faceOffset * 0.56
            let midY = (height * 0.55).rounded()
            let sideInset = margin + 10
            leftCenter = CGPoint(x: sideInset + leftRadius, y: midY)
            faceCenter = CGPoint(x: width - sideInset - faceOffset - faceButtonRadius, y: midY)

            // The top-right corner hosts the pause button, so the shoulders sit a bit lower.
            let shoulderWidth = min(max(leftRadius * 1.5, 72), width * 0.16)
            layoutShoulders(
                width: width,
                top: margin + 46,
                margin: margin,
                shoulderSize: CGSize(width: shoulderWidth, height: shoulderHeight),
                smallSize: CGSize(width: min(shoulderWidth * 0.62, 64), height: smallHeight)
            )

            let pillY = height - margin - pillSize.height
            singleRects[.select] = CGRect(
                x: leftCenter.x - pillSize.width / 2, y: pillY,
                width: pillSize.width, height: pillSize.height
            )
            singleRects[.start] = CGRect(
                x: faceCenter.x - pillSize.width / 2, y: pillY,
                width: pillSize.width, height: pillSize.height
            )
        }

        // 3DS diamond: A right, B bottom, X top, Y left.
        faceCenters = [
            .a: CGPoint(x: faceCenter.x + faceOffset, y: faceCenter.y),
            .b: CGPoint(x: faceCenter.x, y: faceCenter.y + faceOffset),
            .x: CGPoint(x: faceCenter.x, y: faceCenter.y - faceOffset),
            .y: CGPoint(x: faceCenter.x - faceOffset, y: faceCenter.y),
        ]
    }

    private func layoutShoulders(width: CGFloat, top: CGFloat, margin: CGFloat, shoulderSize: CGSize, smallSize: CGSize) {
        let smallTop = top + (shoulderSize.height - smallSize.height) / 2
        let left = CGRect(x: margin, y: top, width: shoulderSize.width, height: shoulderSize.height)
        let right = CGRect(
            x: width - margin - shoulderSize.width, y: top,
            width: shoulderSize.width, height: shoulderSize.height
        )
        singleRects[.l] = left
        singleRects[.r] = right
        singleRects[.zl] = CGRect(x: left.maxX + 8, y: smallTop, width: smallSize.width, height: smallSize.height)
        singleRects[.zr] = CGRect(
            x: right.minX - 8 - smallSize.width, y: smallTop,
            width: smallSize.width, height: smallSize.height
        )
    }

    // MARK: Drawing

    private var overlayDisplayScale: CGFloat {
        window?.windowScene?.screen.scale ?? max(traitCollection.displayScale, 1)
    }

    private func rebuildLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        controlsLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        buttonLayers.removeAll()
        dpadArmLayers.removeAll()
        stickKnobLayer = nil
        guard leftRadius > 0 else { return }

        let scale = overlayDisplayScale

        switch leftStyle {
        case .circlePad:
            buildCirclePad()
        case .dPad:
            buildDPad()
        }

        let faceFont = max(14, faceButtonRadius * 0.85)
        for (button, center) in faceCenters {
            let path = UIBezierPath(
                arcCenter: center, radius: faceButtonRadius,
                startAngle: 0, endAngle: .pi * 2, clockwise: true
            ).cgPath
            let shape = makeShape(path, fill: normalFill, stroke: strokeColor)
            controlsLayer.addSublayer(shape)
            buttonLayers[button] = shape
            controlsLayer.addSublayer(makeLabel(Self.title(for: button), center: center, fontSize: faceFont, scale: scale))
        }

        for (button, rect) in singleRects {
            let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).cgPath
            let shape = makeShape(path, fill: normalFill, stroke: strokeColor)
            controlsLayer.addSublayer(shape)
            buttonLayers[button] = shape
            let fontSize: CGFloat
            switch button {
            case .l, .r: fontSize = 15
            case .zl, .zr: fontSize = 12
            default: fontSize = 10
            }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            controlsLayer.addSublayer(makeLabel(Self.title(for: button), center: center, fontSize: fontSize, scale: scale))
        }

        applyPressedVisuals()
        updateKnobPosition()
    }

    private func buildCirclePad() {
        let baseRect = CGRect(
            x: leftCenter.x - leftRadius, y: leftCenter.y - leftRadius,
            width: leftRadius * 2, height: leftRadius * 2
        )
        controlsLayer.addSublayer(makeShape(UIBezierPath(ovalIn: baseRect).cgPath, fill: baseFill, stroke: strokeColor))

        let knobRadius = leftRadius * 0.46
        let knob = CAShapeLayer()
        knob.bounds = CGRect(x: 0, y: 0, width: knobRadius * 2, height: knobRadius * 2)
        knob.path = UIBezierPath(ovalIn: knob.bounds).cgPath
        knob.fillColor = knobFill
        knob.strokeColor = strokeColor
        knob.lineWidth = 2
        knob.position = leftCenter
        controlsLayer.addSublayer(knob)
        stickKnobLayer = knob
    }

    private func buildDPad() {
        let center = leftCenter
        let radius = leftRadius
        let armWidth = radius * 0.64
        let half = armWidth / 2
        let armLength = radius - half
        let corner = CGSize(width: armWidth * 0.22, height: armWidth * 0.22)

        let arms: [(PPButton, CGRect, UIRectCorner)] = [
            (.up, CGRect(x: center.x - half, y: center.y - radius, width: armWidth, height: armLength), [.topLeft, .topRight]),
            (.down, CGRect(x: center.x - half, y: center.y + half, width: armWidth, height: armLength), [.bottomLeft, .bottomRight]),
            (.left, CGRect(x: center.x - radius, y: center.y - half, width: armLength, height: armWidth), [.topLeft, .bottomLeft]),
            (.right, CGRect(x: center.x + half, y: center.y - half, width: armLength, height: armWidth), [.topRight, .bottomRight]),
        ]

        let hub = CGRect(x: center.x - half, y: center.y - half, width: armWidth, height: armWidth)
        controlsLayer.addSublayer(makeShape(UIBezierPath(rect: hub).cgPath, fill: normalFill, stroke: nil))

        let arrowDistance = half + armLength / 2
        for (button, rect, corners) in arms {
            let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: corner).cgPath
            let shape = makeShape(path, fill: normalFill, stroke: strokeColor)
            controlsLayer.addSublayer(shape)
            dpadArmLayers[button] = shape

            let arrowCenter: CGPoint
            switch button {
            case .up: arrowCenter = CGPoint(x: center.x, y: center.y - arrowDistance)
            case .down: arrowCenter = CGPoint(x: center.x, y: center.y + arrowDistance)
            case .left: arrowCenter = CGPoint(x: center.x - arrowDistance, y: center.y)
            default: arrowCenter = CGPoint(x: center.x + arrowDistance, y: center.y)
            }
            let arrow = makeShape(trianglePath(center: arrowCenter, size: armWidth * 0.42, direction: button), fill: arrowColor, stroke: nil)
            controlsLayer.addSublayer(arrow)
        }
    }

    private func trianglePath(center: CGPoint, size: CGFloat, direction: PPButton) -> CGPath {
        let h = size / 2
        let path = UIBezierPath()
        switch direction {
        case .up:
            path.move(to: CGPoint(x: center.x, y: center.y - h))
            path.addLine(to: CGPoint(x: center.x + h, y: center.y + h * 0.6))
            path.addLine(to: CGPoint(x: center.x - h, y: center.y + h * 0.6))
        case .down:
            path.move(to: CGPoint(x: center.x, y: center.y + h))
            path.addLine(to: CGPoint(x: center.x - h, y: center.y - h * 0.6))
            path.addLine(to: CGPoint(x: center.x + h, y: center.y - h * 0.6))
        case .left:
            path.move(to: CGPoint(x: center.x - h, y: center.y))
            path.addLine(to: CGPoint(x: center.x + h * 0.6, y: center.y - h))
            path.addLine(to: CGPoint(x: center.x + h * 0.6, y: center.y + h))
        default:
            path.move(to: CGPoint(x: center.x + h, y: center.y))
            path.addLine(to: CGPoint(x: center.x - h * 0.6, y: center.y + h))
            path.addLine(to: CGPoint(x: center.x - h * 0.6, y: center.y - h))
        }
        path.close()
        return path.cgPath
    }

    private func makeShape(_ path: CGPath, fill: CGColor?, stroke: CGColor?) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.frame = controlsLayer.bounds
        shape.path = path
        shape.fillColor = fill
        shape.strokeColor = stroke
        shape.lineWidth = stroke == nil ? 0 : 2
        return shape
    }

    private func makeLabel(_ text: String, center: CGPoint, fontSize: CGFloat, scale: CGFloat) -> CATextLayer {
        let label = CATextLayer()
        label.string = text
        label.font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
        label.fontSize = fontSize
        label.foregroundColor = labelColor
        label.alignmentMode = .center
        label.contentsScale = scale
        label.isWrapped = false
        let height = ceil(fontSize * 1.25)
        let width = ceil(fontSize * CGFloat(max(text.count, 1)) * 0.8) + 12
        label.frame = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        return label
    }

    private static func title(for button: PPButton) -> String {
        switch button {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .l: return "L"
        case .r: return "R"
        case .zl: return "ZL"
        case .zr: return "ZR"
        case .start: return "START"
        case .select: return "SELECT"
        default: return ""
        }
    }

    private func applyPressedVisuals() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (button, shape) in buttonLayers {
            shape.fillColor = pressedButtons.contains(button) ? pressedFill : normalFill
        }
        for (button, shape) in dpadArmLayers {
            shape.fillColor = pressedButtons.contains(button) ? pressedFill : normalFill
        }
        stickKnobLayer?.fillColor = stickTouch != nil ? pressedFill : knobFill
        CATransaction.commit()
    }

    private func updateKnobPosition() {
        guard let knob = stickKnobLayer else { return }
        let travel = leftRadius * 0.58
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        knob.position = CGPoint(
            x: leftCenter.x + stickVector.dx * travel,
            y: leftCenter.y - stickVector.dy * travel
        )
        knob.fillColor = stickTouch != nil ? pressedFill : knobFill
        CATransaction.commit()
    }

    // MARK: Hit testing

    private func role(at point: CGPoint) -> TouchRole? {
        for (button, rect) in singleRects where rect.insetBy(dx: -4, dy: -10).contains(point) {
            return .single(button)
        }
        if faceOffset > 0, distance(point, faceCenter) <= faceOffset + faceButtonRadius * 1.45 {
            return .faceCluster
        }
        if leftRadius > 0, distance(point, leftCenter) <= leftRadius * 1.35 {
            return .leftControl
        }
        return nil
    }

    /// Portrait: only the control regions capture touches (the overlay has its own area).
    /// Landscape: the overlay covers the render view, so it takes every touch and forwards the
    /// ones that are not on a control to `MetalHostView.current` (the emulated touch screen),
    /// instead of relying on SwiftUI passing touches between overlapping representables.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if !isPortraitLayout, MetalHostView.current != nil {
            return bounds.contains(point)
        }
        return role(at: point) != nil
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            guard let hitRole = role(at: point) else {
                // Not on a control: in landscape this is a touch on the screens underneath.
                if !isPortraitLayout, screenTouch == nil, let screen = MetalHostView.current {
                    screenTouch = touch
                    screen.forwardTouchBegan(touch)
                }
                continue
            }
            switch hitRole {
            case .leftControl:
                switch leftStyle {
                case .circlePad:
                    guard stickTouch == nil else { continue }
                    stickTouch = touch
                    touchRoles[touch] = hitRole
                    updateStick(with: point)
                case .dPad:
                    touchRoles[touch] = hitRole
                    touchButtons[touch] = dpadButtons(at: point)
                }
            case .faceCluster:
                touchRoles[touch] = hitRole
                touchButtons[touch] = faceButtons(at: point)
            case .single(let button):
                touchRoles[touch] = hitRole
                touchButtons[touch] = [button]
            }
        }
        syncButtons()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch === screenTouch {
                MetalHostView.current?.forwardTouchMoved(touch)
                continue
            }
            guard let role = touchRoles[touch] else { continue }
            let point = touch.location(in: self)
            switch role {
            case .leftControl:
                if touch === stickTouch {
                    updateStick(with: point)
                } else if leftStyle == .dPad {
                    touchButtons[touch] = dpadButtons(at: point)
                }
            case .faceCluster:
                // Sliding between face buttons (and pressing two at once in between) is allowed.
                touchButtons[touch] = faceButtons(at: point)
            case .single:
                // Shoulder / Start / Select stay held until the finger lifts.
                break
            }
        }
        syncButtons()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch === screenTouch {
                MetalHostView.current?.forwardTouchEnded(touch)
                screenTouch = nil
                continue
            }
            if touch === stickTouch {
                stickTouch = nil
                setStickVector(.zero)
            }
            touchRoles[touch] = nil
            touchButtons[touch] = nil
        }
        syncButtons()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        releaseAll()
    }

    /// Releases every button held by this overlay and recentres the circle pad.
    func releaseAll() {
        if let touch = screenTouch {
            MetalHostView.current?.forwardTouchEnded(touch)
            screenTouch = nil
        }
        touchRoles.removeAll()
        touchButtons.removeAll()
        if stickTouch != nil || stickVector != .zero {
            stickTouch = nil
            setStickVector(.zero)
        }
        syncButtons()
    }

    private func updateStick(with point: CGPoint) {
        guard leftRadius > 0 else { return }
        var dx = (point.x - leftCenter.x) / leftRadius
        var dy = (leftCenter.y - point.y) / leftRadius // y up positive
        let length = hypot(dx, dy)
        if length < 0.08 {
            dx = 0
            dy = 0
        } else if length > 1 {
            dx /= length
            dy /= length
        }
        setStickVector(CGVector(dx: dx, dy: dy))
    }

    private func setStickVector(_ vector: CGVector) {
        stickVector = vector
        PPEmulator.shared.setAnalogStick(.circlePad, x: Float(vector.dx), y: Float(vector.dy))
        updateKnobPosition()
    }

    private func dpadButtons(at point: CGPoint) -> Set<PPButton> {
        let dx = point.x - leftCenter.x
        let dy = leftCenter.y - point.y // y up positive
        guard hypot(dx, dy) >= leftRadius * 0.22 else { return [] }
        let angle = atan2(dy, dx) * 180 / .pi // 0 = right, 90 = up
        var result: Set<PPButton> = []
        // Eight 45 degree sectors: diagonals press two directions.
        if abs(angle) < 67.5 { result.insert(.right) }
        if abs(angle) > 112.5 { result.insert(.left) }
        if angle > 22.5 && angle < 157.5 { result.insert(.up) }
        if angle < -22.5 && angle > -157.5 { result.insert(.down) }
        return result
    }

    private func faceButtons(at point: CGPoint) -> Set<PPButton> {
        var result: Set<PPButton> = []
        let hitRadius = faceButtonRadius * 1.3
        for (button, center) in faceCenters where distance(point, center) <= hitRadius {
            result.insert(button)
        }
        return result
    }

    /// Diffs the union of all fingers' buttons against what the core currently has pressed.
    private func syncButtons() {
        let desired = touchButtons.values.reduce(into: Set<PPButton>()) { $0.formUnion($1) }
        guard desired != pressedButtons else {
            applyPressedVisuals()
            return
        }
        let released = pressedButtons.subtracting(desired)
        let newlyPressed = desired.subtracting(pressedButtons)
        for button in released {
            PPEmulator.shared.setButton(button, pressed: false)
        }
        for button in newlyPressed {
            PPEmulator.shared.setButton(button, pressed: true)
        }
        if !newlyPressed.isEmpty {
            Haptics.buttonDown()
        }
        pressedButtons = desired
        applyPressedVisuals()
    }
}
