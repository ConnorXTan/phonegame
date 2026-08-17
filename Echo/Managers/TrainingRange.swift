import ARKit
import Foundation
import simd

/// Drone-lifetime tiers, picked by shooting a start orb at the console.
enum TrainingDifficulty: String, CaseIterable, Identifiable {
    case easy, medium, hard

    var id: String { rawValue }

    /// Chip-style label on the orb (2–3 words max, so uppercase is fine).
    var label: String { rawValue.uppercased() }

    /// How long each drone stays up before it escapes. Every loadout clears a
    /// drone in at most 2 s of trigger time (see `TrainingDrone.maxHP`), so
    /// even HARD leaves room to find it, settle, and land the burst.
    var droneLifetime: TimeInterval {
        switch self {
        case .easy: return 8
        case .medium: return 6
        case .hard: return 4
        }
    }

    /// Half-width of the spawn arc off the console line. The second difficulty
    /// axis: lifetime sets how long you have, this sets how far you have to go
    /// to get there. A portrait viewfinder sees about ±16°, so EASY spawns
    /// mostly at the frame's edge while HARD is reliably a flick past it —
    /// still inside the minimap's ±60° fan, so it's always findable.
    var arcHalfWidth: Float {
        switch self {
        case .easy: return 26 * .pi / 180
        case .medium: return 34 * .pi / 180
        case .hard: return 45 * .pi / 180
        }
    }
}

/// One pop-up target. Hits remove the shooter's own `role.damage`, the same
/// as a player, so 8 HP costs Light 8 taps, Regular 4 and Heavy 3 — roughly
/// 0.7 s, 1.5 s and 2.0 s of trigger time. Flat HP per hit would have been
/// simpler but made the drill unplayable on the slow loadouts: 8 taps at
/// Heavy's one-second cadence is 7 s against a 4 s clock, and its 5-round
/// magazine can't even hold the burst.
struct TrainingDrone: Identifiable {
    static let maxHP = 8

    let id: String
    let position: simd_float3
    /// Signed bearing off the console line at spawn, kept so the next spawn
    /// can be placed clear of every live drone.
    let azimuth: Float
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

/// Something a `tick` produced that deserves feedback. The range never reaches
/// for haptics itself — it reports, GameEngine plays.
enum TrainingEvent: Equatable {
    /// At least one drone ran out its clock and left.
    case droneEscaped
    case runFinished
}

/// Solo drill state: a console of glowing orbs anchored ~2 m ahead of where
/// the player entered, and 30 drones that pop up in a frontal arc — up to
/// three at a time, each with 4 HP and a difficulty-set escape clock.
/// Everything is local — no network, no UWB; ARKit's world frame is the only
/// anchor, so even a phone without a U2 chip can drill here.
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
    @Published private(set) var drones: [TrainingDrone] = []
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

    /// Whatever the reticle is currently holding, so the lock can be sticky
    /// (see `releaseSlack`) and so the trigger resolves against the same
    /// target the player can see is lit.
    private(set) var lockedID: String?

    static let dronesPerRun = 30
    /// How many drones can be up at once. One-at-a-time made a missed drone
    /// feel like the range had stalled — nothing on screen, nothing on the
    /// map, and no way to tell a gap from a bug. Two keeps that guarantee
    /// while leaving the drill about the target you're on rather than about
    /// triaging a crowd.
    static let maxConcurrentDrones = 2

    /// The range runs its own bookkeeping and lock test entirely on this
    /// phone, so it ticks three times faster than the networked path (which
    /// is paced by ~5 Hz UWB readings). At 10 Hz the reticle lit up as much
    /// as 100 ms after the drone was already centered.
    static let tickInterval: TimeInterval = 1.0 / 30

    var accuracy: Double? {
        shots > 0 ? Double(hits) / Double(shots) : nil
    }

    // MARK: - Console geometry (meters — physical layout, not UI rhythm)

    /// Center of the orb row, frozen the first time tracking is good.
    private(set) var consoleCenter: simd_float3?
    private var consoleRight = simd_float3(1, 0, 0)
    /// Player → console at placement; the spawn arc is centered on it.
    private var consoleForward = simd_float3(0, 0, -1)

