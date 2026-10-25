// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// External game controllers (MFi, Xbox, PlayStation, Switch Pro, ...) through GameController.
// Input handlers talk to PPEmulator.shared directly (its input API is thread-safe).

import Combine
import Foundation
import GameController
import PlanetCore

@MainActor
final class ControllerManager: ObservableObject {
    static let shared = ControllerManager()

    /// nil when no extended gamepad is connected.
    @Published private(set) var controllerName: String?

    var isControllerConnected: Bool { controllerName != nil }

    private var isStarted = false
    private var observers = Set<AnyCancellable>()

    private init() {}

    /// Idempotent; observes GCControllerDidConnect/DidDisconnect and wires extendedGamepad handlers.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        let center = NotificationCenter.default
        center.publisher(for: .GCControllerDidConnect)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let controller = notification.object as? GCController else { return }
                self?.attach(controller)
            }
            .store(in: &observers)

        center.publisher(for: .GCControllerDidDisconnect)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.detach(notification.object as? GCController)
            }
            .store(in: &observers)

        for controller in GCController.controllers() {
            attach(controller)
        }
        updateControllerName(excluding: nil)
    }

    // MARK: - Private

    private func attach(_ controller: GCController) {
        if let gamepad = controller.extendedGamepad {
            Self.wire(gamepad)
            if controller.playerIndex == .indexUnset {
                controller.playerIndex = .index1
            }
        }
        updateControllerName(excluding: nil)
    }

    private func detach(_ controller: GCController?) {
        // Buttons held on the disconnected pad must not stay pressed.
        PPEmulator.shared.releaseAllInputs()
        updateControllerName(excluding: controller)
    }

    private func updateControllerName(excluding removed: GCController?) {
        let connected = GCController.controllers().first { controller in
            controller !== removed && controller.extendedGamepad != nil
        }
        guard let connected else {
            controllerName = nil
            return
        }
        if let vendor = connected.vendorName, !vendor.isEmpty {
            controllerName = vendor
        } else if !connected.productCategory.isEmpty {
            controllerName = connected.productCategory
        } else {
            controllerName = "Controller"
        }
    }

    // MARK: - Input mapping (nonisolated: handlers run on the GameController handler queue)

    private nonisolated static func wire(_ gamepad: GCExtendedGamepad) {
        bind(gamepad.dpad.up, to: .up)
        bind(gamepad.dpad.down, to: .down)
        bind(gamepad.dpad.left, to: .left)
        bind(gamepad.dpad.right, to: .right)

        gamepad.leftThumbstick.valueChangedHandler = { _, x, y in
            PPEmulator.shared.setAnalogStick(.circlePad, x: x, y: y)
        }
        gamepad.rightThumbstick.valueChangedHandler = { _, x, y in
            PPEmulator.shared.setAnalogStick(.cStick, x: x, y: y)
        }

        bind(gamepad.leftShoulder, to: .l)
        bind(gamepad.rightShoulder, to: .r)
        bind(gamepad.leftTrigger, to: .zl)
        bind(gamepad.rightTrigger, to: .zr)
        bind(gamepad.buttonMenu, to: .start)
        if let options = gamepad.buttonOptions {
            bind(options, to: .select)
        }

        // Face buttons: GameController names them by position (A = bottom, B = right,
        // X = left, Y = top).
        bindFace(gamepad.buttonA, positional: .b, byLabel: .a)
        bindFace(gamepad.buttonB, positional: .a, byLabel: .b)
        bindFace(gamepad.buttonX, positional: .y, byLabel: .x)
        bindFace(gamepad.buttonY, positional: .x, byLabel: .y)
    }

    private nonisolated static func bind(_ input: GCControllerButtonInput, to button: PPButton) {
        input.pressedChangedHandler = { _, _, pressed in
            PPEmulator.shared.setButton(button, pressed: pressed)
        }
    }

    /// The layout is read when the button goes down; the release always goes to the button that
    /// was pressed, so changing the layout while holding a button cannot leave it stuck.
    private nonisolated static func bindFace(_ input: GCControllerButtonInput,
                                             positional: PPButton, byLabel: PPButton) {
        let latch = PressedButtonLatch()
        input.pressedChangedHandler = { _, _, pressed in
            if pressed {
                let target = ControllerFaceLayout.persistedValue() == .byLabel ? byLabel : positional
                if let previous = latch.take(), previous != target {
                    PPEmulator.shared.setButton(previous, pressed: false)
                }
                latch.store(target)
                PPEmulator.shared.setButton(target, pressed: true)
            } else {
                let target = latch.take()
                    ?? (ControllerFaceLayout.persistedValue() == .byLabel ? byLabel : positional)
                PPEmulator.shared.setButton(target, pressed: false)
            }
        }
    }
}

/// Remembers which emulated button a physical face button pressed. Lock protected because the
/// GameController handler queue is configurable.
private final class PressedButtonLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var button: PPButton?

    func store(_ value: PPButton) {
        lock.lock()
        button = value
        lock.unlock()
    }

    func take() -> PPButton? {
        lock.lock()
        defer { lock.unlock() }
        let value = button
        button = nil
        return value
    }
}
