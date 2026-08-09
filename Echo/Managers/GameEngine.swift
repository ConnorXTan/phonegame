import ARKit
import AVFoundation
import Foundation
import NearbyInteraction
import simd
import UIKit

enum GamePhase: Equatable {
    case menu, browsing, lobby, playing, summary
}

/// Source of truth for game state. Hit resolution runs on the SHOOTER's phone
/// (it has the ranging data); the victim applies damage on receipt and
/// broadcasts its own health/death — at hackathon scale, trust the network.
final class GameEngine: NSObject, ObservableObject {

    @Published var playerName: String = ""
    @Published var settings: GameSettings = .standard
    /// Our loadout. Survives leave() so the pick sticks between games.
    @Published private(set) var myRole: PlayerRole = .regular
    @Published private(set) var phase: GamePhase = .menu
    @Published private(set) var isHost = false

    @Published private(set) var players: [String: Player] = [:]   // includes self, keyed by name
    @Published private(set) var killFeed: [KillEvent] = []
    @Published private(set) var aimedTarget: String?
    @Published private(set) var lastFireTime: Date?
    @Published private(set) var respawnRemaining: TimeInterval = 0
    @Published private(set) var lastKilledBy: String?
    /// Wall-clock end of our damage immunity. Enforced victim-side because each
    /// phone is authoritative for its own HP — shooters resolve independently
    /// and can't see each other, so this is the only place a crossfire can be
    /// collapsed into one hit.
    @Published private(set) var invulnerableUntil: Date?
    @Published private(set) var damageFlash = false
    @Published private(set) var uwbWarning: String?
    @Published private(set) var rangingAlert: String?
    /// Which peer `rangingAlert` is about (nil = device-wide, e.g. permission
    /// problems), so a recovery for that peer — and only that peer — dismisses it.
    private var rangingAlertPeer: String?
    @Published private(set) var hostEndedNotice: String?   // shown on the menu after a host shutdown
    @Published private(set) var aimHint: String?
    @Published private(set) var matchRemaining: TimeInterval = 0
    @Published private(set) var matchResult: MatchResult?
    @Published private(set) var ammo: Int = 0
    @Published private(set) var reloadRemaining: TimeInterval = 0
    /// Bumped on every confirmed hit we land — the HUD watches it to flash the
    /// hit marker. A counter, not a Bool, so back-to-back hits each register.
    @Published private(set) var hitMarker = HitMarker(count: 0, isKill: false)

    var isReloading: Bool { reloadRemaining > 0 }
    var magazineSize: Int { myRole.magazineSize }

    // Spectator mode (the laptop): watches the mesh, never plays.
    // A match already running when the game master arrives locks its setup
    // screen — the laptop must never take over a live game. Solo practice
    // (a one-player "match") doesn't count; it yields on Start instead.
    @Published private(set) var externalMatchPlayers = 0
    private var externalHostName: String?
    var externalMatchInProgress: Bool { isSpectator && isHost && externalMatchPlayers >= 2 }
    @Published private(set) var isSpectator = false
    @Published private(set) var watchingPlayer: String?     // wire name of the streamed player
    @Published private(set) var spectatorFrame: UIImage?
    @Published private(set) var spectatorOverlay: SpectatorOverlayState?   // their crosshair + enemy tags
    @Published private(set) var killClips: [KillClip] = []   // spectator: post-match kill review, newest last
    @Published private(set) var spectators: Set<String> = []   // peers that are spectators, not targets
    @Published private(set) var joiningLobby: String?          // wire name of the host we're connecting to
    @Published private(set) var lobbyNotice: String?           // join failures ("lobby full") for the menu/browser
    private var streamingTo: String?                           // player side: who gets our viewfinder

    private(set) var network: NetworkManager?
    /// Browse-only manager warming the peer cache while we sit on the menu.
    /// Promoted to `network` on Host/Join if the call sign still matches.
    private var prewarmed: NetworkManager?
    private var prewarmDebounce: DispatchWorkItem?
    let ranging = RangingManager()
    let haptics = HapticsManager()
    let camera = AimCameraManager()
    private let dummy = TargetDummy()

    private var aimTimer: Timer?
    private var autoFireTimer: Timer?
    private var respawnTimer: Timer?
    private var matchTimer: Timer?
    private var matchDeadline: Date?
    private var reloadTimer: Timer?
    private var pendingSnapshots: [String: (state: PlayerState, at: Date)] = [:]
    private var dummyInvulnerableUntil: Date?   // the dummy's half of the same rule

    var myName: String { network?.myName ?? playerName }
    var me: Player? { players[myName] }
    var isAlive: Bool { me?.isAlive ?? true }
    var myTeam: Team? { me?.team }

    /// Whether `player` is a legal target. Solo: everyone. Team play: only the
    /// other side — a player whose team hasn't arrived yet counts as an enemy,
    /// so a dropped teamChange can't make anyone unkillable; the victim's own
    /// same-team check absorbs the rare false positive.
    func isEnemy(_ player: Player) -> Bool {
        guard settings.teamPlay, let mine = myTeam else { return true }
        return player.team != mine
    }

    /// Combined kills for one side — the team-play score.
    func teamKills(_ team: Team) -> Int {
        players.values.filter { $0.team == team }.reduce(0) { $0 + $1.kills }
    }

    /// Takes the date so the HUD can drive a countdown off a TimelineView tick
    /// — `invulnerableUntil` publishes when the window opens, never when it
    /// lapses, so nothing would repaint on expiry otherwise.
    func isInvulnerable(at date: Date = Date()) -> Bool {
        guard let until = invulnerableUntil else { return false }
        return date < until
    }

    var opponents: [Player] {
        players.values.filter { $0.name != myName }.sorted { $0.name < $1.name }
    }

    override init() {
        super.init()
        ranging.delegate = self
        ranging.camera = camera   // one ARSession: viewfinder + camera assistance
        // Killcam: pair every buffered frame with the live HUD overlay, and
        // log app sounds so clips can rebuild their audio.
        camera.clipOverlayProvider = { [weak self] in self?.currentOverlayState() }
        SoundManager.shared.eventTap = { [weak self] name, volume, rate in
            guard let self, self.camera.clipBufferEnabled else { return }
            self.soundLog.append((name, volume, rate, Date()))
            let cutoff = Date().addingTimeInterval(-8)
            if self.soundLog.first?.at ?? Date() < cutoff {
                self.soundLog.removeAll { $0.at < cutoff }
            }
        }
        if !RangingManager.isSupported {
            uwbWarning = "This device has no UWB chip (needs iPhone 11+, non-SE). Ranging won't work here."
        } else if !RangingManager.supportsAiming {
            uwbWarning = "This device can't measure UWB direction, so aiming won't work."
        }
    }

