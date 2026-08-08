import AudioToolbox
import CoreHaptics
import UIKit

/// All hit/fire feedback: Core Haptics patterns with UIFeedbackGenerator
/// fallbacks, plus placeholder system sounds (swap for real pew/hit assets
/// during polish).
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
        AudioServicesPlaySystemSound(1104)
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

    /// Victim-side damage: heavy ×3 burst, per the plan.
    func playDamage() {
        AudioServicesPlaySystemSound(1057)
        play([transient(0, intensity: 1.0, sharpness: 0.5),
              transient(0.1, intensity: 1.0, sharpness: 0.5),
              transient(0.2, intensity: 1.0, sharpness: 0.5)]) {
            self.impactHeavy.impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.impactHeavy.impactOccurred() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.impactHeavy.impactOccurred() }
        }
    }

    func playDeath() {
        AudioServicesPlaySystemSound(1073)
        let rumble = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
            ],
            relativeTime: 0, duration: 0.8)
        play([rumble]) { self.notify.notificationOccurred(.error) }
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
    func playDistantShot() { AudioServicesPlaySystemSound(1103) }

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