    /// The viewport the world layer is drawn into, republished by
    /// TrainingOverlay on every layout pass. `aimedTargetID` resolves in this
    /// same space, so it has to be the size the sprites were projected into.
    private(set) var viewport: CGSize = .zero

    func setViewport(_ size: CGSize) { viewport = size }

    /// How far ahead the console anchors.
    static let consoleDistance: Float = 2.2
    /// How far below the phone the orb row sits — about 20° down at the
    /// console's 2.2 m, so it's something you glance down at and it never
    /// shares a band with the drone arc behind it.
    static let consoleDrop: Float = 0.8
    /// Orb row pitch. 0.8 m kept the aim cone from covering two orbs at once
    /// back when the cone was an angle off the camera axis — but it also put
    /// the outer orbs 20° off the console line, and a portrait viewfinder only
    /// sees about ±16°, so EASY and HARD sat off the sides of the screen and
    /// had to be panned to one at a time. At 0.45 m the whole row reads at
    /// once, and the screen-space aim test still leaves ~140 pt between
    /// neighbours — wider than the cone's radius, so the nearer orb to the
    /// crosshair wins cleanly.
    static let orbSpacing: Float = 0.45
    /// Orb sphere radius; the overlay sizes sprites off this.
    static let orbRadius: Float = 0.07
    /// The counter panel floats this far above the orb row: high enough to
    /// clear the reticle at the center of the screen, low enough to still read
    /// as part of the console rather than as free-floating chrome.
    static let counterLift: Float = 0.45
    /// Drone body radius, for perspective sizing in the overlay.
    static let droneRadius: Float = 0.18

    // MARK: - Run geometry

    private var runOrigin = simd_float3()
    private var lastAzimuth: Float = 0
    private var nextSpawnAt: Date?
    private var runStartedAt: Date?
    /// When tracking last became good — placement waits out a settle window.
    private var trackingNormalSince: Date?

    /// A beat after the start orb to turn from the console to the arc.
    private static let firstSpawnDelay: TimeInterval = 1.0
    /// Steady drip while the arc is under its concurrency cap.
    private static let interSpawnGap: TimeInterval = 1.1
    /// Top-up after a kill or an escape — short enough that clearing fast
    /// keeps targets coming fast, long enough that the replacement doesn't
    /// appear inside the hit marker.
    private static let refillGap: TimeInterval = 0.35
    /// ARKit reports `.normal` well before its pose stops being refined.
    /// Anchoring on the first good frame leaves the console visibly sliding
    /// for a second or two afterwards.
    private static let placementSettleTime: TimeInterval = 0.8

    // MARK: - Tick (driven by GameEngine's aim timer, ~30 Hz)

    @discardableResult
    func tick(session: ARSession, at now: Date) -> [TrainingEvent] {
        guard consoleCenter != nil else {
            tryPlaceConsole(session: session, at: now)
            return []
        }
        guard state == .running else { return [] }
        var events: [TrainingEvent] = []
        if drones.contains(where: { $0.expiresAt <= now }) {
            drones.removeAll { $0.expiresAt <= now }
            events.append(.droneEscaped)
            scheduleRefill(from: now)
        }
        if spawnedCount >= Self.dronesPerRun {
            // The run ends when the last drone is down or gone, not when the
            // thirtieth spawns — otherwise the tail of the arc vanishes
            // mid-flick.
            if drones.isEmpty {
                finishRun(at: now)
                // The buzzer covers the last drone leaving; firing both cues
                // on the same tick just muddies each other.
                return [.runFinished]
            }
            return events
        }
        if drones.count < Self.maxConcurrentDrones, let due = nextSpawnAt, now >= due {
            spawnDrone(at: now)
        }
        return events
    }

