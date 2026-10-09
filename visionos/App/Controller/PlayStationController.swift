// SPDX-License-Identifier: GPL-2.0-or-later
//
// The controller, read through Apple's GameController framework with its PlayStation profiles:
// a DualSense (GCDualSenseGamepad) or a DualShock 4 (GCDualShockGamepad). Every button, stick,
// trigger, the touchpad and the motion sensors are taken from those classes and handed to the
// emulator in the PlayStation 4's own terms (astro_core.h), which is what the Quest app does
// with an Android gamepad and the PC build with SDL. The other direction - rumble and the light
// bar - goes to the same controller through its haptics (CoreHaptics engines on its handles) and
// its light (GCDeviceLight).
//
// A controller of Sony's make goes first whenever one is connected (as on the Quest, app 0.7):
// other gamepads are only used while there is none.
//
// PlayStation VR2 Sense controllers (GameController's spatial controllers, one per hand) are a
// controller too: the two together give the PlayStation 4 controller's buttons, sticks and
// triggers, and the headset tracks them (SenseTracking.swift), so the game's controller follows
// one of them in space.

import CoreHaptics
import Foundation
import GameController

final class PlayStationController: @unchecked Sendable {
    static let shared = PlayStationController()

    /// For the launcher: what is connected.
    struct Status: Equatable {
        var name: String
        var kind: Kind
        var isPlayStation: Bool
        var hasMotion: Bool
        var hasTouchpad: Bool
    }

    /// What kind of controller the game is played with: it decides how the controller is placed
    /// in space (HeadsetTracking.swift).
    enum Kind: Equatable {
        /// A DualSense or DualShock 4: placed between the two hands holding it.
        case playStation
        /// PlayStation VR2 Sense controllers: placed where the headset tracks one of them.
        case sense
        /// Any other gamepad: placed between the hands as well.
        case other
    }

    private let lock = NSLock()
    private var controller: GCController?
    /// PlayStation VR2 Sense controllers, by hand, while they are what the game is played with.
    private(set) var senseLeft: GCController?
    private(set) var senseRight: GCController?
    private var senseMotors: [ObjectIdentifier: RumbleMotor] = [:]
    /// The hand each Sense controller is for, when the headset's tracking says so.
    private var senseHands: [ObjectIdentifier: Bool] = [:]
    private var lowFrequency: RumbleMotor?
    private var highFrequency: RumbleMotor?
    private var appliedFeedback = AstroPadFeedback()
    private var observers: [NSObjectProtocol] = []
    /// Motion updates so far (a few go to the log).
    private var motionReports: UInt = 0
    /// Rumble changes so far (a few go to the log).
    private var feedbackReports: UInt = 0
    /// When the motion sensors last reported (ProcessInfo uptime), and when they were last woken
    /// up again: visionOS can turn them off (sensorsActive false, no more updates) while the app
    /// keeps the controller, and then the game's controller stops turning.
    private var lastMotionTime: TimeInterval = 0
    private var lastMotionWake: TimeInterval = 0
    private var motionWakes: UInt = 0
    var onStatusChange: ((Status?) -> Void)?

    private init() {}

