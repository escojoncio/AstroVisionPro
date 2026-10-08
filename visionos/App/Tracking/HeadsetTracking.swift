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
        var handsNote = "not asked for (hands=0)"
        if trackHands && HandTrackingProvider.isSupported {
            let authorization = await session.requestAuthorization(for: [.handTracking])
            if authorization[.handTracking] == .allowed {
                providers.append(hands)
                handsNote = "allowed"
            } else {
                handsNote = "not allowed (\(String(describing: authorization[.handTracking])))"
            }
        } else if trackHands {
            handsNote = "not supported"
        }
        do {
            try await session.run(providers)
            handsRunning = providers.count > 1
        } catch {
            // Without hands the controller is placed by its motion sensors alone.
            handsRunning = false
            handsNote += ", the session failed: \(error)"
            try? await session.run([world])
        }
        LogFiles.log("Hand tracking: \(handsNote); running \(handsRunning)")
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
        guard let anchor, anchor.isTracked else {
            return nil
        }
        let origin = anchor.originFromAnchorTransform
        guard let skeleton = anchor.handSkeleton,
              skeleton.joint(.middleFingerMetacarpal).isTracked,
              skeleton.joint(.middleFingerKnuckle).isTracked else {
            // Fingers wrapped round a controller are often not made out; the hand itself still
            // is: its origin (the wrist) stands in, a few centimetres short of the palm.
            let wrist = origin.columns.3
            return SIMD3<Float>(wrist.x, wrist.y, wrist.z)
        }
        let a = origin * skeleton.joint(.middleFingerMetacarpal).anchorFromJointTransform.columns.3
        let b = origin * skeleton.joint(.middleFingerKnuckle).anchorFromJointTransform.columns.3
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

    // What the hands did since the last report (every 5 s, to the log).
    private var reportTime: TimeInterval = 0
    private var framesBoth = 0
    private var framesOne = 0
    private var framesNone = 0
    private var framesApart = 0
    private var lastDistance: Float = 0

    private func report(at time: TimeInterval) {
        guard time - reportTime >= 5 else { return }
        if reportTime > 0 {
            let state = handsRunning ? "\(hands.state)" : "off"
            LogFiles.log(String(format: "Hands (%@): both seen %ld, one %ld, none %ld, both but not holding %ld frames; palms last %.2f m apart",
                                state, framesBoth, framesOne, framesNone, framesApart, lastDistance))
        }
        reportTime = time
        framesBoth = 0
        framesOne = 0
        framesNone = 0
        framesApart = 0
    }

    private func updatePadFromHands(at time: TimeInterval) {
        report(at: time)
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
            lastDistance = distance
            // Hands much further apart, or on top of each other, are not holding a controller.
            if distance > 0.04 && distance < 0.45 {
                framesBoth += 1
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
            } else {
                framesApart += 1
            }
        } else if leftPalm != nil || rightPalm != nil {
            framesOne += 1
            if time - bothSeenTime < Self.oneHandSeconds,
               let offset = leftPalm != nil ? offsetFromLeft : offsetFromRight {
                // One hand out of sight: the other one still holds the controller where it was.
                placed = (leftPalm ?? rightPalm!) + offset
            } else if let palm = leftPalm ?? rightPalm, let head = deviceAnchor(at: CACurrentMediaTime()) {
                // Only one hand ever seen: the controller is between the hands, half a
                // controller's width towards the other one (sideways as the head is turned).
                let right = head.originFromAnchorTransform.columns.0
                var sideways = SIMD3<Float>(right.x, 0, right.z)
                let length = simd_length(sideways)
                if length > 1e-3 {
                    sideways /= length
                    placed = palm + sideways * (leftPalm != nil ? 0.08 : -0.08) + SIMD3<Float>(0, 0.015, 0)
                }
            }
        } else {
            framesNone += 1
        }
        if let centre = placed {
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
        // Once more when the hands are lost, so that the last position is no longer trusted.
        if !seen && padSeen {
            astro_core_pad_lost()
        }
        padSeen = seen
    }
}
