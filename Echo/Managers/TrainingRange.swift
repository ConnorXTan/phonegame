import ARKit
import Foundation
import simd

/// Drone-lifetime tiers, picked by shooting a start orb at the console.
enum TrainingDifficulty: String, CaseIterable, Identifiable {
    case easy, medium, hard

    var id: String { rawValue }

    /// Chip-style label on the orb (2–3 words max, so uppercase is fine).
    var label: String { rawValue.uppercased() }

    /// How long each drone stays up before it escapes. Four hearts at one
    /// heart per hit means four taps — even HARD leaves room to flick,
    /// settle, and land them all at Regular's half-second cadence.
    var droneLifetime: TimeInterval {
        switch self {
        case .easy: return 8
        case .medium: return 6
        case .hard: return 4
        }
    }
}

/// One pop-up target. Flat one heart per hit regardless of loadout — the
/// range drills flicking and tracking, not damage math — so every drone is
/// exactly four taps.
struct TrainingDrone: Identifiable {
    static let maxHP = 4

    let id: String
    let position: simd_float3
    var hp: Int = TrainingDrone.maxHP
    let spawnedAt: Date
    let expiresAt: Date

    /// 1 → 0 as the escape clock runs — drives the ring around the sprite.
    func remainingFraction(at date: Date) -> Double {
        let total = expiresAt.timeIntervalSince(spawnedAt)
        guard total > 0 else { return 0 }
        return max(0, min(1, expiresAt.timeIntervalSince(date) / total))
    }

    /// Seconds since spawn — drives the pop-in scale.
    func age(at date: Date) -> TimeInterval {
        date.timeIntervalSince(spawnedAt)
    }
}

/// A shootable console control — the range's only "buttons", fired at like
/// anything else so the player never lowers the phone.
struct TrainingOrb: Identifiable {
    enum Action: Equatable {
        case start(TrainingDifficulty)
        case reset
    }

    let id: String
    let action: Action
    let position: simd_float3

    var label: String {
        switch action {
        case .start(let difficulty): return difficulty.label
        case .reset: return "RESET"
        }
    }
}

/// What a trigger pull connected with, so GameEngine can route feedback.
enum TrainingShotOutcome {
    case miss
    case droneHit
    case droneKill
    case orbHit
}

/// Solo drill state: a console of glowing orbs anchored ~2 m ahead of where
/// the player entered, and 30 drones that pop up one at a time in a frontal
/// arc, each with 4 HP and a difficulty-set escape clock. Everything is
/// local — no network, no UWB; ARKit's world frame is the only anchor, so
/// even a phone without a U2 chip can drill here.
///
/// Owned by GameEngine while `phase == .training`. GameEngine's aim timer
/// drives `tick`, its `fire()` routes trigger pulls into `registerShot`, and
/// the shot test mirrors `resolveShot`'s rule — most-centered target inside
/// the same aim cone — so the range trains the real trigger.
final class TrainingRange: ObservableObject {

    enum State: Equatable {
        /// Waiting for ARKit tracking to settle so the console can anchor.
        case placing
        case idle
        case running
        case finished
    }

    @Published private(set) var state: State = .placing
    @Published private(set) var drone: TrainingDrone?
    @Published private(set) var orbs: [TrainingOrb] = []
    @Published private(set) var difficulty: TrainingDifficulty = .medium
    @Published private(set) var kills = 0
    @Published private(set) var spawnedCount = 0
    @Published private(set) var shots = 0
    @Published private(set) var hits = 0
    /// Where the last drone died, for the overlay's kill burst.
    @Published private(set) var lastKill: (position: simd_float3, at: Date)?

    /// Wall-clock length of the last finished run.
    private(set) var runDuration: TimeInterval = 0

    static let dronesPerRun = 30

    var accuracy: Double? {
        shots > 0 ? Double(hits) / Double(shots) : nil
    }

    // MARK: - Console geometry (meters — physical layout, not UI rhythm)

    /// Center of the orb row, frozen the first time tracking is good.
    private(set) var consoleCenter: simd_float3?
    private var consoleRight = simd_float3(1, 0, 0)
    /// Player → console at placement; the spawn arc is centered on it.
    private var consoleForward = simd_float3(0, 0, -1)