    /// Starts watching for controllers. On the main thread.
    func start() {
        GCController.shouldMonitorBackgroundEvents = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.choose()
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.choose()
        })
        GCController.startWirelessControllerDiscovery {}
        choose()
    }

    var status: Status? {
        lock.lock()
        defer { lock.unlock() }
        if let controller {
            return Self.describe(controller)
        }
        if senseLeft != nil || senseRight != nil {
            return senseStatus
        }
        return nil
    }

    /// Which kind of controller is in use, for the tracking (nil: none).
    var kind: Kind? {
        status?.kind
    }

    /// The Sense controllers in use, for the headset's tracking.
    var senseControllers: [GCController] {
        lock.lock()
        defer { lock.unlock() }
        return [senseLeft, senseRight].compactMap { $0 }
    }

    private var senseStatus: Status {
        let count = (senseLeft != nil ? 1 : 0) + (senseRight != nil ? 1 : 0)
        return Status(name: L("PlayStation VR2 Sense (\(count) de 2)", "PlayStation VR2 Sense (\(count) of 2)"), kind: .sense,
                      isPlayStation: true, hasMotion: true, hasTouchpad: false)
    }

    static func isSense(_ controller: GCController) -> Bool {
        controller.productCategory == GCProductCategorySpatialController
    }

    /// Whether a Sense controller is the left one: as the headset's tracking says, else by its name.
    private func isLeftSense(_ controller: GCController) -> Bool {
        if let left = senseHands[ObjectIdentifier(controller)] {
            return left
        }
        let name = (controller.vendorName ?? "").lowercased()
        return name.contains("left") || name.contains("(l)") || name.hasSuffix(" l")
    }

    /// Called by the tracking when it knows which hand a Sense controller is for.
    func noteSenseHand(_ controller: GCController, isLeft: Bool) {
        lock.lock()
        let known = senseHands[ObjectIdentifier(controller)]
        senseHands[ObjectIdentifier(controller)] = isLeft
        lock.unlock()
        if known != isLeft {
            DispatchQueue.main.async { [weak self] in
                self?.choose()
            }
        }
    }

    private static func isPlayStation(_ controller: GCController) -> Bool {
        controller.extendedGamepad is GCDualSenseGamepad || controller.extendedGamepad is GCDualShockGamepad
    }

    private static func describe(_ controller: GCController) -> Status {
        let gamepad = controller.extendedGamepad
        return Status(
            name: controller.vendorName ?? controller.productCategory,
            kind: isPlayStation(controller) ? .playStation : .other,
            isPlayStation: isPlayStation(controller),
            hasMotion: controller.motion != nil,
            hasTouchpad: gamepad is GCDualSenseGamepad || gamepad is GCDualShockGamepad
        )
    }

    /// Picks the controller: a PlayStation one if there is one.
    private func choose() {
        let all = GCController.controllers()
        let senses = all.filter(Self.isSense)
        let candidates = all.filter { $0.extendedGamepad != nil && !Self.isSense($0) }
        // A DualSense or DualShock 4 first, then PlayStation VR2 Sense controllers, then the rest.
        var chosen = candidates.first(where: Self.isPlayStation)
        var useSense = false
        if chosen == nil && !senses.isEmpty {
            useSense = true
        } else if chosen == nil {
            chosen = candidates.first
        }
        updateSense(useSense ? senses : [])
        lock.lock()
        let changed = chosen !== controller
        if changed {
            lowFrequency?.stop()
            highFrequency?.stop()
            lowFrequency = nil
            highFrequency = nil
            appliedFeedback = AstroPadFeedback()
            controller = chosen
        }
        lock.unlock()
        if useSense {
            // Sense controllers come and go one at a time: tell every change.
            astro_core_pad_connected(true, "PlayStation VR2 Sense")
            onStatusChange?(senseStatus)
            return
        }
        guard changed else { return }

        if let chosen {
            setUp(chosen)
            let status = Self.describe(chosen)
            astro_core_pad_connected(true, "\(status.name) (\(chosen.productCategory))")
            onStatusChange?(status)
        } else {
            astro_core_pad_connected(false, nil)
            onStatusChange?(nil)
        }
    }

    /// Takes the Sense controllers into use (or none), one for each hand.
    private func updateSense(_ senses: [GCController]) {
        var left: GCController?
        var right: GCController?
        lock.lock()
        for sense in senses {
            if isLeftSense(sense) {
                if left == nil { left = sense } else if right == nil { right = sense }
            } else {
                if right == nil { right = sense } else if left == nil { left = sense }
            }
        }
        let previous = Set([senseLeft, senseRight].compactMap { $0.map(ObjectIdentifier.init) })
        senseLeft = left
        senseRight = right
        let current = Set([left, right].compactMap { $0.map(ObjectIdentifier.init) })
        for gone in previous.subtracting(current) {
            senseMotors[gone]?.stop()
            senseMotors[gone] = nil
        }
        lock.unlock()
        for sense in [left, right].compactMap({ $0 }) where !previous.contains(ObjectIdentifier(sense)) {
            for (_, button) in sense.physicalInputProfile.buttons where button.isBoundToSystemGesture {
                button.preferredSystemGestureState = .disabled
            }
            if let haptics = sense.haptics, let motor = RumbleMotor(haptics: haptics, locality: .default) {
                lock.lock()
                senseMotors[ObjectIdentifier(sense)] = motor
                lock.unlock()
            }
        }
    }

    private func setUp(_ controller: GCController) {
        // The PS button, Create and the touchpad belong to the game, not to the system.
        for (_, button) in controller.physicalInputProfile.buttons where button.isBoundToSystemGesture {
            button.preferredSystemGestureState = .disabled
        }
        // The motion sensors are what turns and tilts the controller in the game.
        lock.lock()
        lastMotionTime = 0
        lock.unlock()
        if let motion = controller.motion {
            if motion.sensorsRequireManualActivation {
                motion.sensorsActive = true
            }
            motion.valueChangedHandler = { [weak self] motion in
                self?.motionChanged(motion)
            }
        }
        // Rumble: the low frequency motor in the left grip, the high frequency one in the right,
        // as SDL drives a PlayStation controller on Apple systems. A controller that has no
        // motor of each grip to give gets one for both grips (or its only one) for the two.
        if let haptics = controller.haptics {
            let localities = haptics.supportedLocalities.map { $0.rawValue }.sorted().joined(separator: ", ")
            var low = RumbleMotor(haptics: haptics, locality: .leftHandle)
            var high = RumbleMotor(haptics: haptics, locality: .rightHandle)
            var how = "a motor in each grip"
            if low == nil || high == nil {
                let both = RumbleMotor(haptics: haptics, locality: .handles)
                    ?? RumbleMotor(haptics: haptics, locality: .default)
                low = low ?? both
                high = high ?? both
                how = both != nil ? "one motor for both grips" : "no motor"
            }
            LogFiles.log("Controller rumble: \(how) (it has: \(localities.isEmpty ? "none" : localities))")
            lock.lock()
            lowFrequency = low
            highFrequency = high
            lock.unlock()
        } else {
            LogFiles.log("Controller rumble: the controller offers no haptics")
        }
    }

    /// The motion sensors, in the frame and units the emulator was written against (SDL's
    /// sensor convention: x right, y up out of the face buttons, z towards the player; rad/s,
    /// and m/s² as an accelerometer reads them, +9.8 up at rest).
    /// GameController's frame for a gamepad is x right, y away from the player, z up out of the
    /// face buttons, and its acceleration is in G with gravity pointing down. The turn rate is
    /// mapped as SDL's GameController driver maps it (x, z, -y); the acceleration has to go
    /// through the same change of axes (SDL's driver leaves it out, which tilts the controller
    /// a quarter turn: at rest it read as pointing at the player), and is negated to read as an
    /// accelerometer does.
    private func motionChanged(_ motion: GCMotion) {
        guard motion.sensorsActive else { return }
        lock.lock()
        let wasQuiet = lastMotionTime > 0 && ProcessInfo.processInfo.systemUptime - lastMotionTime > 0.5
        lastMotionTime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        if wasQuiet {
            LogFiles.log("Controller motion: reporting again")
        }
        var gyro: [Float] = [0, 0, 0]
        if motion.hasRotationRate {
            let rate = motion.rotationRate
            gyro = [Float(rate.x), Float(rate.z), Float(-rate.y)]
        }
        let acceleration = motion.acceleration
        let standardGravity: Float = 9.80665
        let accel: [Float] = [Float(-acceleration.x) * standardGravity,
                              Float(-acceleration.z) * standardGravity,
                              Float(acceleration.y) * standardGravity]
        // Now and then, what GameController itself said (its own axes), for the log.
        motionReports &+= 1
        if motionReports % 600 == 1 {
            let rate = motion.hasRotationRate ? motion.rotationRate : GCRotationRate(x: 0, y: 0, z: 0)
            LogFiles.log(String(format: "Controller motion: turn %.2f %.2f %.2f rad/s, acceleration %.2f %.2f %.2f G (GameController axes; gravity and user apart: %@)",
                                rate.x, rate.y, rate.z, acceleration.x, acceleration.y,
                                acceleration.z, motion.hasGravityAndUserAcceleration ? "yes" : "no"))
        }
        gyro.withUnsafeBufferPointer { g in
            accel.withUnsafeBufferPointer { a in
                astro_core_pad_motion(g.baseAddress, a.baseAddress)
            }
        }
    }

    /// The motion sensors went quiet for more than half a second while the controller is in use:
    /// visionOS turned them off (it does when the app's space stops being the one in front for a
    /// moment). They are turned on again and their handler set again, on the main thread, at most
    /// once a second.
    private func keepMotionOn(_ controller: GCController) {
        guard let motion = controller.motion else { return }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let quiet = lastMotionTime > 0 && now - lastMotionTime > 0.5
        let due = quiet && now - lastMotionWake > 1.0
        if due {
            lastMotionWake = now
            motionWakes &+= 1
        }
        let wakes = motionWakes
        let silence = now - lastMotionTime
        lock.unlock()
        guard due else { return }
        let active = motion.sensorsActive
        if wakes <= 20 || wakes % 60 == 0 {
            LogFiles.log(String(format: "Controller motion: no reports for %.1f s (sensors active: %@); turning them on again (%u)",
                                silence, active ? "yes" : "no", UInt32(truncatingIfNeeded: wakes)))
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentController === controller else { return }
            if motion.sensorsRequireManualActivation {
                // Off and on: an "active" flag left on by a system that stopped the sensors
                // does not start them again by itself.
                if motion.sensorsActive {
                    motion.sensorsActive = false
                }
                motion.sensorsActive = true
            }
            motion.valueChangedHandler = { [weak self] motion in
                self?.motionChanged(motion)
            }
        }
    }

    private var currentController: GCController? {
        lock.lock()
        defer { lock.unlock() }
        return controller
    }

    /// Reads the buttons, sticks, triggers and touchpad, and passes on what the game asks of the
    /// motors and the light. Once per refresh of the headset's display.
    func poll() {
        lock.lock()
        let controller = self.controller
        let senseLeft = self.senseLeft
        let senseRight = self.senseRight
        lock.unlock()
        if controller == nil, senseLeft != nil || senseRight != nil {
            pollSense(left: senseLeft, right: senseRight)
            return
        }
        guard let controller, let gamepad = controller.extendedGamepad else {
            return
        }

        var state = AstroPadState()
        var buttons: UInt32 = 0
        func set(_ bit: UInt32, _ pressed: Bool) {
            if pressed {
                buttons |= bit
            }
        }
        // Face buttons: on a PlayStation profile, A is ✕, B is ○, X is □ and Y is △.
        set(AstroPadCross.rawValue, gamepad.buttonA.isPressed)
        set(AstroPadCircle.rawValue, gamepad.buttonB.isPressed)
        set(AstroPadSquare.rawValue, gamepad.buttonX.isPressed)
        set(AstroPadTriangle.rawValue, gamepad.buttonY.isPressed)
        set(AstroPadL1.rawValue, gamepad.leftShoulder.isPressed)
        set(AstroPadR1.rawValue, gamepad.rightShoulder.isPressed)
        set(AstroPadL2.rawValue, gamepad.leftTrigger.isPressed)
        set(AstroPadR2.rawValue, gamepad.rightTrigger.isPressed)
        set(AstroPadL3.rawValue, gamepad.leftThumbstickButton?.isPressed ?? false)
        set(AstroPadR3.rawValue, gamepad.rightThumbstickButton?.isPressed ?? false)
        // OPTIONS is the menu button; Create (Share on a DualShock 4) is no button of the game's.
        set(AstroPadOptions.rawValue, gamepad.buttonMenu.isPressed)
        set(AstroPadUp.rawValue, gamepad.dpad.up.isPressed)
        set(AstroPadDown.rawValue, gamepad.dpad.down.isPressed)
        set(AstroPadLeft.rawValue, gamepad.dpad.left.isPressed)
        set(AstroPadRight.rawValue, gamepad.dpad.right.isPressed)

        // The touchpad, from the PlayStation profiles.
        var touchpadButton: GCControllerButtonInput?
        var finger: GCControllerDirectionPad?
        if let dualSense = gamepad as? GCDualSenseGamepad {
            touchpadButton = dualSense.touchpadButton
            finger = dualSense.touchpadPrimary
        } else if let dualShock = gamepad as? GCDualShockGamepad {
            touchpadButton = dualShock.touchpadButton
            finger = dualShock.touchpadPrimary
        }
        set(AstroPadTouchPad.rawValue, touchpadButton?.isPressed ?? false)
        state.buttons = buttons

        // Sticks: 0 to 255 with 128 in the middle, up is 0 (the PlayStation 4's way round).
        func axis(_ value: Float, flipped: Bool = false) -> UInt8 {
            let v = flipped ? -value : value
            return UInt8(clamping: Int(((v + 1.0) * 127.5).rounded()))
        }
        state.left_x = axis(gamepad.leftThumbstick.xAxis.value)
        state.left_y = axis(gamepad.leftThumbstick.yAxis.value, flipped: true)
        state.right_x = axis(gamepad.rightThumbstick.xAxis.value)
        state.right_y = axis(gamepad.rightThumbstick.yAxis.value, flipped: true)
        state.left_trigger = UInt8(clamping: Int((gamepad.leftTrigger.value * 255).rounded()))
        state.right_trigger = UInt8(clamping: Int((gamepad.rightTrigger.value * 255).rounded()))

        // A finger on the touchpad: where, from the left and from the top (as SDL reports it).
        if let finger, finger.xAxis.value != 0 || finger.yAxis.value != 0 {
            state.touch_down = true
            state.touch_x = (1.0 + finger.xAxis.value) * 0.5
            state.touch_y = 1.0 - (1.0 + finger.yAxis.value) * 0.5
        } else {
            state.touch_down = false
            state.touch_x = 0.5
            state.touch_y = 0.5
        }
        state.home = gamepad.buttonHome?.isPressed ?? false
        astro_core_pad_state(&state)
        keepMotionOn(controller)

        applyFeedback(controller)
    }

    /// The two Sense controllers as one PlayStation 4 controller: the left one has L1 (its grip
    /// button), L2 (its trigger), L3 and the left stick, □ and △, and Create; the right one R1,
    /// R2, R3, the right stick, ✕ and ○, OPTIONS and the PS button. They have no directional
    /// buttons or touchpad: Create presses the touchpad.
    private func pollSense(left: GCController?, right: GCController?) {
        var state = AstroPadState()
        var buttons: UInt32 = 0
        func set(_ bit: UInt32, _ pressed: Bool) {
            if pressed {
                buttons |= bit
            }
        }
        func pressed(_ controller: GCController?, _ names: [String]) -> Bool {
            guard let profile = controller?.physicalInputProfile else { return false }
            return names.contains { profile.buttons[$0]?.isPressed ?? false }
        }
        func value(_ controller: GCController?, _ names: [String]) -> Float {
            guard let profile = controller?.physicalInputProfile else { return 0 }
            return names.compactMap { profile.buttons[$0]?.value }.max() ?? 0
        }
        func stick(_ controller: GCController?, _ names: [String]) -> (Float, Float) {
            guard let profile = controller?.physicalInputProfile else { return (0, 0) }
            for name in names {
                if let pad = profile.dpads[name] {
                    return (pad.xAxis.value, pad.yAxis.value)
                }
            }
            return (0, 0)
        }
        let a = GCInputButtonA, b = GCInputButtonB, x = GCInputButtonX, y = GCInputButtonY
        // Left: its two face buttons are □ (lower) and △ (upper), whatever names they are given.
        set(AstroPadSquare.rawValue, pressed(left, [x, a]))
        set(AstroPadTriangle.rawValue, pressed(left, [y, b]))
        // Right: ✕ (lower) and ○ (upper).
        set(AstroPadCross.rawValue, pressed(right, [a, x]))
        set(AstroPadCircle.rawValue, pressed(right, [b, y]))
        set(AstroPadL1.rawValue, pressed(left, [__GCInputButtonName.gripButton.rawValue, GCInputLeftShoulder]))
        set(AstroPadR1.rawValue, pressed(right, [__GCInputButtonName.gripButton.rawValue, GCInputRightShoulder]))
        let l2 = value(left, [__GCInputButtonName.trigger.rawValue, GCInputLeftTrigger])
        let r2 = value(right, [__GCInputButtonName.trigger.rawValue, GCInputRightTrigger])
        set(AstroPadL2.rawValue, l2 > 0.5)
        set(AstroPadR2.rawValue, r2 > 0.5)
        set(AstroPadL3.rawValue, pressed(left, [__GCInputButtonName.thumbstickButton.rawValue, GCInputLeftThumbstickButton]))
        set(AstroPadR3.rawValue, pressed(right, [__GCInputButtonName.thumbstickButton.rawValue, GCInputRightThumbstickButton]))
        set(AstroPadOptions.rawValue, pressed(right, [GCInputButtonOptions, GCInputButtonMenu]))
        set(AstroPadTouchPad.rawValue, pressed(left, [GCInputButtonShare, GCInputButtonMenu, GCInputButtonOptions]))
        state.buttons = buttons

        func axis(_ value: Float, flipped: Bool = false) -> UInt8 {
            let v = flipped ? -value : value
            return UInt8(clamping: Int(((v + 1.0) * 127.5).rounded()))
        }
        let (lx, ly) = stick(left, [__GCInputDirectionPadName.thumbstick.rawValue, GCInputLeftThumbstick])
        let (rx, ry) = stick(right, [__GCInputDirectionPadName.thumbstick.rawValue, GCInputRightThumbstick])
        state.left_x = axis(lx)
        state.left_y = axis(ly, flipped: true)
        state.right_x = axis(rx)
        state.right_y = axis(ry, flipped: true)
        state.left_trigger = UInt8(clamping: Int((l2 * 255).rounded()))
        state.right_trigger = UInt8(clamping: Int((r2 * 255).rounded()))
        state.touch_down = false
        state.touch_x = 0.5
        state.touch_y = 0.5
        state.home = pressed(right, [GCInputButtonHome]) || pressed(left, [GCInputButtonHome])
        astro_core_pad_state(&state)

        // Rumble: the game's large motor in the left controller, the small one in the right.
        var wanted = AstroPadFeedback()
        guard astro_core_pad_feedback(&wanted) else { return }
        lock.lock()
        let previous = appliedFeedback
        appliedFeedback = wanted
        let leftMotor = left.flatMap { senseMotors[ObjectIdentifier($0)] }
        let rightMotor = right.flatMap { senseMotors[ObjectIdentifier($0)] }
        lock.unlock()
        if wanted.large_motor != previous.large_motor {
            leftMotor?.setIntensity(Float(wanted.large_motor) / 255.0)
        }
        if wanted.small_motor != previous.small_motor {
            rightMotor?.setIntensity(Float(wanted.small_motor) / 255.0)
        }
    }

    private func applyFeedback(_ controller: GCController) {
        var wanted = AstroPadFeedback()
        guard astro_core_pad_feedback(&wanted) else { return }
        lock.lock()
        let previous = appliedFeedback
        appliedFeedback = wanted
        let low = lowFrequency
        let high = highFrequency
        lock.unlock()

        // The first few the game asks for, for the log.
        if wanted.large_motor != previous.large_motor || wanted.small_motor != previous.small_motor {
            feedbackReports &+= 1
            if feedbackReports <= 5 {
                LogFiles.log("Controller rumble: large \(wanted.large_motor) small \(wanted.small_motor); motors \(low != nil ? "yes" : "no")/\(high != nil ? "yes" : "no")")
            }
        }
        // The game's large motor is the low frequency one, its small motor the high frequency one.
        // One motor for both: the stronger of the two.
        if let low, let high, low === high {
            if wanted.large_motor != previous.large_motor || wanted.small_motor != previous.small_motor {
                low.setIntensity(Float(max(wanted.large_motor, wanted.small_motor)) / 255.0)
            }
        } else {
            if wanted.large_motor != previous.large_motor {
                low?.setIntensity(Float(wanted.large_motor) / 255.0)
            }
            if wanted.small_motor != previous.small_motor {
                high?.setIntensity(Float(wanted.small_motor) / 255.0)
            }
        }
        if wanted.red != previous.red || wanted.green != previous.green || wanted.blue != previous.blue,
           let light = controller.light {
            light.color = GCColor(red: Float(wanted.red) / 255.0, green: Float(wanted.green) / 255.0,
                                  blue: Float(wanted.blue) / 255.0)
        }
    }
}