    /// Anchor the console once ARKit is tracking: ~2 m out along the
    /// gravity-leveled view axis, a touch below eye line so orbs never sit
    /// on top of the drone arc behind them.
    private func tryPlaceConsole(session: ARSession, at now: Date) {
        guard let frame = session.currentFrame,
              case .normal = frame.camera.trackingState else {
            trackingNormalSince = nil
            return
        }
        let settledSince = trackingNormalSince ?? now
        trackingNormalSince = settledSince
        guard now.timeIntervalSince(settledSince) >= Self.placementSettleTime else { return }
        let t = frame.camera.transform
        let camera = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let look = -simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let flat = simd_float3(look.x, 0, look.z)
        // Pointing at the floor or ceiling gives no usable heading — wait.
        guard simd_length(flat) > 0.3 else { return }
        consoleForward = simd_normalize(flat)
        consoleRight = simd_normalize(simd_cross(consoleForward, simd_float3(0, 1, 0)))
        consoleCenter = camera + consoleForward * Self.consoleDistance
            + simd_float3(0, -Self.consoleDrop, 0)
        orbs = difficultyOrbs()
        state = .idle
    }

    // MARK: - Shooting

    /// Slack on the release radius, as a multiple of the acquire radius.
    /// Without it the lock chatters on and off at the boundary: the reticle
    /// flickers, and every flip re-fires the lock haptic — which shakes the
    /// very phone the aim is measured from.
    private static let releaseSlack: CGFloat = 1.3

    /// Every shootable in the world right now, drones first.
    private var shootables: [(id: String, position: simd_float3)] {
        drones.map { ($0.id, $0.position) } + orbs.map { ($0.id, $0.position) }
    }

    /// The shootable nearest the crosshair, sticky to whatever is already held.
    ///
    /// Resolved in **screen space**, not as a 3D angle off the camera's view
    /// axis. Both are defensible in isolation, but only this one is guaranteed
    /// to agree with the picture: the sprite is drawn by projecting the anchor
    /// through this same frame and viewport, so measuring that same projection
    /// against the reticle's own position means whatever the player has the
    /// crosshair on is what the trigger resolves against. The angular test can
    /// sit a constant off the projection, and did — it's what left the console
    /// orbs needing to be aimed at from well below where they were drawn, and
    /// put the drones outside the cone entirely at every point on screen the
    /// player could see them.
    ///
    /// The networked path still resolves angularly, and has to: a UWB bearing
    /// is an angle, with no anchor to project.
    func aimedTargetID(frame: ARFrame?, coneRadians: Float) -> String? {
        guard let projector = CameraProjector(frame: frame, viewport: viewport) else { return nil }
        let aim = projector.aimPoint
        let radius = projector.coneRadius(coneRadians)
        var best: (id: String, distance: CGFloat)?
        var heldDistance: CGFloat?
        for target in shootables {
            guard let point = projector.project(target.position) else { continue }
            let distance = hypot(point.x - aim.x, point.y - aim.y)
            if target.id == lockedID { heldDistance = distance }
            guard distance < radius else { continue }
            if best == nil || distance < best!.distance { best = (target.id, distance) }
        }
        if let best { return best.id }
        // Nothing inside the acquire radius: hold the current lock as long as
        // it's still inside the wider release radius.
        if let heldDistance, heldDistance < radius * Self.releaseSlack { return lockedID }
        return nil
    }

    /// `aimedTargetID` plus the bookkeeping its hysteresis needs. Both the
    /// reticle and the trigger go through here, so what the player sees lit
    /// is what the shot resolves against.
    @discardableResult
    func refreshLock(frame: ARFrame?, coneRadians: Float) -> String? {
        let id = aimedTargetID(frame: frame, coneRadians: coneRadians)
        lockedID = id
        return id
    }