    /// How far ahead the console anchors.
    static let consoleDistance: Float = 2.2
    /// Orb row pitch — far enough apart that the 9° aim cone at 2.2 m
    /// (radius ≈ 0.35 m) can't cover two orbs at once.
    static let orbSpacing: Float = 0.8
    /// Orb sphere radius; the overlay sizes sprites off this.
    static let orbRadius: Float = 0.07
    /// The counter panel floats this far above the orb row.
    static let counterLift: Float = 0.5
    /// Drone body radius, for perspective sizing in the overlay.
    static let droneRadius: Float = 0.18

    // MARK: - Run geometry

    private var runOrigin = simd_float3()
    private var lastAzimuth: Float = 0
    private var nextSpawnAt: Date?
    private var runStartedAt: Date?

    /// A beat after the start orb to turn from the console to the arc.
    private static let firstSpawnDelay: TimeInterval = 1.0
    /// Breather between drones so the kill (or escape) reads before the flick.
    private static let interSpawnGap: TimeInterval = 0.4

    // MARK: - Tick (driven by GameEngine's aim timer, ~10 Hz)

    func tick(session: ARSession, at now: Date) {
        guard consoleCenter != nil else {
            tryPlaceConsole(session: session)
            return
        }
        guard state == .running else { return }
        if let current = drone, current.expiresAt <= now {
            drone = nil   // escaped
            scheduleNextSpawn(from: now)
        }
        guard drone == nil else { return }
        if spawnedCount >= Self.dronesPerRun {
            finishRun(at: now)
        } else if let due = nextSpawnAt, now >= due {
            spawnDrone(at: now)
        }
    }

    /// Anchor the console once ARKit is tracking: ~2 m out along the
    /// gravity-leveled view axis, a touch below eye line so orbs never sit
    /// on top of the drone arc behind them.
    private func tryPlaceConsole(session: ARSession) {
        guard let frame = session.currentFrame,
              case .normal = frame.camera.trackingState else { return }
        let t = frame.camera.transform
        let camera = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let look = -simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let flat = simd_float3(look.x, 0, look.z)
        // Pointing at the floor or ceiling gives no usable heading — wait.
        guard simd_length(flat) > 0.3 else { return }
        consoleForward = simd_normalize(flat)
        consoleRight = simd_normalize(simd_cross(consoleForward, simd_float3(0, 1, 0)))
        consoleCenter = camera + consoleForward * Self.consoleDistance
            + simd_float3(0, -0.25, 0)
        orbs = difficultyOrbs()
        state = .idle
    }

    // MARK: - Shooting

    /// The most-centered shootable inside the aim cone — the virtual twin of
    /// GameEngine.resolveShot, minus the radio.
    func aimedTargetID(camera transform: simd_float4x4?, coneRadians: Float) -> String? {
        guard let transform else { return nil }
        var best: (id: String, angle: Float)?
        func consider(_ id: String, _ position: simd_float3) {
            guard let angle = Self.angleOffBoresight(to: position, camera: transform),
                  angle < coneRadians else { return }
            if best == nil || angle < best!.angle { best = (id, angle) }
        }
        if let drone { consider(drone.id, drone.position) }
        for orb in orbs { consider(orb.id, orb.position) }
        return best?.id
    }

    /// Resolve one trigger pull. Cooldown, ammo, and reload gating live in
    /// GameEngine; by the time this runs, a round is definitely leaving.
    func registerShot(camera transform: simd_float4x4?, coneRadians: Float,
                      at now: Date = Date()) -> TrainingShotOutcome {
        if state == .running { shots += 1 }
        guard let id = aimedTargetID(camera: transform, coneRadians: coneRadians) else {
            return .miss
        }
        if var current = drone, current.id == id {
            hits += 1
            current.hp -= 1
            guard current.hp > 0 else {
                kills += 1
                lastKill = (current.position, now)
                drone = nil
                scheduleNextSpawn(from: now)
                return .droneKill
            }
            drone = current
            return .droneHit
        }
        if let orb = orbs.first(where: { $0.id == id }), let transform {
            apply(orb.action, camera: transform, at: now)
            return .orbHit
        }
        return .miss
    }