/// One of the controller's rumble motors, as a CoreHaptics engine playing one endless pattern
/// whose strength is changed (what SDL does for a PlayStation controller on Apple systems).
final class RumbleMotor: @unchecked Sendable {
    private let haptics: GCDeviceHaptics
    private let locality: GCHapticsLocality
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var active = false
    /// The last strength asked for, played again on an engine made anew.
    private var wanted: Float = 0
    /// When an engine may be made again after the last one failed (ProcessInfo uptime).
    private var retryAfter: TimeInterval = 0
    private let lock = NSLock()
    /// Failures and engines made anew, a few for the log.
    private var failures: UInt = 0
    private var rebuilds: UInt = 0

    init?(haptics: GCDeviceHaptics, locality: GCHapticsLocality) {
        self.haptics = haptics
        self.locality = locality
        guard let engine = makeEngine() else {
            return nil
        }
        self.engine = engine
    }

    /// An engine for the motor, started; nil when the system gives none. Its connection to the
    /// haptics server can go (the audio session changing under it is one way): then a new one
    /// is made (setIntensity).
    private func makeEngine(log: Bool = true) -> CHHapticEngine? {
        guard let engine = haptics.createEngine(withLocality: locality) else {
            if log {
                LogFiles.log("Controller rumble: no haptic engine for \(locality.rawValue)")
            }
            return nil
        }
        // Rumble only: no audio of its own, so nothing about the audio session concerns it.
        engine.playsHapticsOnly = true
        engine.stoppedHandler = { [weak self, weak engine] reason in
            guard let self else { return }
            self.lock.lock()
            if self.engine === engine {
                self.player = nil
                self.engine = nil
                self.active = false
            }
            self.lock.unlock()
            LogFiles.log("Controller rumble: the haptic engine stopped (reason \(reason.rawValue))")
        }
        engine.resetHandler = { [weak self, weak engine] in
            guard let self else { return }
            self.lock.lock()
            if self.engine === engine {
                self.player = nil
                self.active = false
                try? engine?.start()
            }
            self.lock.unlock()
        }
        do {
            try engine.start()
        } catch {
            if log {
                LogFiles.log("Controller rumble: the haptic engine for \(locality.rawValue) did not start: \(error.localizedDescription)")
            }
            return nil
        }
        return engine
    }