    // MARK: - Lobby

    /// The call sign as it goes on the wire. Bonjour service instance names
    /// are capped at 63 UTF-8 bytes; leave room for the "#xxxx" uniqueness
    /// suffix. removeLast() drops whole graphemes, so emoji are never split.
    private var sanitizedCallSign: String {
        var name = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.utf8.count > 58 { name.removeLast() }
        return name
    }

    /// Start browse-only discovery while the player is still on the menu, so
    /// nearby peers are already cached when they tap Host/Join and the lobby
    /// fills in a beat instead of after the multi-second Bonjour warmup.
    /// Debounced because the call-sign field calls this per keystroke and
    /// each name change needs a fresh manager (the name is baked into the
    /// wire identity at init).
    func prewarmDiscovery() {
        prewarmDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .menu else { return }
            let name = self.sanitizedCallSign
            guard !name.isEmpty else {
                self.prewarmed?.stop()
                self.prewarmed = nil
                return
            }
            guard self.prewarmed?.playerName != name else { return }
            self.prewarmed?.stop()
            let net = NetworkManager(playerName: name)
            self.prewarmed = net
            net.startDiscovery()
        }
        prewarmDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Hand over the pre-warmed manager if its name still matches, else a
    /// cold one. Either way exactly one candidate manager is left alive.
    private func takeNetwork(named name: String) -> NetworkManager {
        prewarmDebounce?.cancel()
        defer { prewarmed = nil }
        if let warm = prewarmed, warm.playerName == name { return warm }
        prewarmed?.stop()
        return NetworkManager(playerName: name)
    }

    /// Create and host our own lobby (phone hosts).
    func enterLobby(hosting: Bool) {
        // Single entry: the menu stays tappable through the menu→lobby
        // crossfade, so a double-tap ran this twice — orphaning a live
        // NetworkManager that kept its service published and its links open.
        // Two meshes in one process discover and fight each other.
        guard phase == .menu else { return }
        let name = sanitizedCallSign
        guard !name.isEmpty else { return }
        hostEndedNotice = nil
        lobbyNotice = nil
        isHost = hosting
        network?.stop()   // there must never be two live meshes; nil here while the phase guard holds
        let net = takeNetwork(named: name)
        net.delegate = self
        network = net
        let wireName = net.myName
        players = [wireName: Player(name: wireName, role: myRole)]
        net.start(as: hosting ? .host : .player)
        refreshLobbyAdvertisement()
        // Ask now, not at match start — an open permission alert would race
        // the first NISession.run() and the viewfinder's first frame.
        camera.requestAccessIfNeeded()
        phase = .lobby
        autoAssignTeamIfNeeded()   // re-hosting with team play still on from last time
        UIApplication.shared.isIdleTimerDisabled = true   // auto-lock would drop the mesh
    }

