// SPDX-License-Identifier: GPL-2.0-or-later
//
// The head and the hands, through ARKit: what OpenXR's view space and hand trackers give the PC
// build (core/vr/openxr_host.cpp, UpdateHead and UpdatePad).

import ARKit
import Foundation
import QuartzCore
import simd

final class HeadsetTracking: @unchecked Sendable {
    let session = ARKitSession()
    let world = WorldTrackingProvider()
    let hands = HandTrackingProvider()
    private(set) var handsRunning = false

    /// Starts world tracking, and hand tracking when it is allowed and wanted.
    func start(trackHands: Bool) async {
        var providers: [any DataProvider] = [world]
        if trackHands && HandTrackingProvider.isSupported {
            let authorization = await session.requestAuthorization(for: [.handTracking])
            if authorization[.handTracking] == .allowed {
                providers.append(hands)
            }
        }
        do {
            try await session.run(providers)
            handsRunning = providers.count > 1
        } catch {
            // Without hands the controller is placed by its motion sensors alone.
            handsRunning = false
            try? await session.run([world])
        }
    }

    func stop() {
        session.stop()
    }

    /// Where the device is at `time` (seconds on CACurrentMediaTime's clock).
    func deviceAnchor(at time: TimeInterval) -> DeviceAnchor? {
        guard world.state == .running else { return nil }
        return world.queryDeviceAnchor(atTimestamp: time)
    }

    // --- the controller, by the hands around it ----------------------------------------------

    private var padSeen = false
    private var padPosition = SIMD3<Float>(0, 0, 0)
    private var padVelocity = SIMD3<Float>(0, 0, 0)
    private var padTime: TimeInterval = 0

    /// Where the palm of a hand is: the middle of its middle finger's metacarpal (where OpenXR
    /// puts XR_HAND_JOINT_PALM_EXT), between that bone's base and the knuckle.
    private static func palm(_ anchor: HandAnchor?) -> SIMD3<Float>? {
        guard let anchor, anchor.isTracked, let skeleton = anchor.handSkeleton else {
            return nil
        }
        let base = skeleton.joint(.middleFingerMetacarpal)
        let knuckle = skeleton.joint(.middleFingerKnuckle)
        guard base.isTracked, knuckle.isTracked else {
            return nil
        }
        let origin = anchor.originFromAnchorTransform
        let a = origin * base.anchorFromJointTransform.columns.3
        let b = origin * knuckle.anchorFromJointTransform.columns.3
        return (SIMD3<Float>(a.x, a.y, a.z) + SIMD3<Float>(b.x, b.y, b.z)) * 0.5
    }

    /// A gamepad cannot be tracked, the hands that hold it can: both palms a controller's width
    /// apart give away where it is and which way it points. The same as the PC build's.
    func updatePad(at time: TimeInterval) {
        guard handsRunning, hands.state == .running else {
            if padSeen {
                astro_core_pad_lost()
                padSeen = false
            }
            return
        }
        let latest = hands.latestAnchors
        var seen = false
        if let left = Self.palm(latest.leftHand), let right = Self.palm(latest.rightHand) {
            let across = right - left
            let distance = simd_length(across)
            // Hands further apart, or closer together, are not holding a controller.
            if distance > 0.05 && distance < 0.32 {
                var centre = (left + right) * 0.5
                let level = (across.x * across.x + across.z * across.z).squareRoot()
                if level > 0.6 * distance {
                    // The line from the left to the right palm is the controller's sideways
                    // axis; its heading follows from that.
                    let yaw = atan2(-across.z, across.x)
                    astro_core_pad_yaw_reference(yaw)
                    // The palms close around the grips, which sit behind and below the middle
                    // of the controller.
                    centre.x += -sin(yaw) * 0.035
                    centre.z += -cos(yaw) * 0.035
                }
                centre.y += 0.015

                if padSeen && time > padTime {
                    let elapsed = Float(time - padTime)
                    if elapsed < 0.1 {
                        let blend: Float = 0.4
                        padVelocity += ((centre - padPosition) / elapsed - padVelocity) * blend
                    }
                } else {
                    padVelocity = .zero
                }
                padPosition = centre
                padTime = time

                var position = [centre.x, centre.y, centre.z]
                var velocity = [padVelocity.x, padVelocity.y, padVelocity.z]
                astro_core_pad_position(&position, &velocity)
                seen = true
            }
        }
        // Once more when the hands are lost, so that the last position is no longer trusted.
        if !seen && padSeen {
            astro_core_pad_lost()
        }
        padSeen = seen
    }
}