    func setIntensity(_ intensity: Float) {
        lock.lock()
        wanted = intensity
        if apply() {
            lock.unlock()
            return
        }
        // Once more with a new engine, unless one failed just now.
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= retryAfter else {
            lock.unlock()
            return
        }
        retryAfter = now + 0.5
        try? player?.cancel()
        player = nil
        let old = engine
        engine = nil
        active = false
        rebuilds &+= 1
        let rebuild = rebuilds
        lock.unlock()
        // Made outside the lock: the old engine's handlers take it on CoreHaptics' queue.
        old?.stop(completionHandler: nil)
        let made = makeEngine(log: rebuild <= 5)
        lock.lock()
        if engine == nil, retryAfter != .greatestFiniteMagnitude {
            engine = made
        } else {
            made?.stop(completionHandler: nil)
        }
        let worked = engine != nil && apply()
        lock.unlock()
        if rebuild <= 5 {
            LogFiles.log("Controller rumble: haptic engine made anew: \(worked ? "plays" : "still not")")
        }
    }

    /// Plays `wanted` on the engine there is; false when it failed (or there is none).
    private func apply() -> Bool {
        guard let engine else { return wanted <= 0 }
        do {
            if wanted <= 0 {
                if active {
                    try player?.stop(atTime: 0)
                }
                active = false
                return true
            }
            if player == nil {
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)],
                    relativeTime: 0,
                    duration: TimeInterval(GCHapticDurationInfinite))
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                player = try engine.makeAdvancedPlayer(with: pattern)
                active = false
            }
            try player?.sendParameters(
                [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: wanted, relativeTime: 0)],
                atTime: 0)
            if !active {
                try player?.start(atTime: 0)
                active = true
            }
            return true
        } catch {
            active = false
            player = nil
            failures &+= 1
            if failures <= 5 {
                LogFiles.log("Controller rumble: could not play (\(error.localizedDescription))")
            }
            return false
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        try? player?.cancel()
        player = nil
        engine?.stop(completionHandler: nil)
        engine = nil
        active = false
        retryAfter = .greatestFiniteMagnitude
    }
}