    /// Browse for lobbies to join — as a player (phones) or spectator (Mac).
    /// A spectator with no name is just "Spectator".
    func enterBrowser(asSpectator: Bool) {
        guard phase == .menu else { return }
        var name = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.utf8.count > 58 { name.removeLast() }
        if name.isEmpty {
            guard asSpectator else { return }
            name = "Spectator"
        }
        hostEndedNotice = nil
        lobbyNotice = nil
        isSpectator = asSpectator
        isHost = false
        network?.stop()
        let net = takeNetwork(named: name)
        net.delegate = self
        network = net
        players = [:]
        if !asSpectator {
            let wireName = net.myName
            players = [wireName: Player(name: wireName, role: myRole)]
            camera.requestAccessIfNeeded()
        }
        net.start(as: asSpectator ? .spectator : .player)
        phase = .browsing
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Tap a lobby in the browser: connect to its host. Membership (or a
    /// "full" denial) comes back over messages once the host answers.
    func joinLobby(_ lobby: DiscoveredLobby) {
        guard phase == .browsing, joiningLobby == nil, let net = network else { return }
        joiningLobby = lobby.hostName
        net.join(lobby)
        let target = lobby.hostName
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.phase == .browsing, self.joiningLobby == target else { return }
            self.joiningLobby = nil
            self.lobbyNotice = "Couldn't reach \(target.displayCallSign)'s lobby — move closer and retry."
        }
    }

    /// Host only: re-advertise occupancy/capacity/live state after changes.
    func refreshLobbyAdvertisement() {
        guard isHost else { return }
        network?.updateLobbyAdvertisement(
            playerCount: players.keys.filter { $0 != TargetDummy.name }.count,
            capacity: settings.maxPlayers,
            isLive: phase == .playing,
            isTeams: settings.teamPlay)
    }

    /// Host edited a lobby setting: push the whole struct so joiners' lobby
    /// screens track it live — without this they'd learn about team play only
    /// when the match starts, too late to pick a side.
    func hostSettingsChanged() {
        guard isHost, phase == .lobby else { return }
        network?.send(.settingsUpdate(settings: settings))
        refreshLobbyAdvertisement()
    }

    /// Host flips the mode between solo and teams.
    func setTeamPlay(_ on: Bool) {
        guard isHost, phase == .lobby else { return }
        settings.teamPlay = on
        hostSettingsChanged()
        if on { autoAssignTeamIfNeeded() }
    }

    /// Pick a side (or switch) while in the lobby. Team choice is
    /// self-authoritative, like every other row field.
    func selectTeam(_ team: Team) {
        guard settings.teamPlay, !isSpectator, phase == .lobby,
              players[myName] != nil, myTeam != team else { return }
        players[myName]?.team = team
        network?.send(.teamChange(player: myName, team: team))
    }

    /// First contact with team play and no side yet: join the emptier team.
    /// Ties go to alpha, so the host seeds alpha and the first joiner lands
    /// bravo. Two simultaneous joiners can land together — that's what the
    /// manual switch is for.
    private func autoAssignTeamIfNeeded() {
        guard settings.teamPlay, !isSpectator, phase == .lobby,
              let mine = players[myName], mine.team == nil else { return }
        let alphaCount = players.values.filter { $0.team == .alpha }.count
        let bravoCount = players.values.filter { $0.team == .bravo }.count
        let team: Team = bravoCount < alphaCount ? .bravo : .alpha
        players[myName]?.team = team
        network?.send(.teamChange(player: myName, team: team))
    }

    /// Host only: tell everyone who's in — players and spectators separately.
    /// Members mesh among themselves off this list, and the lobby screens
    /// render their sections from it. A Mac game master lists itself as a
    /// spectator so joiners can see who's running the show.
    private func broadcastRoster() {
        guard isHost, let net = network else { return }
        let playerNames = players.keys.filter { $0 != TargetDummy.name }.sorted()
        var spectatorNames = spectators.sorted()
        if isSpectator { spectatorNames.append(myName) }
        net.send(.lobbyRoster(players: playerNames, spectators: spectatorNames))
        net.updateRoster(playerNames + spectatorNames)
    }

    func leave() {
        if isHost, phase != .menu, let net = network {
            // Tell everyone before tearing down, and give the reliable send a
            // beat to flush — disconnect() right after send can drop it.
            net.send(.hostEnded)
            network = nil   // stale-guards drop any further callbacks
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { net.stop() }
        } else {
            network?.stop()
            network = nil
        }
        despawnDummy()
        ranging.stopAll()
        camera.frameTap = nil
        camera.clipBufferEnabled = false
        pendingKillClips = []
        delayedCaptures = []
        killClips = []
        camera.stop()   // after the NI sessions that were using it
        stopTimers()
        players = [:]
        killFeed = []
        aimedTarget = nil
        lastFireTime = nil
        lastKilledBy = nil
        invulnerableUntil = nil
        damageFlash = false
        rangingAlert = nil
        rangingAlertPeer = nil
        pendingSnapshots = [:]
        matchResult = nil
        isHost = false
        isSpectator = false
        watchingPlayer = nil
        spectatorFrame = nil
        spectatorOverlay = nil
        spectators = []
        joiningLobby = nil
        clearExternalMatch()
        streamingTo = nil
        phase = .menu
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Join the mesh as a pure observer — no Player entry, no ranging, no
    /// camera. The laptop's mode: it can still host (Start button, settings,
    /// authoritative match end) because "host" is only a protocol convention.
    func enterSpectator(hosting: Bool) {
        guard phase == .menu else { return }   // same re-entry hazard as enterLobby
        hostEndedNotice = nil
        lobbyNotice = nil
        isSpectator = true
        isHost = hosting
        var name = playerName.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.utf8.count > 58 { name.removeLast() }
        if name.isEmpty { name = "Spectator" }   // the name field is optional here
        network?.stop()
        let net = takeNetwork(named: name)
        net.delegate = self
        network = net
        players = [:]
        net.start(as: hosting ? .host : .spectator)
        refreshLobbyAdvertisement()
        phase = .lobby
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Pick a loadout. Lobby-only: switching mid-match would re-base HP and
    /// let a dying player heal by swapping to Heavy.
    func selectRole(_ role: PlayerRole) {
        guard phase == .lobby, !isSpectator, role != myRole else { return }
        myRole = role
        players[myName]?.role = role
        players[myName]?.hp = role.maxHP
        network?.send(.roleSelect(player: myName, role: role))
    }

    /// Spectator: switch whose viewfinder we're watching (nil = stop).
    func watch(_ name: String?) {
        guard isSpectator, let net = network else { return }
        if let current = watchingPlayer, current != name {
            net.send(.cameraRequest(active: false), to: [current])
        }
        watchingPlayer = name
        spectatorFrame = nil
        spectatorOverlay = nil
        if let name {
            net.send(.cameraRequest(active: true), to: [name])
        }
    }

    /// Streamer side: the HUD elements worth mirroring on the spectator's
    /// feed — crosshair lock and the floating enemy tags. Mirrors
    /// EnemyHealthbarOverlay's projection, but into a fixed 3:4 viewport so
    /// positions are normalized against the FULL portrait camera frame the
    /// spectator receives (the phone screen shows a crop; the stream doesn't).
    private func currentOverlayState() -> SpectatorOverlayState {
        let viewport = CGSize(width: 300, height: 400)
        var tags: [SpectatorOverlayState.Tag] = []
        if let frame = camera.session.currentFrame {
            let now = Date()
            for player in opponents where player.isAlive && player.isConnected {
                guard let reading = ranging.latestReading(for: player.name),
                      now.timeIntervalSince(reading.timestamp) < 1.0 else { continue }
                var world = ranging.worldPosition(for: player.name)
                if world == nil,
                   let directional = ranging.latestDirectional(for: player.name, within: 1.0) {
                    world = Self.synthesizedWorld(from: directional, camera: frame.camera)
                }
                guard let world else { continue }
                let inCamera = frame.camera.transform.inverse * simd_float4(world, 1)
                guard inCamera.z < 0 else { continue }   // behind the lens projects to a mirrored ghost
                let point = frame.camera.projectPoint(world, orientation: .portrait, viewportSize: viewport)
                guard point.x > -20, point.x < viewport.width + 20,
                      point.y > 0, point.y < viewport.height else { continue }
                tags.append(SpectatorOverlayState.Tag(
                    name: player.name.displayCallSign,
                    x: point.x / viewport.width,
                    y: point.y / viewport.height,
                    hp: Double(player.hp) / Double(max(1, player.role.maxHP))))
            }
        }
        return SpectatorOverlayState(tags: tags, lockedTarget: aimedTarget?.displayCallSign)
    }

    /// Same fallback EnemyHealthbarOverlay uses when no world transform
    /// exists: cast the device-frame reading out from the camera pose.
    private static func synthesizedWorld(from reading: RangingReading, camera: ARCamera) -> simd_float3? {
        let deviceDirection: simd_float3
        if let d = reading.direction {
            deviceDirection = d
        } else if let h = reading.horizontalAngle {
            deviceDirection = simd_float3(sin(h), 0, -cos(h))
        } else {
            return nil
        }
        let deviceToCamera = simd_quatf(angle: .pi / 2, axis: simd_float3(0, 0, 1))
        let inCamera = deviceToCamera.act(deviceDirection)
        let t = camera.transform
        let world4 = t * simd_float4(inCamera, 0)
        let origin = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let direction = simd_normalize(simd_float3(world4.x, world4.y, world4.z))
        return origin + direction * (reading.distance ?? TargetDummy.distance)
    }

    /// Host taps Start: broadcast settings, then start locally. The game
    /// master can't start while somebody else's real match is running.
    func startGame() {
        guard phase == .lobby, isHost, !externalMatchInProgress, let net = network else { return }
        net.send(.startGame(settings: settings))
        beginMatch(with: settings)
    }

    private func clearExternalMatch() {
        externalHostName = nil
        externalMatchPlayers = 0
    }

    private func beginMatch(with settings: GameSettings) {
        self.settings = settings
        // Backstop for a joiner who connected right as the host hit Start and
        // never saw a .settingsUpdate — phase is still .lobby here.
        autoAssignTeamIfNeeded()
        for (name, player) in players {
            players[name]?.hp = player.role.maxHP
            players[name]?.isAlive = true
            players[name]?.kills = 0
            players[name]?.deaths = 0
        }
        killFeed = []
        lastKilledBy = nil
        lastFireTime = nil
        invulnerableUntil = nil
        rangingAlert = nil
        rangingAlertPeer = nil
        // U2 iPhones (15/16) aim exclusively through the camera; if its
        // permission was denied, direction data can never arrive.
        if !isSpectator,
           !NISession.deviceCapabilities.supportsDirectionMeasurement,
           NISession.deviceCapabilities.supportsCameraAssistance,
           AVCaptureDevice.authorizationStatus(for: .video) == .denied {
            rangingAlert = "Camera access is off — this iPhone aims through the camera. Enable it: Settings → Apps → Echo → Camera."
        }
        // Late join: snapshots can arrive before .startGame (different senders,
        // independent ordering). Apply any fresh ones on top of the reset.
        for entry in pendingSnapshots.values where Date().timeIntervalSince(entry.at) < 5 {
            apply(entry.state)
        }
        pendingSnapshots = [:]
        matchResult = nil
        pendingKillClips = []
        killClips = []          // spectator: last match's review makes way
        cancelReload()
        ammo = myRole.magazineSize
        phase = .playing
        UIApplication.shared.isIdleTimerDisabled = true   // UWB needs the app foregrounded
        startMatchClock(seconds: settings.matchDuration)
        refreshLobbyAdvertisement()   // the lobby list shows this one as LIVE
        guard !isSpectator else { return }   // observers need only the clock and the mirror

        // Before any NISession.run() below, so ranging attaches to a session
        // that's already delivering frames. Also covers solo practice, where
        // there are no peers and so no NI session to start it.
        camera.start()
        camera.clipBufferEnabled = true   // killcam: keep the last ~5 s rolling
        startAimTimer()
        haptics.prepare()
        SoundManager.shared.prepare()
        haptics.playGameStart()

        // Pairwise UWB token exchange with every connected PLAYER (spectators
        // don't range). Both sides send; ordering races are handled inside
        // RangingManager.
        let playerPeers = (network?.connectedPeers ?? []).filter { !spectators.contains($0) }
        if !playerPeers.isEmpty {
            for peer in playerPeers {
                if let data = ranging.prepare(peerName: peer) {
                    network?.send(.discoveryToken(data), to: [peer])
                }
            }
        } else {
            spawnDummy()   // solo test: nobody to shoot, so conjure a target
        }
    }

    // MARK: - Combat

    func fire() {
        guard phase == .playing, isAlive, let net = network else { return }
        guard !isReloading else { return }
        // Dry trigger on an empty mag racks the reload instead of firing.
        guard ammo > 0 else { startReload(); return }
        let now = Date()
        if let last = lastFireTime, now.timeIntervalSince(last) < myRole.fireCooldown { return }
        lastFireTime = now
        ammo -= 1
        // Resolve BEFORE any feedback. Ranging readings are only good for
        // 0.2 s, and playing audio/haptics first can burn longer than that —
        // the shot would then be scored against stale directions and miss a
        // target the crosshair is plainly locked onto.
        let victim = resolveShot()
        haptics.playFire()
        net.send(.shotFired(by: myName))
        defer { if ammo == 0 { startReload() } }   // auto-reload on the last round
        guard let victim else { return }
        if victim == TargetDummy.name {
            hitDummy()
        } else if net.isConnected(victim) {
            net.send(.hit(target: victim, by: myName, damage: myRole.damage), to: [victim])
            confirmHit()
            // Optimistic: drop their bar now instead of a network round trip
            // later; the victim's authoritative .healthUpdate reconciles it.
            // Never kill optimistically — isAlive, kills, and the feed wait
            // for the real .death, so a hit they didn't accept can't fake one.
            if let hp = players[victim]?.hp {
                players[victim]?.hp = max(0, hp - myRole.damage)
            }
        }
    }

    /// Press-and-hold entry from the FIRE button. Every role fires once on
    /// press; automatic roles (Light) keep firing at their own cadence until
    /// release. fire()'s guards handle death, reload, cooldown, and match end,
    /// so the timer can tick blindly in between.
    func triggerDown() {
        fire()
        guard myRole.isAutomatic else { return }
        autoFireTimer?.invalidate()
        let timer = Timer(timeInterval: myRole.fireCooldown, repeats: true) { [weak self] _ in
            self?.fire()
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps firing during scroll tracking
        autoFireTimer = timer
    }

    func triggerUp() {
        autoFireTimer?.invalidate()
        autoFireTimer = nil
    }

    // MARK: - Kill clips

    /// Everything the shooter's viewfinder held for the last ~5 s, frozen the
    /// moment the kill confirms. Held locally; shipped to spectators after
    /// the match so replays never contend with live traffic.
    private var pendingKillClips: [KillClip] = []
    private var soundLog: [(name: String, volume: Float, rate: Float, at: Date)] = []
    /// Kills waiting out the post-kill roll before their buffer is frozen.
    private var delayedCaptures: [(id: UUID, victim: String)] = []
    /// The clip keeps rolling this long past the kill, so the replay shows
    /// the aftermath instead of cutting on the killing frame.
    private static let postKillRoll: TimeInterval = 2.0

    private func captureKillClip(victim: String) {
        let requestID = UUID()
        delayedCaptures.append((requestID, victim))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.postKillRoll) { [weak self] in
            self?.completeCapture(requestID)
        }
    }

    /// Freeze the buffer for one pending kill. Also called by endMatch for
    /// any still-waiting captures — a final-seconds kill must not lose its
    /// clip to the buffer being disabled.
    private func completeCapture(_ requestID: UUID) {
        guard let index = delayedCaptures.firstIndex(where: { $0.id == requestID }) else { return }
        let victim = delayedCaptures[index].victim
        delayedCaptures.remove(at: index)
        let snapshot = camera.snapshotClip()
        guard !snapshot.frames.isEmpty else { return }
        // The buffer's first frame is (count × interval) ago; sounds map to
        // offsets from there so the review and the MP4 replay them in place.
        let now = Date()
        let duration = Double(snapshot.frames.count) * AimCameraManager.clipFrameInterval
        let clipStart = now.addingTimeInterval(-duration)
        let sounds = soundLog.compactMap { event -> ClipSoundEvent? in
            let offset = event.at.timeIntervalSince(clipStart)
            guard offset >= 0, offset <= duration else { return nil }
            return ClipSoundEvent(name: event.name, volume: event.volume,
                                  rate: event.rate, offset: offset)
        }
        pendingKillClips.append(KillClip(
            id: UUID(), killer: myName, victim: victim, capturedAt: now,
            frames: snapshot.frames, overlays: snapshot.overlays, sounds: sounds))
        if pendingKillClips.count > 10 { pendingKillClips.removeFirst() }
    }

    /// Spectator: encode a reviewed clip to MP4 and push it to the public
    /// gallery. State transitions drive the Publish button.
    func publishKillClip(_ id: UUID) {
        guard isSpectator,
              let index = killClips.firstIndex(where: { $0.id == id }),
              killClips[index].publishState == .idle || killClips[index].publishState == .failed
        else { return }
        let clip = killClips[index]
        killClips[index].publishState = .uploading
        ClipEncoder.encodeMP4(frames: clip.frames, overlays: clip.overlays,
                              sounds: clip.sounds) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.setPublishState(.failed, for: id)
            case .success(let mp4):
                ReplayPublisher.publish(
                    mp4: mp4,
                    killer: clip.killer.displayCallSign,
                    victim: clip.victim.displayCallSign,
                    matchId: String(self.myName.suffix(4)),
                    capturedAt: clip.capturedAt
                ) { uploadResult in
                    try? FileManager.default.removeItem(at: mp4)
                    switch uploadResult {
                    case .success(let url): self.setPublishState(.published(url), for: id)
                    case .failure: self.setPublishState(.failed, for: id)
                    }
                }
            }
        }
    }

    private func setPublishState(_ state: KillClip.PublishState, for id: UUID) {
        guard let index = killClips.firstIndex(where: { $0.id == id }) else { return }
        killClips[index].publishState = state
    }

    /// Post-match: stagger the clips out to every spectator, ~0.5 s apart, so
    /// the summary screen isn't fighting a megabyte burst per clip.
    private func transferKillClips() {
        guard !isSpectator, let net = network, !pendingKillClips.isEmpty, !spectators.isEmpty else {
            pendingKillClips = []
            return
        }
        let clips = pendingKillClips
        pendingKillClips = []
        let targets = spectators
        for (index, clip) in clips.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.5) { [weak self] in
                guard let self, self.network === net else { return }
                for spectator in targets {
                    net.sendKillClip(clip, to: spectator)
                }
            }
        }
    }

    /// Shooter-side hit confirmation — marker, tick, buzz. The kill variant
    /// fires separately when the victim's `.death` comes back over the wire.
    private func confirmHit(kill: Bool = false) {
        hitMarker = HitMarker(count: hitMarker.count + 1, isKill: kill)
        if kill {
            haptics.playKillConfirm()
        } else {
            haptics.playHitMarker()
        }
    }

    /// Manual reload (the button beside FIRE) and the auto-reload on empty.
    func startReload() {
        guard phase == .playing, isAlive, !isReloading, ammo < myRole.magazineSize else { return }
        reloadRemaining = myRole.reloadDuration
        haptics.playReloadStart()
        reloadTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.reloadRemaining -= 0.05
            if self.reloadRemaining <= 0 {
                timer.invalidate()
                self.finishReload()
            }
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking during scroll tracking
        reloadTimer = timer
    }

    private func finishReload() {
        reloadTimer?.invalidate()
        reloadTimer = nil
        reloadRemaining = 0
        ammo = myRole.magazineSize
        haptics.playReloadComplete()
    }

    /// Cancel without loading — death, match end, leaving.
    private func cancelReload() {
        reloadTimer?.invalidate()
        reloadTimer = nil
        reloadRemaining = 0
    }

    /// The core algorithm: most-centered live target inside the aim cone and
    /// weapon range, with a short reading buffer so a single nil-direction
    /// frame doesn't eat the shot. The window is deliberately tight: camera-
    /// assisted NI (U2 chips) can coast on a stale ARKit anchor after the
    /// peer moves, and old readings must not hold a lock.
    func resolveShot() -> String? {
        var best: (name: String, angle: Float)?
        for player in opponents where player.isAlive && isEnemy(player) {
            guard let reading = ranging.latestDirectional(for: player.name, within: 0.2),
                  let angle = reading.angleOffBoresight else { continue }
            let distance = reading.distance
                ?? ranging.latestReading(for: player.name)?.distance
                ?? .infinity
            guard angle < settings.aimConeRadians, distance < settings.weaponRange else { continue }
            if best == nil || angle < best!.angle {
                best = (player.name, angle)
            }
        }
        return best?.name
    }

    private func applyHit(from shooter: String, damage: Int) {
        guard phase == .playing, isAlive, let net = network else { return }
        // Friendly fire never lands. The shooter already filters teammates,
        // but its team table can lag right after a switch — the victim is the
        // authority on its own team, so this is where the rule is final.
        if settings.teamPlay, let mine = myTeam, players[shooter]?.team == mine { return }
        // Absorbed: no damage, no flash, no healthUpdate — as far as the rest
        // of the mesh is concerned this shot never landed.
        let now = Date()
        guard !isInvulnerable(at: now) else { return }
        invulnerableUntil = now.addingTimeInterval(settings.hitInvulnerability)
        let newHP = max(0, (me?.hp ?? 0) - damage)
        players[myName]?.hp = newHP
        haptics.playDamage()
        flashDamage()
        net.send(.healthUpdate(player: myName, hp: newHP))
        if newHP <= 0 {
            die(killedBy: shooter)
        }
    }

    private func die(killedBy killer: String) {
        players[myName]?.isAlive = false
        players[myName]?.deaths += 1
        players[killer]?.kills += 1
        lastKilledBy = killer
        killFeed.insert(KillEvent(killer: killer, victim: myName), at: 0)
        trimFeed()
        network?.send(.death(player: myName, killedBy: killer))
        haptics.playDeath()
        cancelReload()   // respawn hands you a fresh mag anyway
        startRespawnCountdown()
    }

    private func startRespawnCountdown() {
        respawnRemaining = settings.respawnDelay
        respawnTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.respawnRemaining -= 0.1
            if self.respawnRemaining <= 0 {
                timer.invalidate()
                self.respawn()
            }
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking during scroll tracking
        respawnTimer = timer
    }

    private func respawn() {
        respawnRemaining = 0
        players[myName]?.hp = myRole.maxHP
        players[myName]?.isAlive = true
        cancelReload()
        ammo = myRole.magazineSize
        // Overwrites rather than extends any leftover hit i-frames: whoever
        // killed us shouldn't get a shorter spawn window than anyone else.
        invulnerableUntil = Date().addingTimeInterval(settings.spawnProtection)
        network?.send(.respawn(player: myName))
        haptics.playRespawn()
    }

    // MARK: - Match clock

    /// Everyone counts down locally off a wall-clock deadline (drift-free), but
    /// only the host calls time — its `.endMatch` tallies are what everyone
    /// shows, so two phones can never crown different winners. If the host goes
    /// dark, a grace period lets each phone end on its own tallies rather than
    /// stranding the match.
    private func startMatchClock(seconds: TimeInterval) {
        matchDeadline = Date().addingTimeInterval(seconds)
        matchRemaining = seconds
        matchTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tickMatchClock()
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking during scroll tracking
        matchTimer = timer
    }

    /// Host only: call the match right now instead of waiting for the clock.
    /// Same authoritative path as the clock hitting zero — everyone gets the
    /// host's tallies and lands on the summary together.
    func endMatchEarly() {
        guard phase == .playing, isHost else { return }
        let finals = players.values.map(PlayerState.init)
        network?.send(.endMatch(finalStates: finals))
        endMatch(with: Array(players.values))
    }

    private func tickMatchClock() {
        guard phase == .playing, let deadline = matchDeadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        matchRemaining = max(0, remaining)
        guard remaining <= 0 else { return }
        if isHost {
            let finals = players.values.map(PlayerState.init)
            network?.send(.endMatch(finalStates: finals))
            endMatch(with: Array(players.values))
        } else if remaining <= -5 {
            endMatch(with: Array(players.values))   // host never called it
        }
    }

    private func endMatch(with finalPlayers: [Player]) {
        guard phase == .playing else { return }
        // Snapshot before despawning the dummy — in a solo test it holds the
        // only opponent stats worth showing.
        matchResult = MatchResult(
            players: finalPlayers,
            duration: settings.matchDuration,
            myName: myName,
            teamPlay: settings.teamPlay)
        matchTimer?.invalidate()
        matchTimer = nil
        matchDeadline = nil
        matchRemaining = 0
        aimTimer?.invalidate()
        aimTimer = nil
        triggerUp()
        respawnTimer?.invalidate()
        respawnTimer = nil
        respawnRemaining = 0
        cancelReload()
        aimedTarget = nil
        despawnDummy()
        // A kill still waiting out its post-kill roll freezes with whatever
        // the buffer holds — better a short clip than a lost one.
        for capture in delayedCaptures { completeCapture(capture.id) }
        camera.clipBufferEnabled = false
        phase = .summary
        haptics.playMatchEnd()
        transferKillClips()   // ship the killcams to the review screen
    }

    /// Summary → lobby, mesh intact, so the host can run another match.
    func returnToLobby() {
        guard phase == .summary else { return }
        matchResult = nil
        killFeed = []
        lastKilledBy = nil
        lastFireTime = nil
        invulnerableUntil = nil
        damageFlash = false
        for (name, player) in players {
            players[name]?.hp = player.role.maxHP
            players[name]?.isAlive = true
        }
        phase = .lobby
        refreshLobbyAdvertisement()   // back to "open" in the lobby list
        // Leaving the review deletes the clips: published ones live on the
        // gallery, unpublished ones are gone for good — nothing is kept.
        killClips = []
    }

    // MARK: - Aim indicator

    private func startAimTimer() {
        aimTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateAimedTarget()
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking during scroll tracking
        aimTimer = timer
    }

    private func updateAimedTarget() {
        guard phase == .playing, isAlive else {
            if aimedTarget != nil { aimedTarget = nil }
            return
        }
        let target = resolveShot()
        if target != aimedTarget {
            aimedTarget = target
            if target != nil { haptics.playLockTick() }
        }
        let hint = ranging.anyConvergenceHint
        if hint != aimHint { aimHint = hint }
    }

    // MARK: - Target dummy (solo practice)

    private func spawnDummy() {
        var target = Player(name: TargetDummy.name)   // a Regular, 100 HP
        // Solo practice with teams on: the dummy mans the other side, so the
        // enemy-only aim filter still finds it.
        if settings.teamPlay { target.team = myTeam?.other ?? .bravo }
        players[TargetDummy.name] = target
        dummyInvulnerableUntil = nil
        dummy.onReading = { [weak self] reading in
            self?.ranging.injectSyntheticReading(reading, for: TargetDummy.name)
        }
        dummy.spawn()
    }

    private func despawnDummy() {
        guard players[TargetDummy.name] != nil else { return }
        dummy.stop()
        ranging.removeSynthetic(TargetDummy.name)
        players[TargetDummy.name] = nil
        dummyInvulnerableUntil = nil
    }

    /// Victim-side logic, played locally: the dummy takes damage, dies, and
    /// respawns at a new bearing so you have to hunt for it.
    private func hitDummy() {
        guard var target = players[TargetDummy.name], target.isAlive else { return }
        // Unreachable while fireCooldown >= hitInvulnerability (you're the only
        // shooter here), but it keeps practice honest if either is retuned.
        let now = Date()
        if let until = dummyInvulnerableUntil, now < until { return }
        dummyInvulnerableUntil = now.addingTimeInterval(settings.hitInvulnerability)
        target.hp = max(0, target.hp - myRole.damage)
        confirmHit()
        if target.hp <= 0 {
            target.isAlive = false
            target.deaths += 1
            players[myName]?.kills += 1
            killFeed.insert(KillEvent(killer: myName, victim: TargetDummy.name), at: 0)
            trimFeed()
            confirmHit(kill: true)
            captureKillClip(victim: TargetDummy.name)
            dummy.relocate()
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.respawnDelay) { [weak self] in
                guard let self, self.phase == .playing,
                      var revived = self.players[TargetDummy.name] else { return }
                revived.hp = revived.role.maxHP
                revived.isAlive = true
                self.dummyInvulnerableUntil = Date().addingTimeInterval(self.settings.spawnProtection)
                self.players[TargetDummy.name] = revived
            }
        }
        players[TargetDummy.name] = target
    }

    // MARK: - Helpers

    /// Merge a snapshot row from the wire — each phone is authoritative for
    /// its own row, so never overwrite ours.
    private func apply(_ state: PlayerState) {
        guard state.name != myName else { return }
        // A snapshot is the one path that can resurrect a spectator: whoever
        // built it may have added the Mac as a player in peerDidConnect before
        // its .spectatorHello landed, and every receiver would then recreate it
        // as a shootable target even after correctly removing it.
        guard !spectators.contains(state.name) else { return }
        var player = players[state.name] ?? Player(name: state.name, role: state.role)
        player.role = state.role
        player.hp = state.hp
        player.isAlive = state.isAlive
        player.kills = state.kills
        player.deaths = state.deaths
        // A snapshot without a team must not erase one we learned directly.
        if let team = state.team { player.team = team }
        players[state.name] = player
    }

    private func flashDamage() {
        damageFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.damageFlash = false
        }
    }

    private func trimFeed() {
        if killFeed.count > 6 { killFeed.removeLast(killFeed.count - 6) }
    }

    private func stopTimers() {
        aimTimer?.invalidate()
        aimTimer = nil
        triggerUp()
        respawnTimer?.invalidate()
        respawnTimer = nil
        respawnRemaining = 0
        matchTimer?.invalidate()
        matchTimer = nil
        matchDeadline = nil
        matchRemaining = 0
        cancelReload()
    }
}