    /// Resolve one trigger pull. Cooldown, ammo, and reload gating live in
    /// GameEngine; by the time this runs, a round is definitely leaving.
    /// `damage` is the shooter's own `role.damage` — passed in rather than
    /// looked up, so the range stays ignorant of the loadout tables.
    func registerShot(frame: ARFrame?, coneRadians: Float, damage: Int,
                      at now: Date = Date()) -> TrainingShotOutcome {
        if state == .running { shots += 1 }
        guard let id = refreshLock(frame: frame, coneRadians: coneRadians) else {
            return .miss
        }
        if let index = drones.firstIndex(where: { $0.id == id }) {
            hits += 1
            drones[index].hp -= max(1, damage)
            guard drones[index].hp <= 0 else { return .droneHit }
            kills += 1
            lastKill = (drones[index].position, now)
            drones.remove(at: index)
            lockedID = nil
            scheduleRefill(from: now)
            return .droneKill
        }
        if let orb = orbs.first(where: { $0.id == id }),
           let transform = frame?.camera.transform {
            apply(orb.action, camera: transform, at: now)
            return .orbHit
        }
        return .miss
    }

    /// VoiceOver name for whatever the reticle is locked on.
    func displayName(for id: String) -> String? {
        if drones.contains(where: { $0.id == id }) { return "drone" }
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
            resetCounters()
            // The arc is anchored where the player stood when they pulled
            // the start trigger — they're facing the console, so "frontal"
            // and "toward the console" agree.
            runOrigin = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            runStartedAt = now
            nextSpawnAt = now.addingTimeInterval(Self.firstSpawnDelay)
            orbs = resetOrbRow()
            state = .running
        case .reset:
            guard state == .running else { return }
            resetCounters()
            runStartedAt = nil
            nextSpawnAt = nil
            orbs = difficultyOrbs()
            state = .idle
        }
    }

    private func resetCounters() {
        kills = 0
        spawnedCount = 0
        shots = 0
        hits = 0
        runDuration = 0
        lastKill = nil
        lastAzimuth = 0
        drones = []
        lockedID = nil
    }

    private func finishRun(at now: Date) {
        runDuration = runStartedAt.map { now.timeIntervalSince($0) } ?? 0
        runStartedAt = nil
        nextSpawnAt = nil
        orbs = difficultyOrbs()
        state = .finished
    }

    private func scheduleRefill(from now: Date) {
        nextSpawnAt = now.addingTimeInterval(Self.refillGap)
    }

    private func spawnDrone(at now: Date) {
        spawnedCount += 1
        let spawn = nextSpawnPlacement()
        lastAzimuth = spawn.azimuth
        drones.append(TrainingDrone(
            id: "drone-\(spawnedCount)",
            position: spawn.position,
            azimuth: spawn.azimuth,
            spawnedAt: now,
            expiresAt: now.addingTimeInterval(difficulty.droneLifetime)))
        nextSpawnAt = now.addingTimeInterval(Self.interSpawnGap)
    }

    /// Inner edge of the spawn arc. The RESET orb sits dead ahead, and a drone
    /// behind it could otherwise hand the shot to the orb and abort the run.
    /// The outer edge is the difficulty knob — see `arcHalfWidth`.
    private static let arcInner: Float = 10 * .pi / 180
    /// Minimum bearing gap from every live drone (and the one just before
    /// them), so no two sprites overlap and every spawn is still a real flick.
    /// Held at 12° because EASY's arc is only 16° wide per side: at 15° a live
    /// pair can leave no legal azimuth at all, and the placement loop then
    /// exhausts its tries and stacks the new drone on a neighbour anyway.
    private static let minSeparation: Float = 12 * .pi / 180

    /// 2.5–4.5 m out, in the hand-height band around the shooter.
    private func nextSpawnPlacement() -> (position: simd_float3, azimuth: Float) {
        let taken = drones.map(\.azimuth) + [lastAzimuth]
        var azimuth = randomAzimuth()
        for _ in 0..<12 {
            if taken.allSatisfy({ abs(azimuth - $0) >= Self.minSeparation }) { break }
            azimuth = randomAzimuth()
        }
        let direction = simd_quatf(angle: azimuth, axis: simd_float3(0, 1, 0))
            .act(consoleForward)
        let distance = Float.random(in: 2.5...4.5)
        let lift = Float.random(in: -0.4...0.3)
        return (runOrigin + direction * distance + simd_float3(0, lift, 0), azimuth)
    }

    private func randomAzimuth() -> Float {
        Float.random(in: Self.arcInner...difficulty.arcHalfWidth) * (Bool.random() ? 1 : -1)
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
}
