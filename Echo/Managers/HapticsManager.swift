import AudioToolbox
import AVFoundation
import CoreHaptics
import UIKit

/// All hit/fire feedback: Core Haptics patterns with UIFeedbackGenerator
/// fallbacks, synthesized sounds via SoundManager, and a torch muzzle flash.
final class HapticsManager {
    private var engine: CHHapticEngine?
    private var engineRunning = false
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactRigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notify = UINotificationFeedbackGenerator()

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            // Every pattern here is haptic-only (audio goes through SoundManager),
            // so detach from the audio session: a hit still buzzes with the ringer
            // silenced, or while another app owns audio.
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak self] in
                self?.engineRunning = false
                self?.startEngine()
            }
            // Fires on idle auto-shutdown, backgrounding, and audio interruptions;
            // without this the engine stays dead and every later pattern no-ops.
            engine.stoppedHandler = { [weak self] _ in self?.engineRunning = false }
            self.engine = engine
            startEngine()
        } catch {
            print("[Haptics] engine unavailable: \(error)")
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Warm the Taptic Engine so the first hit of a match isn't the slow one.
    func prepare() {
        startEngine()
        impactHeavy.prepare()
        impactLight.prepare()
        impactRigid.prepare()
        notify.prepare()
    }

    @objc private func appDidBecomeActive() { startEngine() }

    private func startEngine() {
        guard let engine, !engineRunning else { return }
        do {
            try engine.start()
            engineRunning = true
        } catch {
            print("[Haptics] engine start failed: \(error)")
        }
    }

    // MARK: - Game events

    func playFire() {
        SoundManager.shared.play("pew")
        flashTorch()
        play([transient(0, intensity: 0.8, sharpness: 0.9)]) {
            self.impactRigid.impactOccurred()
        }
    }

    /// Shooter-side hit confirmation: crisp double tick.
    func playHitMarker() {
        play([transient(0, intensity: 0.7, sharpness: 1.0),
              transient(0.06, intensity: 0.7, sharpness: 1.0)]) {
            self.impactLight.impactOccurred()
        }
    }

    /// Victim-side damage: a full-intensity slam you can't miss — four heavy
    /// knocks riding a 0.45 s rumble that decays away, per the plan.
    func playDamage() {
        SoundManager.shared.play("hit")
        let thud = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35),
            ],
            relativeTime: 0, duration: 0.45)
        let decay = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 1.0),
                .init(relativeTime: 0.3, value: 0.6),
                .init(relativeTime: 0.45, value: 0),
            ],
            relativeTime: 0)
        play([transient(0, intensity: 1.0, sharpness: 0.7),
              transient(0.09, intensity: 1.0, sharpness: 0.7),
              transient(0.18, intensity: 1.0, sharpness: 0.6),
              transient(0.27, intensity: 1.0, sharpness: 0.5),
              thud],
             curves: [decay]) {
            self.systemVibrate()
            self.impactHeavy.impactOccurred(intensity: 1.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.impactHeavy.impactOccurred(intensity: 1.0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.impactHeavy.impactOccurred(intensity: 1.0) }
        }
    }

    /// Long power-down rumble with fading thumps.
    func playDeath() {
        SoundManager.shared.play("death")
        let rumble = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15),
            ],
            relativeTime: 0, duration: 1.1)
        play([rumble,
              transient(0, intensity: 1.0, sharpness: 0.4),
              transient(0.18, intensity: 0.9, sharpness: 0.35),
              transient(0.36, intensity: 0.8, sharpness: 0.3),
              transient(0.6, intensity: 0.6, sharpness: 0.25)]) {
            self.systemVibrate()
            self.notify.notificationOccurred(.error)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.impactHeavy.impactOccurred() }
        }
    }

    func playKillConfirm() {
        play([transient(0, intensity: 1, sharpness: 1),
              transient(0.08, intensity: 1, sharpness: 1),
              transient(0.16, intensity: 1, sharpness: 1)]) {
            self.notify.notificationOccurred(.success)
        }
    }

    /// Mag out: a soft double-clunk so an empty gun is felt, not just seen.
    func playReloadStart() {
        play([transient(0, intensity: 0.55, sharpness: 0.25),
              transient(0.11, intensity: 0.45, sharpness: 0.2)]) {
            self.impactLight.impactOccurred()
        }
    }

    /// Mag in: one crisp snap — you're live again without looking down.
    func playReloadComplete() {
        play([transient(0, intensity: 0.9, sharpness: 0.85)]) {
            self.impactRigid.impactOccurred()
        }
    }

    func playRespawn() { notify.notificationOccurred(.success) }
    func playGameStart() { notify.notificationOccurred(.success) }

    /// Time's up: three slowing thumps, like a final buzzer.
    func playMatchEnd() {
        play([transient(0, intensity: 1.0, sharpness: 0.5),
              transient(0.22, intensity: 0.9, sharpness: 0.45),
              transient(0.55, intensity: 1.0, sharpness: 0.4)]) {
            self.notify.notificationOccurred(.warning)
        }
    }

    func playLockTick() { impactLight.impactOccurred(intensity: 0.6) }
    func playDistantShot() { SoundManager.shared.play("pew", volume: 0.25) }

    // MARK: - Torch muzzle flash

    private let torchQueue = DispatchQueue(label: "echo.torch")

    /// Pop the flashlight for ~80 ms on fire. Best-effort: the torch can be
    /// unavailable while ARKit camera assistance owns the camera pipeline.
    private func flashTorch() {
        torchQueue.async {
            guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                try device.setTorchModeOn(level: 1.0)
                device.unlockForConfiguration()
            } catch { return }
            Thread.sleep(forTimeInterval: 0.08)
            if (try? device.lockForConfiguration()) != nil {
                device.torchMode = .off
                device.unlockForConfiguration()
            }
        }
    }

    // MARK: - Private

    private func transient(_ time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: time)
    }

    private func play(_ events: [CHHapticEvent],
                      curves: [CHHapticParameterCurve] = [],
                      fallback: () -> Void) {
        guard let engine else { fallback(); return }
        startEngine()   // auto-shutdown or an interruption may have stopped it
        do {
            let pattern = try CHHapticPattern(events: events, parameterCurves: curves)
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            print("[Haptics] pattern failed: \(error)")
            engineRunning = false
            fallback()
        }
    }

    /// Last resort when the device has no Taptic Engine to drive (or Core
    /// Haptics died): the plain system buzz, which ignores the ringer switch.
    private func systemVibrate() {
        guard engine == nil else { return }
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
}