// MARK: - NetworkManagerDelegate

extension GameEngine: NetworkManagerDelegate {
    func network(_ manager: NetworkManager, peerDidConnect name: String) {
        guard manager === network else { return }   // stale callbacks after leave()
        // Joiner: the host we picked answered — we're in, pending its
        // capacity check (a .joinDenied would bounce us back out).
        if phase == .browsing, name == joiningLobby {
            joiningLobby = nil
            phase = .lobby
        }
        if players[name] != nil {
            players[name]?.isConnected = true       // reconnect: keep their stats
        }
        // Roster rows are created when the peer declares itself via
        // .hello/.spectatorHello — a bare connection isn't membership.
        manager.send(isSpectator ? .spectatorHello : .hello(playerName: myName, role: myRole), to: [name])
        // Same link, so TCP ordering lands this after the hello that creates
        // our row on their side.
        if settings.teamPlay, let team = myTeam {
            manager.send(.teamChange(player: myName, team: team), to: [name])
        }
    }

    func network(_ manager: NetworkManager, peerDidDisconnect name: String) {
        guard manager === network else { return }
        if name == externalHostName { clearExternalMatch() }   // its match can't hold our lock
        if spectators.contains(name) {
            spectators.remove(name)
            if isHost { broadcastRoster() }
        }
        if phase == .playing, players[name] != nil {
            // Might be a transient blip — keep stats so reconnect doesn't
            // resurrect them at full HP with zeroed kills.
            players[name]?.isConnected = false
        } else {
            players[name] = nil
            if isHost {
                broadcastRoster()
                refreshLobbyAdvertisement()
            }
        }
        ranging.removePeer(name)
        if streamingTo == name {
            streamingTo = nil
            camera.frameTap = nil
        }
        if watchingPlayer == name {
            watchingPlayer = nil
            spectatorFrame = nil
        spectatorOverlay = nil
        }
    }

