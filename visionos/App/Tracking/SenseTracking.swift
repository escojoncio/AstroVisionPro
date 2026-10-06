// SPDX-License-Identifier: GPL-2.0-or-later
//
// PlayStation VR2 Sense controllers, tracked in space by the headset (ARKit's accessory
// tracking, visionOS 26). The game's controller follows one of them - the right one, or the
// left one while the right one is not tracked - as the Quest build's controller follows what the
// Quest Pro's cameras see: its position, and its orientation, which the game reads from the
// PlayStation 4 controller's motion sensors, so the sensors are made from the tracked pose here
// (turn rate from its angular velocity, and gravity turned into the controller's frame).

import ARKit
import Foundation
import GameController
import simd

final class SenseTracking: @unchecked Sendable {
    private let lock = NSLock()
    private var session: ARKitSession?
    private var provider: AccessoryTrackingProvider?
    /// The accessories being tracked, by the controller they came from.
    private var tracked: [ObjectIdentifier: (controller: GCController, accessory: Accessory)] = [:]
    private var starting = false

    private var seen = false
    private var lastTime: TimeInterval = 0

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return provider != nil
    }

    /// Tracks these controllers (and stops tracking any other). Async: loading an accessory
    /// for a controller takes a moment.
    func track(_ controllers: [GCController]) async {
        let wanted = Set(controllers.map(ObjectIdentifier.init))
        lock.lock()
        let current = Set(tracked.keys)
        if wanted == current || starting {
            lock.unlock()
            return
        }
        starting = true
        lock.unlock()
        defer {
            lock.lock()
            starting = false
            lock.unlock()
        }

        stop()
        guard AccessoryTrackingProvider.isSupported, !controllers.isEmpty else {
            return
        }
        var accessories: [ObjectIdentifier: (controller: GCController, accessory: Accessory)] = [:]
        for controller in controllers {
            if let accessory = try? await Accessory(device: controller) {
                accessories[ObjectIdentifier(controller)] = (controller, accessory)
                // The hand a Sense controller is made for, for its buttons (PlayStationController).
                let hand = "\(accessory.inherentChirality)".lowercased()
                if hand.contains("left") || hand.contains("right") {
                    PlayStationController.shared.noteSenseHand(controller, isLeft: hand.contains("left"))
                }
            }
        }
        guard !accessories.isEmpty else { return }
        let session = ARKitSession()
        _ = await session.requestAuthorization(for: AccessoryTrackingProvider.requiredAuthorizations)
        let provider = AccessoryTrackingProvider(accessories: accessories.values.map(\.accessory))
        do {
            try await session.run([provider])
        } catch {
            return
        }
        lock.lock()
        self.session = session
        self.provider = provider
        self.tracked = accessories
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let session = self.session
        self.session = nil
        provider = nil
        tracked = [:]
        lock.unlock()
        session?.stop()
        if seen {
            astro_core_pad_lost()
            seen = false
        }
    }

    /// Places the game's controller where the tracked Sense controller is. Once per frame.
    func updatePad(at time: TimeInterval) {
        lock.lock()
        let provider = self.provider
        lock.unlock()
        guard let provider, provider.state == .running else {
            if seen {
                astro_core_pad_lost()
                seen = false
            }
            return
        }

        // The right hand's controller if it is tracked, otherwise the left one's.
        var best: AccessoryAnchor?
        var bestIsRight = false
        for anchor in provider.latestAnchors where anchor.isTracked {
            let held = "\(anchor.heldChirality)".lowercased()
            let inherent = "\(anchor.accessory.inherentChirality)".lowercased()
            let isRight = held.contains("right") || (!held.contains("left") && inherent.contains("right"))
            if best == nil || (isRight && !bestIsRight) {
                best = anchor
                bestIsRight = isRight
            }
        }
        guard let anchor = best else {
            if seen {
                astro_core_pad_lost()
                seen = false
            }
            return
        }

        let transform = anchor.originFromAnchorTransform
        let rotation = simd_float3x3(
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        let toController = rotation.transpose

        // Position and velocity, in the same space as the head's.
        var position = [transform.columns.3.x, transform.columns.3.y, transform.columns.3.z]
        let v = anchor.velocity
        var velocity = [v.x, v.y, v.z]
        astro_core_pad_position(&position, &velocity)

        // Heading: the controller's sideways axis, as for a gamepad between two hands.
        let across = rotation.columns.0
        astro_core_pad_yaw_reference(atan2(-across.z, across.x))

        // Motion sensors, in the frame the emulator expects (SDL's: x right, y up, z towards
        // the player - ARKit's own for an anchor that points away from the player): the turn
        // rate in the controller's frame, and gravity as an accelerometer at rest reads it.
        let gyro = toController * anchor.angularVelocity
        let gravity = toController * SIMD3<Float>(0, 9.80665, 0)
        let gyroValues = [gyro.x, gyro.y, gyro.z]
        let accelValues = [gravity.x, gravity.y, gravity.z]
        gyroValues.withUnsafeBufferPointer { g in
            accelValues.withUnsafeBufferPointer { a in
                astro_core_pad_motion(g.baseAddress, a.baseAddress)
            }
        }
        seen = true
        lastTime = time
    }
}
