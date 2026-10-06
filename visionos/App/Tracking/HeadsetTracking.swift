// SPDX-License-Identifier: GPL-2.0-or-later
//
// The head and the hands, through ARKit: what OpenXR's view space and hand trackers give the PC
// build (core/vr/openxr_host.cpp, UpdateHead and UpdatePad).
//
// The game expects the PlayStation Camera to see its controller; the Quest build uses the
// Quest's cameras instead. visionOS lets no app see the cameras, so the controller is placed
// with what the headset tracks for the app:
//   - a DualSense or DualShock 4 between the two hands holding it (and, while one hand is out
//     of sight, by the other one, where it was relative to the controller);
//   - PlayStation VR2 Sense controllers by the headset's own tracking of one of them
//     (SenseTracking.swift).

import ARKit
import Foundation
import QuartzCore
import simd

final class HeadsetTracking: @unchecked Sendable {
    let session = ARKitSession()
    let world = WorldTrackingProvider()
    let hands = HandTrackingProvider()
    private(set) var handsRunning = false
    let sense = SenseTracking()
    private var senseRequested: Set<ObjectIdentifier> = []

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
        sense.stop()
        senseRequested = []
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
    /// Where the controller was relative to each palm the last time both were seen, for while
    /// only one of them is.
    private var offsetFromLeft: SIMD3<Float>?
    private var offsetFromRight: SIMD3<Float>?
    private var bothSeenTime: TimeInterval = 0
    /// How long one hand alone keeps placing the controller.
    private static let oneHandSeconds: TimeInterval = 1.5

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
        let controllers = PlayStationController.shared
        if controllers.kind == .sense {
            let senses = controllers.senseControllers
            let wanted = Set(senses.map(ObjectIdentifier.init))
            if wanted != senseRequested {
                senseRequested = wanted
                let sense = self.sense
                Task.detached {
                    await sense.track(senses)
                }
            }
            sense.updatePad(at: time)
            return
        }
        if !senseRequested.isEmpty {
            senseRequested = []
            sense.stop()
        }
        updatePadFromHands(at: time)
    }

    private func updatePadFromHands(at time: TimeInterval) {
        guard handsRunning, hands.state == .running else {
            if padSeen {
                astro_core_pad_lost()
                padSeen = false
            }
            return
        }
        let latest = hands.latestAnchors
        var seen = false
        let leftPalm = Self.palm(latest.leftHand)
        let rightPalm = Self.palm(latest.rightHand)
        var placed: SIMD3<Float>?
        if let left = leftPalm, let right = rightPalm {
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
                offsetFromLeft = centre - left
                offsetFromRight = centre - right
                bothSeenTime = time
                placed = centre
            }
        } else if time - bothSeenTime < Self.oneHandSeconds {
            // One hand out of sight: the other one still holds the controller where it was.
            if let left = leftPalm, let offset = offsetFromLeft {
                placed = left + offset
            } else if let right = rightPalm, let offset = offsetFromRight {
                placed = right + offset
            }
        }
        if let centre = placed {
            do {
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
