// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Feeds the device accelerometer and gyroscope to the emulated 3DS motion sensors.

import CoreMotion
import Foundation
import PlanetCore

final class MotionProvider: @unchecked Sendable {
    static let shared = MotionProvider()

    private let manager = CMMotionManager()
    private let queue: OperationQueue
    private let lock = NSLock()
    private var currentOrientation: PPInterfaceOrientation = .portrait

    /// Updated by EmulationView when the interface orientation changes. Lock protected: read on
    /// the motion queue for every sample.
    var orientation: PPInterfaceOrientation {
        get {
            lock.lock()
            defer { lock.unlock() }
            return currentOrientation
        }
        set {
            lock.lock()
            currentOrientation = newValue
            lock.unlock()
        }
    }

    private init() {
        queue = OperationQueue()
        queue.name = "org.planetport.motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
    }

    /// Starts device motion updates at 60 Hz. No-op when unavailable or already running.
    /// Call start/stop from the main thread.
    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let gravity = motion.gravity
            let user = motion.userAcceleration
            let rotation = motion.rotationRate
            // Total acceleration in g (CoreMotion sign convention) and rotation rate in rad/s;
            // the bridge rotates the sample into the 3DS frame for `orientation`.
            PPEmulator.shared.updateMotion(accelerationX: gravity.x + user.x,
                                           y: gravity.y + user.y,
                                           z: gravity.z + user.z,
                                           rotationRateX: rotation.x,
                                           y: rotation.y,
                                           z: rotation.z,
                                           orientation: self.orientation)
        }
    }

    func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
    }
}