    func network(_ manager: NetworkManager, didReceive message: GameMessage, from peerName: String) {
        guard manager === network else { return }
        switch message {
        case .hello(let name, let role):
            // Host gates capacity here: spectators never count, reconnects
            // (already in players) always pass.
            if isHost, players[name] == nil,
               players.keys.filter({ $0 != TargetDummy.name }).count >= settings.maxPlayers {
                manager.send(.joinDenied(reason: "Lobby is full (\(settings.maxPlayers) players)."), to: [peerName])
                return
            }
            if players[name] == nil {
                players[name] = Player(name: name, role: role)
            } else {
                players[name]?.isConnected = true
                // Mid-match their row (HP included) is authoritative from
                // them — don't re-base it under a role that can't change now.
                if phase != .playing { players[name]?.role = role }
            }
            if isHost {
                broadcastRoster()
                refreshLobbyAdvertisement()
                // Joiners can't see lobby settings otherwise — and the team
                // picker only appears once they know team play is on.
                if phase == .lobby {
                    manager.send(.settingsUpdate(settings: settings), to: [peerName])
                }
            }
            if phase == .playing {
                if !isSpectator { despawnDummy() }   // a real target arrived
                // Late joiner or reconnect mid-match: sync settings + full
                // state (host), our own authoritative row (everyone), and
                // pair up UWB. Ordered unicasts land after .startGame.
                if isHost {
                    manager.send(.startGame(settings: settings), to: [peerName])
                    manager.send(.stateSnapshot(players.values.map(PlayerState.init)), to: [peerName])
                    if let deadline = matchDeadline {
                        manager.send(.matchClock(remaining: max(0, deadline.timeIntervalSinceNow)), to: [peerName])
                    }
                } else if let mine = me {
                    manager.send(.stateSnapshot([PlayerState(mine)]), to: [peerName])
                }
                if !isSpectator, let data = ranging.prepare(peerName: name) {
                    manager.send(.discoveryToken(data), to: [peerName])
                }
            }

        case .roleSelect(let player, let role):
            // Lobby-only by construction (the picker hides in play), but guard
            // anyway: a mid-match swap would re-base a live HP total.
            guard phase != .playing, player != myName else { return }
            players[player]?.role = role
            players[player]?.hp = role.maxHP

        case .discoveryToken(let data):
            if let reply = ranging.receiveToken(data, from: peerName) {
                manager.send(.discoveryToken(reply), to: [peerName])
            }

        case .settingsUpdate(let settings):
            // Hosts ignore it — their own settings are the ones being mirrored.
            guard !isHost, phase == .lobby else { return }
            self.settings = settings
            autoAssignTeamIfNeeded()

        case .teamChange(let player, let team):
            guard player != myName else { return }   // our own choice is authoritative
            players[player]?.team = team

        case .startGame(let settings):
            let fromSpectator = spectators.contains(peerName)
            if phase == .playing {
                if fromSpectator, isHost, !isSpectator {
                    // The game master started a real match while we were host
                    // of a stale one (typically abandoned solo practice) —
                    // ours yields and we join theirs.
                    isHost = false
                    beginMatch(with: settings)
                } else if !isHost {
                    // Late-join/reconnect resync; don't reset the match. A
                    // host ignores it — its own settings are authoritative,
                    // and a rival's broadcast must not rewrite a live match.
                    self.settings = settings
                }
            } else {
                // The game master (spectator-host) is never dragged into
                // someone else's match — it opens on its setup screen and
                // starts matches itself. Note who runs the live match; the
                // snapshot that follows tells us whether it's a real game
                // (2+ players, locks our setup) or abandoned solo practice.
                if isSpectator, isHost {
                    externalHostName = peerName
                    return
                }
                // Someone else's match is starting — whoever started it calls
                // time. Without dropping the flag, a lobby host pulled into a
                // running match would broadcast rival .endMatch tallies when
                // its own clock hit zero.
                isHost = false
                beginMatch(with: settings)
            }

        case .stateSnapshot(let states):
            if phase == .playing {
                states.forEach(apply)
            } else {
                if isSpectator, isHost, peerName == externalHostName {
                    externalMatchPlayers = states.count
                }
                // Can arrive before .startGame from independent senders; stash
                // and apply after beginMatch resets.
                for state in states where state.name != myName {
                    pendingSnapshots[state.name] = (state, Date())
                }
            }

        case .shotFired(let by):
            if by != myName { haptics.playDistantShot() }

        case .hit(let target, let by, let damage):
            if target == myName { applyHit(from: by, damage: damage) }

        case .healthUpdate(let player, let hp):
            if player != myName { players[player]?.hp = hp }

        case .death(let player, let killedBy):
            guard player != myName else { return }
            players[player]?.isAlive = false
            players[player]?.deaths += 1
            players[killedBy]?.kills += 1
            killFeed.insert(KillEvent(killer: killedBy, victim: player), at: 0)
            trimFeed()
            if killedBy == myName {
                confirmHit(kill: true)
                captureKillClip(victim: player)
            }

        case .respawn(let player):
            guard player != myName else { return }
            players[player]?.hp = (players[player]?.role ?? .regular).maxHP
            players[player]?.isAlive = true

        case .endMatch(let finalStates):
            if externalMatchInProgress, peerName == externalHostName {
                clearExternalMatch()   // the running game ended; setup unlocks
                return
            }
            guard phase == .playing else { return }
            // Host's tallies are authoritative for the summary; fall back to
            // our own row if the host somehow never saw us.
            var finals = finalStates.map { state -> Player in
                var player = players[state.name] ?? Player(name: state.name, role: state.role)
                player.role = state.role
                player.hp = state.hp
                player.isAlive = state.isAlive
                player.kills = state.kills
                player.deaths = state.deaths
                if let team = state.team { player.team = team }
                return player
            }
            if !finals.contains(where: { $0.name == myName }), let mine = me {
                finals.append(mine)
            }
            endMatch(with: finals)

        case .matchClock(let remaining):
            guard phase == .playing, !isHost else { return }
            startMatchClock(seconds: remaining)

        case .spectatorHello:
            // Not a combatant: no roster row, no HP, no UWB session, can't be shot.
            spectators.insert(peerName)
            players[peerName] = nil
            ranging.removePeer(peerName)
            if isHost {
                broadcastRoster()
                if phase == .playing {
                    // Catch the spectator up on the running match.
                    manager.send(.startGame(settings: settings), to: [peerName])
                    manager.send(.stateSnapshot(players.values.map(PlayerState.init)), to: [peerName])
                    if let deadline = matchDeadline {
                        manager.send(.matchClock(remaining: max(0, deadline.timeIntervalSinceNow)), to: [peerName])
                    }
                }
            }

        case .cameraRequest(let active):
            if active {
                streamingTo = peerName
                camera.start()   // idempotent; covers a lobby preview request
                camera.frameTap = { [weak self] jpeg in
                    guard let self, let target = self.streamingTo else { return }
                    self.network?.sendCameraFrame(jpeg, to: target)
                    // Ride along with every frame: what our HUD is showing,
                    // so the spectator can redraw crosshair + enemy tags.
                    self.network?.send(.overlayState(self.currentOverlayState()), to: [target])
                }
            } else if streamingTo == peerName {
                streamingTo = nil
                camera.frameTap = nil
            }

        case .overlayState(let state):
            if isSpectator, peerName == watchingPlayer {
                spectatorOverlay = state
            }

        case .hostEnded:
            guard !isHost else {
                // Two hosts: don't let one kick the other — but a phone host
                // shutting down does unlock the game master's setup screen.
                if peerName == externalHostName { clearExternalMatch() }
                return
            }
            leave()
            hostEndedNotice = "The host ended the game."

        case .lobbyRoster(let playerNames, let spectatorNames):
            guard !isHost else { return }   // members mirror the host's list
            spectators = Set(spectatorNames).subtracting([myName])
            // Role unknown until their .hello / .roleSelect lands; Regular
            // is the placeholder.
            for name in playerNames where players[name] == nil && name != myName {
                players[name] = Player(name: name)
            }
            if phase == .lobby {
                // Host-authoritative membership: prune strangers pre-match.
                for name in players.keys where name != myName && !playerNames.contains(name) {
                    players[name] = nil
                }
            }
            network?.updateRoster(playerNames + spectatorNames)

        case .joinDenied(let reason):
            guard !isHost, phase == .lobby || phase == .browsing else { return }
            leave()
            lobbyNotice = reason
        }
    }

