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

import CoreHaptics
import Foundation
import GameController

final class PlayStationController: @unchecked Sendable {
    static let shared = PlayStationController()

    /// For the launcher: what is connected.
    struct Status: Equatable {
        var name: String
        var isPlayStation: Bool
        var hasMotion: Bool
        var hasTouchpad: Bool
    }

    private let lock = NSLock()
    private var controller: GCController?
    private var lowFrequency: RumbleMotor?
    private var highFrequency: RumbleMotor?
    private var appliedFeedback = AstroPadFeedback()
    private var observers: [NSObjectProtocol] = []
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
        return controller.map(Self.describe)
    }

    private static func isPlayStation(_ controller: GCController) -> Bool {
        controller.extendedGamepad is GCDualSenseGamepad || controller.extendedGamepad is GCDualShockGamepad
    }

    private static func describe(_ controller: GCController) -> Status {
        let gamepad = controller.extendedGamepad
        return Status(
            name: controller.vendorName ?? controller.productCategory,
            isPlayStation: isPlayStation(controller),
            hasMotion: controller.motion != nil,
            hasTouchpad: gamepad is GCDualSenseGamepad || gamepad is GCDualShockGamepad
        )
    }

    /// Picks the controller: a PlayStation one if there is one.
    private func choose() {
        let candidates = GCController.controllers().filter { $0.extendedGamepad != nil }
        let chosen = candidates.first(where: Self.isPlayStation) ?? candidates.first
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

    private func setUp(_ controller: GCController) {
        // The PS button, Create and the touchpad belong to the game, not to the system.
        for (_, button) in controller.physicalInputProfile.buttons where button.isBoundToSystemGesture {
            button.preferredSystemGestureState = .disabled
        }
        // The motion sensors are what turns and tilts the controller in the game.
        if let motion = controller.motion {
            if motion.sensorsRequireManualActivation {
                motion.sensorsActive = true
            }
            motion.valueChangedHandler = { [weak self] motion in
                self?.motionChanged(motion)
            }
        }
        // Rumble: the low frequency motor in the left grip, the high frequency one in the right,
        // as SDL drives a PlayStation controller on Apple systems.
        if let haptics = controller.haptics {
            let low = RumbleMotor(haptics: haptics, locality: .leftHandle)
            let high = RumbleMotor(haptics: haptics, locality: .rightHandle)
            lock.lock()
            lowFrequency = low
            highFrequency = high
            lock.unlock()
        }
    }

    /// The motion sensors, converted the way SDL's GameController driver converts them
    /// (src/joystick/apple/SDL_mfijoystick.m) - the convention the emulator was written against:
    /// rad/s, and m/s² with gravity included.
    private func motionChanged(_ motion: GCMotion) {
        guard motion.sensorsActive else { return }
        var gyro: [Float] = [0, 0, 0]
        var accel: [Float] = [0, 0, -9.80665]
        if motion.hasRotationRate {
            let rate = motion.rotationRate
            gyro = [Float(rate.x), Float(rate.z), Float(-rate.y)]
        }
        if motion.hasGravityAndUserAcceleration {
            let acceleration = motion.acceleration
            accel = [Float(-acceleration.x) * 9.80665, Float(-acceleration.y) * 9.80665, Float(-acceleration.z) * 9.80665]
        } else {
            let acceleration = motion.acceleration
            accel = [Float(-acceleration.x) * 9.80665, Float(-acceleration.y) * 9.80665, Float(-acceleration.z) * 9.80665]
        }
        gyro.withUnsafeBufferPointer { g in
            accel.withUnsafeBufferPointer { a in
                astro_core_pad_motion(g.baseAddress, a.baseAddress)
            }
        }
    }

    /// Reads the buttons, sticks, triggers and touchpad, and passes on what the game asks of the
    /// motors and the light. Once per refresh of the headset's display.
    func poll() {
        lock.lock()
        let controller = self.controller
        lock.unlock()
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

        applyFeedback(controller)
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

        // The game's large motor is the low frequency one, its small motor the high frequency one.
        if wanted.large_motor != previous.large_motor {
            low?.setIntensity(Float(wanted.large_motor) / 255.0)
        }
        if wanted.small_motor != previous.small_motor {
            high?.setIntensity(Float(wanted.small_motor) / 255.0)
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
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var active = false
    private let lock = NSLock()

    init?(haptics: GCDeviceHaptics, locality: GCHapticsLocality) {
        guard let engine = haptics.createEngine(withLocality: locality) else {
            return nil
        }
        self.engine = engine
        engine.stoppedHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.player = nil
            self.engine = nil
            self.active = false
            self.lock.unlock()
        }
        engine.resetHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.player = nil
            self.active = false
            try? self.engine?.start()
            self.lock.unlock()
        }
        do {
            try engine.start()
        } catch {
            return nil
        }
    }

    func setIntensity(_ intensity: Float) {
        lock.lock()
        defer { lock.unlock() }
        guard let engine else { return }
        do {
            if intensity <= 0 {
                if active {
                    try player?.stop(atTime: 0)
                }
                active = false
                return
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
                [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0)],
                atTime: 0)
            if !active {
                try player?.start(atTime: 0)
                active = true
            }
        } catch {
            active = false
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
    }
}
