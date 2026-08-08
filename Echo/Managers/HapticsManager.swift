import AVFoundation
import CoreHaptics
import UIKit

/// All hit/fire feedback: Core Haptics patterns with UIFeedbackGenerator
/// fallbacks, synthesized sounds via SoundManager, and a torch muzzle flash.
final class HapticsManager {
    private var engine: CHHapticEngine?
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactRigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notify = UINotificationFeedbackGenerator()

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            engine.resetHandler = { [weak engine] in try? engine?.start() }
            try engine.start()
            self.engine = engine
        } catch {
            print("[Haptics] engine unavailable: \(error)")
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

    /// Victim-side damage: heavy ×3 burst over a thud tail, per the plan.
    func playDamage() {
        SoundManager.shared.play("hit")
        let thud = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
            ],
            relativeTime: 0, duration: 0.25)
        play([transient(0, intensity: 1.0, sharpness: 0.6),
              transient(0.08, intensity: 1.0, sharpness: 0.6),
              transient(0.16, intensity: 1.0, sharpness: 0.6),
              thud]) {
            self.impactHeavy.impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.impactHeavy.impactOccurred() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.impactHeavy.impactOccurred() }
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

    func playRespawn() { notify.notificationOccurred(.success) }
    func playGameStart() { notify.notificationOccurred(.success) }
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

    private func play(_ events: [CHHapticEvent], fallback: () -> Void) {
        guard let engine else { fallback(); return }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try engine.start()
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback()
        }
    }
}