    func network(_ manager: NetworkManager, didReceiveKillClip clip: KillClip, from peerName: String) {
        guard manager === network, isSpectator else { return }
        guard !killClips.contains(where: { $0.id == clip.id }) else { return }
        killClips.append(clip)
        killClips.sort { $0.capturedAt < $1.capturedAt }
    }

    func network(_ manager: NetworkManager, didReceiveCameraFrame jpeg: Data, from peerName: String) {
        guard manager === network, isSpectator,
              peerName == watchingPlayer,
              let image = UIImage(data: jpeg) else { return }
        spectatorFrame = image
    }
}

// MARK: - RangingManagerDelegate

extension GameEngine: RangingManagerDelegate {
    func ranging(_ manager: RangingManager, resendToken tokenData: Data, to peerName: String) {
        guard let net = network, net.isConnected(peerName) else { return }
        net.send(.discoveryToken(tokenData), to: [peerName])
    }

    func ranging(_ manager: RangingManager, raiseAlert reason: String, forPeer peerName: String?) {
        rangingAlert = reason
        rangingAlertPeer = peerName
    }

    func ranging(_ manager: RangingManager, clearAlertForPeer peerName: String) {
        // A device-wide alert (permission, camera access) can't be dismissed
        // by one peer's recovery — only per-peer alerts clear here.
        guard rangingAlertPeer == peerName else { return }
        rangingAlert = nil
        rangingAlertPeer = nil
    }
}