    /// VoiceOver name for whatever the reticle is locked on.
    func displayName(for id: String) -> String? {
        if drone?.id == id { return "drone" }
        guard let orb = orbs.first(where: { $0.id == id }) else { return nil }
        switch orb.action {
        case .start(let difficulty): return "\(difficulty.rawValue) start orb"
        case .reset: return "reset orb"
        }
    }

    // MARK: - Private

    private func apply(_ action: TrainingOrb.Action, camera t: simd_float4x4, at now: Date) {
        switch action {
        case .start(let picked):
            difficulty = picked
            kills = 0
            spawnedCount = 0
            shots = 0
            hits = 0
            runDuration = 0
            lastKill = nil
            // The arc is anchored where the player stood when they pulled
            // the start trigger — they're facing the console, so "frontal"
            // and "toward the console" agree.
            runOrigin = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            runStartedAt = now
            nextSpawnAt = now.addingTimeInterval(Self.firstSpawnDelay)
            drone = nil
            orbs = resetOrbRow()
            state = .running
        case .reset:
            guard state == .running else { return }
            drone = nil
            nextSpawnAt = nil
            runStartedAt = nil
            kills = 0
            spawnedCount = 0
            shots = 0
            hits = 0
            orbs = difficultyOrbs()
            state = .idle
        }
    }

    private func finishRun(at now: Date) {
        runDuration = runStartedAt.map { now.timeIntervalSince($0) } ?? 0
        runStartedAt = nil
        nextSpawnAt = nil
        orbs = difficultyOrbs()
        state = .finished
    }

    private func scheduleNextSpawn(from now: Date) {
        nextSpawnAt = now.addingTimeInterval(Self.interSpawnGap)
    }

    private func spawnDrone(at now: Date) {
        spawnedCount += 1
        drone = TrainingDrone(
            id: "drone-\(spawnedCount)",
            position: nextSpawnPosition(),
            spawnedAt: now,
            expiresAt: now.addingTimeInterval(difficulty.droneLifetime))
        nextSpawnAt = nil
    }

    /// Frontal arc, Valorant-style: azimuths within ±75° of the console line
    /// but outside ±12° — the RESET orb sits dead ahead, and a drone behind
    /// it could otherwise hand the shot to the orb and abort the run. Each
    /// spawn lands at least 25° from the last so every drone demands a real
    /// flick; 2.5–5 m out, in the hand-height band around the shooter.
    private func nextSpawnPosition() -> simd_float3 {
        var azimuth: Float = 0
        for _ in 0..<8 {
            let magnitude = Float.random(in: (12 * .pi / 180)...(75 * .pi / 180))
            azimuth = magnitude * (Bool.random() ? 1 : -1)
            if abs(azimuth - lastAzimuth) >= 25 * .pi / 180 { break }
        }
        lastAzimuth = azimuth
        let direction = simd_quatf(angle: azimuth, axis: simd_float3(0, 1, 0))
            .act(consoleForward)
        let distance = Float.random(in: 2.5...5)
        let lift = Float.random(in: -0.4...0.3)
        return runOrigin + direction * distance + simd_float3(0, lift, 0)
    }

    private func difficultyOrbs() -> [TrainingOrb] {
        guard let center = consoleCenter else { return [] }
        return TrainingDifficulty.allCases.enumerated().map { index, difficulty in
            TrainingOrb(
                id: "orb-\(difficulty.rawValue)",
                action: .start(difficulty),
                position: center + consoleRight * (Float(index - 1) * Self.orbSpacing))
        }
    }

    private func resetOrbRow() -> [TrainingOrb] {
        guard let center = consoleCenter else { return [] }
        return [TrainingOrb(id: "orb-reset", action: .reset, position: center)]
    }

    /// Radians between the camera's view axis (straight out the back of the
    /// phone) and the ray to `point` — the virtual twin of
    /// RangingReading.angleOffBoresight. ARKit's camera looks down its -Z.
    static func angleOffBoresight(to point: simd_float3, camera t: simd_float4x4) -> Float? {
        let origin = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let boresight = -simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let offset = point - origin
        let distance = simd_length(offset)
        guard distance > 0.2 else { return nil }   // standing inside it — no aim solution
        return acos(max(-1, min(1, simd_dot(boresight, offset / distance))))
    }
}
