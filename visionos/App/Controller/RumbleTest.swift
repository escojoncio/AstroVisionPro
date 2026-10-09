// SPDX-License-Identifier: GPL-2.0-or-later
//
// The settings' «Probar vibración»: five ways of making the controller rumble, one after the
// other, each named on screen and in the log with what CoreHaptics answered. Which of them the
// player feels tells what visionOS accepts:
//   1. as SDL does it (what the game's rumble does): an engine on each grip, a plain player of
//      one endless pattern whose strength is set;
//   2. one pattern of a set length (one second) on the controller's default engine;
//   3. five short taps on the default engine;
//   4. as the game's rumble did before: haptics-only engines and an advanced player;
//   5. the DualSense's adaptive triggers (vibration, then resistance), which go through
//      GameController itself and not CoreHaptics; the triggers' own status is logged, so the
//      log says whether they took it even when nothing is felt.

import CoreHaptics
import Foundation
import GameController

enum RumbleTest {
    private struct Step {
        let label: String
        let logName: String
        let seconds: TimeInterval
        /// Starts the step; gives back what stops it, or nil when it could not start.
        let start: (GCController) -> (() -> Void)?
    }

    private static let gap: TimeInterval = 1.2

    /// A test is going on (on the main thread): another is not started, and the game's motors
    /// are not made anew meanwhile.
    private(set) static var isRunning = false

    /// Runs the steps on the main thread; `report` is given each step's label as it starts and
    /// "" at the end.
    static func run(controller: GCController?, report: @escaping (String) -> Void) {
        guard !isRunning else {
            LogFiles.log("Controller rumble test: one is going on already")
            return
        }
        guard let controller else {
            LogFiles.log("Controller rumble test: no controller")
            report(L("No hay mando conectado", "No controller is connected"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                report("")
            }
            return
        }
        let localities = controller.haptics?.supportedLocalities.map { $0.rawValue }.sorted().joined(separator: ", ") ?? "no haptics"
        LogFiles.log("Controller rumble test: \(controller.vendorName ?? controller.productCategory) (\(controller.productCategory)); haptics: \(localities)")
        isRunning = true
        runStep(0, steps, controller, report)
    }

    private static func runStep(_ index: Int, _ steps: [Step], _ controller: GCController,
                                _ report: @escaping (String) -> Void) {
        guard index < steps.count else {
            LogFiles.log("Controller rumble test: done")
            isRunning = false
            report("")
            return
        }
        let step = steps[index]
        report("\(index + 1) / \(steps.count) · \(step.label)")
        LogFiles.log("Controller rumble test \(index + 1)/\(steps.count): \(step.logName)")
        let stop = step.start(controller)
        DispatchQueue.main.asyncAfter(deadline: .now() + step.seconds) {
            stop?()
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
                runStep(index + 1, steps, controller, report)
            }
        }
    }

    private static var steps: [Step] {
        [
            Step(label: L("Como SDL (la del juego ahora)", "As SDL does it (the game's now)"),
                 logName: "as SDL: an engine on each grip, a plain player, endless pattern",
                 seconds: 1.0) { controller in
                endless(controller, step: 1, hapticsOnly: false, advanced: false)
            },
            Step(label: L("Un segundo seguido", "One second straight"),
                 logName: "a one second pattern on the default engine", seconds: 1.2) { controller in
                pattern(controller, step: 2, events: [
                    CHHapticEvent(eventType: .hapticContinuous,
                                  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)],
                                  relativeTime: 0, duration: 1.0),
                ])
            },
            Step(label: L("Cinco toques", "Five taps"),
                 logName: "five taps on the default engine", seconds: 1.2) { controller in
                pattern(controller, step: 3, events: (0..<5).map { tap in
                    CHHapticEvent(eventType: .hapticTransient,
                                  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                                               CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)],
                                  relativeTime: TimeInterval(tap) * 0.2)
                })
            },
            Step(label: L("Como antes (avanzado)", "As before (advanced)"),
                 logName: "as before: haptics-only engines on the grips, an advanced player",
                 seconds: 1.0) { controller in
                endless(controller, step: 4, hapticsOnly: true, advanced: true)
            },
            Step(label: L("Gatillos L2 y R2 (apoya los dedos)", "L2 and R2 triggers (rest your fingers on them)"),
                 logName: "the adaptive triggers: vibration 1.5 s, then resistance", seconds: 4.0) { controller in
                triggers(controller)
            },
        ]
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    /// A started engine for one place of the controller, or nil (said in the log).
    private static func engine(_ controller: GCController, _ locality: GCHapticsLocality, step: Int,
                               hapticsOnly: Bool) -> CHHapticEngine? {
        guard let haptics = controller.haptics else {
            LogFiles.log("Controller rumble test \(step): the controller offers no haptics")
            return nil
        }
        guard let engine = haptics.createEngine(withLocality: locality) else {
            LogFiles.log("Controller rumble test \(step): no engine for \(locality.rawValue)")
            return nil
        }
        if hapticsOnly {
            engine.playsHapticsOnly = true
        }
        engine.stoppedHandler = { reason in
            LogFiles.log("Controller rumble test \(step): the engine for \(locality.rawValue) stopped (reason \(reason.rawValue))")
        }
        do {
            try engine.start()
        } catch {
            LogFiles.log("Controller rumble test \(step): the engine for \(locality.rawValue) did not start (\(describe(error)))")
            return nil
        }
        return engine
    }

    /// The grips' engines (one for both when the controller has no engine for each).
    private static func gripLocalities(_ controller: GCController) -> [GCHapticsLocality] {
        let has = controller.haptics?.supportedLocalities ?? []
        if has.contains(.leftHandle) && has.contains(.rightHandle) {
            return [.leftHandle, .rightHandle]
        }
        return [has.contains(.handles) ? .handles : .default]
    }

    /// An endless pattern at full strength on each grip, its strength set as the game's rumble
    /// sets it.
    private static func endless(_ controller: GCController, step: Int, hapticsOnly: Bool,
                                advanced: Bool) -> (() -> Void)? {
        var playing: [(CHHapticEngine, CHHapticPatternPlayer)] = []
        for locality in gripLocalities(controller) {
            guard let engine = engine(controller, locality, step: step, hapticsOnly: hapticsOnly) else {
                continue
            }
            do {
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)],
                    relativeTime: 0,
                    duration: TimeInterval(GCHapticDurationInfinite))
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let player: CHHapticPatternPlayer
                if advanced {
                    player = try engine.makeAdvancedPlayer(with: pattern)
                } else {
                    player = try engine.makePlayer(with: pattern)
                }
                try player.sendParameters(
                    [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 1.0, relativeTime: 0)],
                    atTime: 0)
                try player.start(atTime: 0)
                LogFiles.log("Controller rumble test \(step): \(locality.rawValue) plays")
                playing.append((engine, player))
            } catch {
                LogFiles.log("Controller rumble test \(step): \(locality.rawValue) could not play (\(describe(error)))")
                engine.stop(completionHandler: nil)
            }
        }
        guard !playing.isEmpty else { return nil }
        return {
            for (engine, player) in playing {
                try? player.stop(atTime: 0)
                engine.stop(completionHandler: nil)
            }
        }
    }

    /// One pattern played once on the controller's default engine.
    private static func pattern(_ controller: GCController, step: Int,
                                events: [CHHapticEvent]) -> (() -> Void)? {
        guard let engine = engine(controller, .default, step: step, hapticsOnly: false) else {
            return nil
        }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
            LogFiles.log("Controller rumble test \(step): plays")
            return {
                try? player.stop(atTime: 0)
                engine.stop(completionHandler: nil)
            }
        } catch {
            LogFiles.log("Controller rumble test \(step): could not play (\(describe(error)))")
            engine.stop(completionHandler: nil)
            return nil
        }
    }

    /// The DualSense's adaptive triggers: vibrating for a second and a half, then hard to press.
    /// Their status after each change goes to the log.
    private static func triggers(_ controller: GCController) -> (() -> Void)? {
        guard let dualSense = controller.extendedGamepad as? GCDualSenseGamepad else {
            LogFiles.log("Controller rumble test 5: not a DualSense, no adaptive triggers")
            return nil
        }
        let left = dualSense.leftTrigger
        let right = dualSense.rightTrigger
        func status(_ when: String) {
            LogFiles.log("Controller rumble test 5 (\(when)): L2 mode \(left.mode.rawValue) status \(left.status.rawValue); R2 mode \(right.mode.rawValue) status \(right.status.rawValue)")
        }
        left.setModeVibrationWithStartPosition(0, amplitude: 1.0, frequency: 0.6)
        right.setModeVibrationWithStartPosition(0, amplitude: 1.0, frequency: 0.6)
        status("vibration set")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            status("vibration, half a second later")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            left.setModeFeedbackWithStartPosition(0, resistiveStrength: 1.0)
            right.setModeFeedbackWithStartPosition(0, resistiveStrength: 1.0)
            status("resistance set")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            status("resistance, a second later")
        }
        return {
            left.setModeOff()
            right.setModeOff()
            status("off")
        }
    }
}
